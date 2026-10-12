import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Page;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/app_database.dart';
import '../data/book_repository.dart';
import '../services/ocr_engine.dart';
import '../services/ocr_service.dart';
import '../services/sherpa_tts.dart';
import '../theme/app_theme.dart';
import 'listen_page.dart';
import 'offline_tts_page.dart';
import 'proofread_page.dart';
import 'reader_page.dart';

/// 书详情：书籍信息 + 页面照片管理（拍照 / 相册批量导入、排序、删除）。
class BookDetailPage extends StatefulWidget {
  const BookDetailPage({
    super.key,
    required this.repository,
    required this.book,
  });

  final BookRepository repository;
  final Book book;

  @override
  State<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends State<BookDetailPage> {
  final _picker = ImagePicker();
  bool _busy = false;

  // OCR 状态
  OcrService? _ocrService;
  MlKitOcrEngine? _ocrEngine;
  bool _ocrRunning = false;
  bool _ocrPaused = false;
  int _ocrDone = 0;
  int _ocrTotal = 0;
  String _ocrStatus = '';

  // 章节与多选
  int? _chapterView; // 当前查看/导入的章节（null=全部，导入时表示未分章）
  int _focusIndex = 0; // 当前查看/点击的页（进入校对时定位到这一页）
  bool _selecting = false;
  final Set<int> _selectedPageIds = {};

  // 朗读（离线神经语音 sherpa-onnx）
  String _sherpaVoiceId = 'melo';
  String _sherpaVoiceName = '若晚 · 柔和高保真';
  bool _sherpaReady = false;
  AudioPlayer? _trialPlayer;
  FlutterTts? _trialTts;

  Book get book => widget.book;

  @override
  void initState() {
    super.initState();
    _refreshSherpa();
  }

  /// 读取默认离线音色及其是否已下载。
  Future<void> _refreshSherpa() async {
    final id =
        await widget.repository.getSetting(kSherpaVoiceSetting) ?? 'melo';
    final v = sherpaVoiceById(id);
    final ready = await TtsModelManager.instance.isInstalled(v);
    if (mounted) {
      setState(() {
        _sherpaVoiceId = v.id;
        _sherpaVoiceName = v.displayName;
        _sherpaReady = ready;
      });
    }
  }

  @override
  void dispose() {
    _ocrService?.cancel();
    _ocrEngine?.dispose();
    _trialPlayer?.dispose();
    _trialTts?.stop();
    super.dispose();
  }

  Future<void> _startOcr() async {
    if (_ocrRunning) {
      return;
    }
    setState(() {
      _ocrRunning = true;
      _ocrPaused = false;
      _ocrDone = 0;
      _ocrTotal = 0;
      _ocrStatus = '准备中…';
    });
    _ocrEngine = MlKitOcrEngine();
    _ocrService = OcrService(AppDatabase.instance, _ocrEngine!,
        repository: widget.repository);
    await _ocrService!.processBook(
      book.id,
      onProgress: (done, total, status) {
        if (mounted) {
          setState(() {
            _ocrDone = done;
            _ocrTotal = total;
            _ocrStatus = status;
          });
        }
      },
    );
    if (mounted) {
      setState(() => _ocrRunning = false);
    }
    _ocrEngine?.dispose();
    _ocrEngine = null;
  }

  Future<void> _importFromGallery() async {
    setState(() => _busy = true);
    try {
      // maxWidth 2000：批量多选时压缩内存与复制耗时（仍保留书页细节）
      final files = await _picker.pickMultiImage(
          imageQuality: 92, maxWidth: 2000, limit: 60);
      if (files.isNotEmpty) {
        await widget.repository.addPagesFromPaths(
          book.id,
          files.map((f) => f.path).toList(),
          chapterId: _chapterView,
        );
        _snack('已导入 ${files.length} 张照片，正在识别…');
        if (!_ocrRunning) {
          unawaited(_startOcr());
        }
      }
    } catch (e) {
      _snack('导入失败：$e');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _takePhoto() async {
    setState(() => _busy = true);
    try {
      // maxWidth 保留高分辨率（拍书页需要细节），92 质量压缩体积
      final file = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 3000,
        imageQuality: 92,
      );
      if (file != null) {
        await widget.repository.addPagesFromPaths(
          book.id,
          [file.path],
          chapterId: _chapterView,
        );
        _snack('已添加 1 张照片，正在识别…');
        if (!_ocrRunning) {
          unawaited(_startOcr());
        }
      }
    } catch (e) {
      _snack('拍照失败：$e');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  /// 导入电子书文本：粘贴/输入书的内容，按空行分段自动分页，
  /// 直接成为可读的电子书页（无需照片）。
  Future<void> _importTextBook() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('导入电子书文本',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: ctrl,
            maxLines: 12,
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: const InputDecoration(
              hintText: '把书的内容粘贴到这里（可整章粘贴，按空行分段自动成页）',
              hintStyle: TextStyle(color: AppColors.textSecondary),
              filled: true,
              fillColor: AppColors.surfaceHigh,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('导入',
                style: TextStyle(color: AppColors.textPrimary)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) {
      return;
    }
    final text = ctrl.text.trim();
    if (text.isEmpty) {
      _snack('内容为空，没有导入');
      return;
    }
    setState(() => _busy = true);
    try {
      final n = await widget.repository.addTextPages(book.id, text,
          chapterId: _chapterView);
      _snack(n > 0 ? '已导入 $n 页电子书' : '内容为空，没有导入');
    } catch (e) {
      _snack('导入失败：$e');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _snack(String msg) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _toggleSelecting() {
    setState(() {
      _selecting = !_selecting;
      _selectedPageIds.clear();
    });
  }

  void _toggleSelectPage(int pageId) {
    setState(() {
      if (_selectedPageIds.contains(pageId)) {
        _selectedPageIds.remove(pageId);
      } else {
        _selectedPageIds.add(pageId);
      }
    });
  }

  Future<void> _deleteSelected() async {
    final n = _selectedPageIds.length;
    if (n == 0) {
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('删除选中的 $n 张照片？',
            style: const TextStyle(color: AppColors.textPrimary, fontSize: 16)),
        content: const Text('已识别的文字也会一并删除，此操作不可恢复。',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除',
                style: TextStyle(color: AppColors.accentRedPressed)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.repository.deletePages(_selectedPageIds.toList());
      if (mounted) {
        setState(() => _selectedPageIds.clear());
      }
    }
  }

  Future<void> _moveSelectedToChapter() async {
    final chapters = await widget.repository.watchChapters(book.id).first;
    if (!mounted) {
      return;
    }
    final target = await showModalBottomSheet<int?>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('移动到章节',
                  style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.menu_book_outlined,
                  color: AppColors.textSecondary),
              title: const Text('未分章',
                  style: TextStyle(color: AppColors.textPrimary, fontSize: 14)),
              onTap: () => Navigator.pop(ctx, -1),
            ),
            for (final c in chapters)
              ListTile(
                dense: true,
                leading: const Icon(Icons.bookmark_outline,
                    color: AppColors.gold),
                title: Text(c.title,
                    style: const TextStyle(
                        color: AppColors.textPrimary, fontSize: 14)),
                onTap: () => Navigator.pop(ctx, c.id),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (target == null || !mounted) {
      return;
    }
    await widget.repository
        .movePagesToChapter(_selectedPageIds.toList(), target == -1 ? null : target);
    if (mounted) {
      setState(() => _selectedPageIds.clear());
    }
  }

  Future<void> _addChapter() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('新建章节',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: InputDecoration(
            hintText: '章节名，如：第一章',
            hintStyle: const TextStyle(color: AppColors.textSecondary),
            filled: true,
            fillColor: AppColors.surfaceHigh,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppColors.outline),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('创建', style: TextStyle(color: AppColors.gold)),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      final id = await widget.repository.createChapter(book.id, name);
      if (mounted) {
        setState(() => _chapterView = id);
      }
    }
  }

  Future<void> _chapterMenu(Chapter chapter) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Text(chapter.title,
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.edit_outlined,
                  color: AppColors.textSecondary),
              title: const Text('重命名',
                  style: TextStyle(color: AppColors.textPrimary)),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline,
                  color: AppColors.accentRedPressed),
              title: const Text('删除章节（照片保留，变为未分章）',
                  style: TextStyle(
                      color: AppColors.accentRedPressed, fontSize: 14)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null || !mounted) {
      return;
    }
    if (action == 'rename') {
      final ctrl = TextEditingController(text: chapter.title);
      final name = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('重命名章节',
              style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            style: const TextStyle(color: AppColors.textPrimary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消',
                  style: TextStyle(color: AppColors.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child:
                  const Text('确定', style: TextStyle(color: AppColors.gold)),
            ),
          ],
        ),
      );
      if (name != null && name.isNotEmpty) {
        await widget.repository.renameChapter(chapter.id, name);
      }
    } else if (action == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text('删除章节「${chapter.title}」？',
              style: const TextStyle(
                  color: AppColors.textPrimary, fontSize: 16)),
          content: const Text('章节内照片会保留并变为未分章。',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消',
                  style: TextStyle(color: AppColors.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除',
                  style: TextStyle(color: AppColors.accentRedPressed)),
            ),
          ],
        ),
      );
      if (ok == true) {
        await widget.repository.deleteChapter(chapter.id);
        if (mounted && _chapterView == chapter.id) {
          setState(() => _chapterView = null);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(book.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.auto_stories_outlined,
                size: 20, color: AppColors.gold),
            tooltip: '阅读',
            onPressed: () {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ReaderPage(
                  repository: widget.repository,
                  book: book,
                ),
              ));
            },
          ),
          IconButton(
            icon: const Icon(Icons.fact_check_outlined,
                size: 20, color: AppColors.textSecondary),
            tooltip: '校对文字',
            onPressed: _openProofread,
          ),
          IconButton(
            icon: Icon(
              _selecting ? Icons.close : Icons.checklist,
              color: _selecting ? AppColors.gold : AppColors.textSecondary,
              size: 20,
            ),
            tooltip: _selecting ? '完成' : '选择照片',
            onPressed: _toggleSelecting,
          ),
        ],
      ),
      body: Column(
        children: [
          // 书籍信息条
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                _coverThumb(),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${book.author}${book.authorCountry.isEmpty ? '' : ' · ${book.authorCountry}'}${book.authorEra.isEmpty ? '' : ' · ${book.authorEra}'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppColors.textSecondary, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.outline),
          // 章节选择行
          StreamBuilder<List<Chapter>>(
            stream: widget.repository.watchChapters(book.id),
            builder: (context, snapshot) {
              final chapters = snapshot.data ?? const <Chapter>[];
              return SizedBox(
                height: 42,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                  children: [
                    _chapterChip('全部',
                        selected: _chapterView == null,
                        onTap: () => setState(() => _chapterView = null)),
                    for (final c in chapters)
                      _chapterChip(
                        c.title,
                        selected: _chapterView == c.id,
                        onTap: () => setState(() => _chapterView = c.id),
                        onLongPress: () => _chapterMenu(c),
                      ),
                    _chapterChip('＋ 新章节',
                        selected: false,
                        onTap: _addChapter),
                  ],
                ),
              );
            },
          ),
          // 拍摄提示
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
            child: Row(
              children: [
                const Icon(Icons.tips_and_updates_outlined,
                    size: 14, color: AppColors.gold),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '拍书页小技巧：一次只拍一页、页面尽量满屏、手机与页面平行、光线充足',
                    style: TextStyle(
                        color: AppColors.textSecondary, fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
          // 导入按钮
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _takePhoto,
                    icon: const Icon(Icons.photo_camera_outlined, size: 16),
                    label: const Text('拍照'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.textPrimary,
                      side: const BorderSide(color: AppColors.outline),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _importFromGallery,
                    icon: const Icon(Icons.photo_library_outlined, size: 16),
                    label: const Text('相册导入'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accentRed,
                      foregroundColor: AppColors.textPrimary,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 导入电子书文本（无需照片，直接成为可读的电子书页）
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _importTextBook,
                    icon: const Icon(Icons.description_outlined, size: 16),
                    label: const Text('导入电子书（粘贴文本）'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.textPrimary,
                      side: const BorderSide(color: AppColors.outline),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // OCR 识别
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: _buildOcrSection(),
          ),
          // 听书
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: _buildListenSection(),
          ),
          // 照片网格
          Expanded(
            child: StreamBuilder<List<Page>>(
              stream: widget.repository.watchPages(book.id,
                  chapterId: _chapterView),
              builder: (context, snapshot) {
                final pages = snapshot.data ?? const <Page>[];
                if (pages.isEmpty) {
                  return const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.photo_library_outlined,
                            size: 48, color: AppColors.textSecondary),
                        SizedBox(height: 12),
                        Text('还没有照片',
                            style: TextStyle(
                                color: AppColors.textPrimary, fontSize: 15)),
                        SizedBox(height: 6),
                        Text('拍照或从相册导入这本书的照片',
                            style: TextStyle(
                                color: AppColors.textSecondary, fontSize: 12)),
                      ],
                    ),
                  );
                }
                return Column(
                  children: [
                    Expanded(
                      child: GridView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                          childAspectRatio: 0.72,
                        ),
                        itemCount: pages.length,
                        itemBuilder: (context, index) {
                          final page = pages[index];
                          return _buildPageCell(page, index: index);
                        },
                      ),
                    ),
                    // 多选操作栏
                    if (_selecting)
                      _buildSelectionBar(pages),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _chapterChip(
    String label, {
    required bool selected,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
  }) {
    final chip = ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: selected,
      onSelected: (_) => onTap(),
      backgroundColor: AppColors.surface,
      selectedColor: AppColors.surfaceHigh,
      checkmarkColor: AppColors.gold,
      showCheckmark: false,
      side: BorderSide(
          color: selected ? AppColors.gold : AppColors.outline),
      labelStyle: TextStyle(
        fontSize: 12,
        color: selected ? AppColors.textPrimary : AppColors.textSecondary,
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: onLongPress == null
          ? chip
          : GestureDetector(onLongPress: onLongPress, child: chip),
    );
  }

  /// 打开校对页，定位到当前查看/点击的那一页。
  void _openProofread() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ProofreadPage(
        repository: widget.repository,
        book: book,
        initialIndex: _focusIndex,
      ),
    ));
  }

  /// 单页缩略图：选择模式下点击勾选，普通模式下长按拖拽排序；
  /// 普通模式点击某页 → 直接进入校对该页。
  Widget _buildPageCell(Page page, {required int index}) {
    // 原照片存在则显示照片；删除原图 / 纯文本页则显示这一页的电子书
    final hasImage =
        page.imagePath.isNotEmpty && File(page.imagePath).existsSync();
    Widget cell = ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (hasImage)
            Image.file(
              File(page.imagePath),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Container(
                color: AppColors.surfaceHigh,
                child: const Center(
                  child: Icon(Icons.broken_image_outlined,
                      size: 28, color: AppColors.textSecondary),
                ),
              ),
            )
          else
            Container(
              color: AppColors.surfaceHigh,
              padding: const EdgeInsets.all(6),
              alignment: Alignment.topLeft,
              child: Text(
                page.content.isEmpty ? '（无内容）' : page.content,
                maxLines: 7,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 10,
                    color: AppColors.textSecondary,
                    height: 1.4),
              ),
            ),
          // 序号角标
          Positioned(
            top: 4,
            left: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xCC1F1A16),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '${page.orderIndex}',
                style:
                    const TextStyle(fontSize: 11, color: AppColors.gold),
              ),
            ),
          ),
          if (page.status != 'pending')
            Positioned(
              bottom: 4,
              right: 4,
              child: Icon(
                page.status == 'proofread'
                    ? Icons.check_circle
                    : Icons.article_outlined,
                size: 14,
                color: page.status == 'proofread'
                    ? AppColors.gold
                    : AppColors.textSecondary,
              ),
            ),
          // 选择状态蒙层
          if (_selecting)
            Container(
              color: _selectedPageIds.contains(page.id)
                  ? const Color(0x55B08D57)
                  : const Color(0x001F1A16),
            ),
          if (_selecting && _selectedPageIds.contains(page.id))
            const Positioned(
              top: 4,
              right: 4,
              child: Icon(Icons.check_circle, size: 18, color: AppColors.gold),
            ),
        ],
      ),
    );

    if (_selecting) {
      return GestureDetector(
        onTap: () => _toggleSelectPage(page.id),
        child: cell,
      );
    }
    // 普通模式：长按拖拽排序；点击该页 → 进入校对该页
    return DragTarget<int>(
      onWillAcceptWithDetails: (d) => d.data != page.id,
      onAcceptWithDetails: (d) {
        widget.repository.swapPageOrder(d.data, page.id);
      },
      builder: (context, candidates, rejected) {
        return GestureDetector(
          onTap: () {
            setState(() => _focusIndex = index);
            _openProofread();
          },
          child: LongPressDraggable<int>(
            data: page.id,
            delay: const Duration(milliseconds: 250),
            feedback: Material(
              color: Colors.transparent,
              child: SizedBox(
                width: 110,
                height: 150,
                child: cell,
              ),
            ),
            childWhenDragging: Opacity(opacity: 0.4, child: cell),
            child: cell,
          ),
        );
      },
    );
  }

  Widget _buildSelectionBar(List<Page> pages) {
    final selectedCount = _selectedPageIds.length;
    final allSelected =
        pages.isNotEmpty && selectedCount == pages.length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.outline)),
      ),
      child: Row(
        children: [
          TextButton(
            onPressed: () {
              setState(() {
                if (allSelected) {
                  _selectedPageIds.clear();
                } else {
                  _selectedPageIds
                    ..clear()
                    ..addAll(pages.map((p) => p.id));
                }
              });
            },
            child: Text(allSelected ? '取消全选' : '全选',
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 13)),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: selectedCount == 0 ? null : _moveSelectedToChapter,
            icon: const Icon(Icons.drive_file_move_outline,
                size: 16, color: AppColors.textSecondary),
            label: Text('移到章节',
                style: TextStyle(
                    color: selectedCount == 0
                        ? AppColors.textSecondary.withValues(alpha: 0.4)
                        : AppColors.textSecondary,
                    fontSize: 13)),
          ),
          TextButton.icon(
            onPressed: selectedCount == 0 ? null : _deleteSelected,
            icon: Icon(Icons.delete_outline,
                size: 16,
                color: selectedCount == 0
                    ? AppColors.textSecondary.withValues(alpha: 0.4)
                    : AppColors.accentRedPressed),
            label: Text('删除$selectedCount',
                style: TextStyle(
                    color: selectedCount == 0
                        ? AppColors.textSecondary.withValues(alpha: 0.4)
                        : AppColors.accentRedPressed,
                    fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _coverThumb() {
    final path = book.coverPath;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 48,
        height: 72,
        child: path != null && File(path).existsSync()
            ? Image.file(File(path), fit: BoxFit.cover)
            : Container(
                color: AppColors.surfaceHigh,
                child: const Icon(Icons.auto_stories_outlined,
                    size: 20, color: AppColors.textSecondary),
              ),
      ),
    );
  }

  /// OCR 识别面板：未运行时显示按钮，运行时显示进度与暂停/取消。
  // ===== 听书（批次 11） =====

  Future<void> _trialVoice() async {
    await _refreshSherpa();
    if (!mounted) {
      return;
    }
    if (!_sherpaReady) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('离线语音未下载',
              style:
                  TextStyle(color: AppColors.textPrimary, fontSize: 16)),
          content: Text(
              '「$_sherpaVoiceName」需在 Wi-Fi 下下载一次（约 60MB），之后完全离线。',
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 13)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消',
                  style: TextStyle(color: AppColors.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('去下载',
                  style: TextStyle(color: AppColors.gold)),
            ),
          ],
        ),
      );
      if (go == true && mounted) {
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) =>
              OfflineTtsPage(repository: widget.repository),
        ));
        await _refreshSherpa();
      }
      return;
    }
    _snack('正在合成试听…');
    final v = sherpaVoiceById(_sherpaVoiceId);
    try {
      // 后台 isolate 合成，避免大模型在界面线程加载导致卡顿。
      final modelBase = (await TtsModelManager.instance.dirFor(v)).path;
      final data = await synthesizeSpeechOnIsolate(
          v.id, '你好，这是猎书客的离线朗读试听，祝你阅读愉快。', modelBase);
      final docs = await getApplicationDocumentsDirectory();
      final f = File(p.join(docs.path, 'tts_trial.wav'));
      await f.writeAsBytes(data);
      _trialPlayer?.dispose();
      _trialPlayer = AudioPlayer();
      await _trialPlayer!.setFilePath(f.path);
      _trialPlayer!.play();
    } catch (e) {
      _snack('试听失败：$e');
    }
  }

  Future<void> _openListen() async {
    final pages = await widget.repository.watchPages(book.id).first;
    final readable =
        pages.where((pg) => pg.content.trim().isNotEmpty).length;
    if (!mounted) {
      return;
    }
    if (readable == 0) {
      _snack('还没有识别出文字，先点「识别全部文字」');
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          ListenPage(repository: widget.repository, book: book),
    ));
  }

  Widget _buildListenSection() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.outline),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.headphones_outlined,
                  size: 16, color: AppColors.gold),
              const SizedBox(width: 6),
              const Text('听书',
                  style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(
                _sherpaReady ? _sherpaVoiceName : '离线语音未下载',
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 11),
              ),
              TextButton(
                onPressed: () async {
                  await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) =>
                        OfflineTtsPage(repository: widget.repository),
                  ));
                  await _refreshSherpa();
                },
                child: const Text('管理语音',
                    style:
                        TextStyle(color: AppColors.gold, fontSize: 11)),
              ),
              TextButton(
                onPressed: _trialVoice,
                child: const Text('试听',
                    style: TextStyle(color: AppColors.gold, fontSize: 12)),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _openListen,
                  icon: const Icon(Icons.play_circle_outline, size: 16),
                  label: const Text('开始听书'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accentRed,
                    foregroundColor: AppColors.textPrimary,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '离线神经语音，逐页缓存、连续播放（不依赖手机系统语音）',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Future<void> _reOcrAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('重新识别全部页？',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
        content: const Text(
            '已识别的文字会被新结果覆盖（用新版分段），\n音频与照片不受影响。',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('重新识别', style: TextStyle(color: AppColors.gold)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) {
      return;
    }
    await widget.repository.resetPagesToPending(book.id);
    await _startOcr();
  }

  Widget _buildOcrSection() {
    if (!_ocrRunning) {
      return SizedBox(
        width: double.infinity,
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _startOcr,
                icon: const Icon(Icons.document_scanner_outlined, size: 16),
                label: const Text('识别全部文字（离线）'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.gold,
                  side: const BorderSide(color: AppColors.outline),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: _busy ? null : _reOcrAll,
              icon: const Icon(Icons.refresh, size: 18),
              color: AppColors.textSecondary,
              tooltip: '重新识别全部页（覆盖旧文字，音频保留）',
            ),
          ],
        ),
      );
    }
    final progress =
        _ocrTotal == 0 ? 0.0 : _ocrDone / _ocrTotal;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.outline),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _ocrStatus,
                  style: const TextStyle(
                      color: AppColors.textPrimary, fontSize: 13),
                ),
              ),
              IconButton(
                onPressed: () {
                  if (_ocrPaused) {
                    _ocrService?.resume();
                    setState(() => _ocrPaused = false);
                  } else {
                    _ocrService?.pause();
                    setState(() => _ocrPaused = true);
                  }
                },
                icon: Icon(
                  _ocrPaused ? Icons.play_arrow : Icons.pause,
                  size: 18,
                  color: AppColors.gold,
                ),
                tooltip: _ocrPaused ? '继续' : '暂停',
              ),
              IconButton(
                onPressed: () => _ocrService?.cancel(),
                icon: const Icon(Icons.close,
                    size: 18, color: AppColors.textSecondary),
                tooltip: '取消',
              ),
            ],
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: progress,
            minHeight: 4,
            backgroundColor: AppColors.surfaceHigh,
            color: AppColors.gold,
          ),
        ],
      ),
    );
  }
}

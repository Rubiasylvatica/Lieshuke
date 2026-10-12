import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Page;

import '../data/app_database.dart';
import '../data/book_repository.dart';
import '../theme/app_theme.dart';

/// 校对页：照片与识别文字对照，逐页修改错误；
/// 全书确认后可删除原照片（释放空间，文字永久保留）。
class ProofreadPage extends StatefulWidget {
  const ProofreadPage({
    super.key,
    required this.repository,
    required this.book,
    this.initialIndex = 0,
  });

  final BookRepository repository;
  final Book book;

  /// 打开后先定位到第几页（0 起，按全部页顺序）；阅读器跳转用。
  final int initialIndex;

  @override
  State<ProofreadPage> createState() => _ProofreadPageState();
}

class _ProofreadPageState extends State<ProofreadPage> {
  final _textCtrl = TextEditingController();
  StreamSubscription<List<Page>>? _sub;

  List<Page> _pages = const [];
  int? _chapterId; // null = 全部
  int _index = 0;
  int _lastLoadedPageId = -1;
  bool _dirty = false;
  bool _busy = false;
  bool _photosDeleted = false;

  // 待定位的初始页（打开后跳到这一页）
  int? _pendingInitialIndex;
  // 保存成功的金色闪动提示
  bool _flashSaved = false;

  Book get book => widget.book;

  @override
  void initState() {
    super.initState();
    _photosDeleted = book.photosDeleted;
    _pendingInitialIndex = widget.initialIndex;
    _subscribe();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _textCtrl.dispose();
    super.dispose();
  }

  void _subscribe() {
    _sub?.cancel();
    _sub = widget.repository
        .watchPages(book.id, chapterId: _chapterId)
        .listen((pages) {
      if (!mounted) {
        return;
      }
      setState(() {
        _pages = pages;
        if (_pages.isEmpty) {
          _index = 0;
          _lastLoadedPageId = -1;
          _dirty = false;
          _textCtrl.clear();
          return;
        }
        if (_pendingInitialIndex != null) {
          _index = _pendingInitialIndex!.clamp(0, _pages.length - 1).toInt();
          _pendingInitialIndex = null;
        } else if (_index >= _pages.length) {
          _index = _pages.length - 1;
        }
        final current = _pages[_index];
        if (current.id != _lastLoadedPageId) {
          _loadPage(current);
        }
      });
    });
  }

  void _loadPage(Page page) {
    _lastLoadedPageId = page.id;
    _dirty = false;
    _textCtrl.text = page.content;
  }

  Future<void> _saveCurrent({bool silent = false}) async {
    if (_lastLoadedPageId < 0) {
      return;
    }
    await widget.repository
        .savePageContent(_lastLoadedPageId, _textCtrl.text);
    _dirty = false;
    if (!silent && mounted) {
      // 保存成功：文字框底色闪一下金色，不弹提示条（避免挡住按钮）
      setState(() => _flashSaved = true);
      Future.delayed(const Duration(milliseconds: 900), () {
        if (mounted) {
          setState(() => _flashSaved = false);
        }
      });
    }
  }

  Future<void> _goTo(int newIndex) async {
    if (newIndex < 0 || newIndex >= _pages.length) {
      return;
    }
    if (_dirty) {
      await _saveCurrent(silent: true);
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _index = newIndex;
      _loadPage(_pages[newIndex]);
    });
  }

  void _snack(String msg) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  String _statusLabel(Page page) {
    switch (page.status) {
      case 'proofread':
        return '已校对';
      case 'recognized':
        return '已识别';
      default:
        return '待识别';
    }
  }

  Color _statusColor(Page page) {
    switch (page.status) {
      case 'proofread':
        return AppColors.gold;
      case 'recognized':
        return AppColors.textSecondary;
      default:
        return AppColors.accentRedPressed;
    }
  }

  Future<void> _finishProofread() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('全书校对完成？',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
        content: const Text(
            '确认后本书会被标记为「已校对」。之后仍可随时回来修改。',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('再改改',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('确认完成', style: TextStyle(color: AppColors.gold)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.repository.markProofreadDone(book.id);
      if (mounted) {
        _snack('已标记全书校对完成');
      }
    }
  }

  Future<void> _deletePhotos() async {
    setState(() => _busy = true);
    final int totalBytes;
    final int missingText;
    try {
      totalBytes = await widget.repository.photosTotalBytes(book.id);
      missingText = await widget.repository.pagesWithoutText(book.id);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
    if (!mounted) {
      return;
    }
    final sizeText = _formatBytes(totalBytes);
    final canDelete = missingText == 0 && _pages.isNotEmpty;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('删除原照片？',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '共 ${_pages.length} 张照片，可释放约 $sizeText。',
              style:
                  const TextStyle(color: AppColors.textPrimary, fontSize: 14),
            ),
            const SizedBox(height: 8),
            if (canDelete)
              const Text('每页文字都已保存，删除后电子书内容不受影响。',
                  style:
                      TextStyle(color: AppColors.textSecondary, fontSize: 13))
            else
              Text(
                missingText > 0
                    ? '还有 $missingText 页没有保存文字，不能删除。'
                    : '还没有照片可删除。',
                style: const TextStyle(
                    color: AppColors.accentRedPressed, fontSize: 13),
              ),
            const SizedBox(height: 4),
            const Text('此操作不可恢复。',
                style:
                    TextStyle(color: AppColors.textSecondary, fontSize: 13)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          if (canDelete)
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除照片',
                  style: TextStyle(color: AppColors.accentRedPressed)),
            ),
        ],
      ),
    );
    if (ok == true) {
      try {
        await widget.repository.deleteOriginalPhotos(book.id);
        if (mounted) {
          setState(() => _photosDeleted = true);
          _snack('原照片已删除，共释放 $sizeText');
        }
      } catch (e) {
        if (mounted) {
          _snack('删除失败：$e');
        }
      }
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('校对 · ${book.title}'),
        actions: [
          TextButton(
            onPressed: _busy ? null : _finishProofread,
            child: const Text('完成校对',
                style: TextStyle(color: AppColors.gold, fontSize: 13)),
          ),
          IconButton(
            tooltip: '删除原照片',
            onPressed: _busy ? null : _deletePhotos,
            icon: const Icon(Icons.delete_sweep_outlined,
                size: 20, color: AppColors.textSecondary),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildChapterRow(),
          const Divider(height: 1, color: AppColors.outline),
          Expanded(child: _buildBody()),
          _buildBottomBar(),
        ],
      ),
    );
  }

  Widget _buildChapterRow() {
    return StreamBuilder<List<Chapter>>(
      stream: widget.repository.watchChapters(book.id),
      builder: (context, snapshot) {
        final chapters = snapshot.data ?? const <Chapter>[];
        return SizedBox(
          height: 42,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            children: [
              _chip('全部', selected: _chapterId == null, onTap: () {
                setState(() => _chapterId = null);
                _subscribe();
              }),
              for (final c in chapters)
                _chip(c.title, selected: _chapterId == c.id, onTap: () {
                  setState(() => _chapterId = c.id);
                  _subscribe();
                }),
            ],
          ),
        );
      },
    );
  }

  Widget _chip(String label,
      {required bool selected, required VoidCallback onTap}) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: selected,
        onSelected: (_) => onTap(),
        backgroundColor: AppColors.surface,
        selectedColor: AppColors.surfaceHigh,
        checkmarkColor: AppColors.gold,
        showCheckmark: false,
        side: BorderSide(color: selected ? AppColors.gold : AppColors.outline),
        labelStyle: TextStyle(
          fontSize: 12,
          color: selected ? AppColors.textPrimary : AppColors.textSecondary,
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_pages.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_stories_outlined,
                size: 48, color: AppColors.textSecondary),
            SizedBox(height: 12),
            Text('没有可校对的书页',
                style: TextStyle(color: AppColors.textPrimary, fontSize: 15)),
            SizedBox(height: 6),
            Text('先去导入照片并识别文字吧',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
          ],
        ),
      );
    }
    final page = _pages[_index];
    return Column(
      children: [
        // 状态条
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              Text('第 ${_index + 1} / ${_pages.length} 页',
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 12)),
              const Spacer(),
              if (_dirty)
                const Text('未保存',
                    style: TextStyle(
                        color: AppColors.accentRedPressed, fontSize: 12)),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  border: Border.all(color: _statusColor(page)),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(_statusLabel(page),
                    style: TextStyle(
                        fontSize: 11, color: _statusColor(page))),
              ),
            ],
          ),
        ),
        // 照片区
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                color: AppColors.surface,
                child: _buildPhoto(page),
              ),
            ),
          ),
        ),
        // 文字编辑区
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              decoration: BoxDecoration(
                color: _flashSaved
                    ? const Color(0xFF3D3321)
                    : AppColors.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _flashSaved ? AppColors.gold : AppColors.outline,
                  width: _flashSaved ? 1.5 : 1,
                ),
              ),
              child: TextField(
                controller: _textCtrl,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    height: 1.7),
                decoration: const InputDecoration(
                  hintText: '识别出的文字会显示在这里，点一下即可修改…',
                  hintStyle: TextStyle(color: AppColors.textSecondary),
                  contentPadding: EdgeInsets.all(12),
                  border: InputBorder.none,
                ),
                onChanged: (_) {
                  if (!_dirty) {
                    setState(() => _dirty = true);
                  }
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPhoto(Page page) {
    final file = File(page.imagePath);
    // 先看文件在不在：重新导入过照片的书，即使曾删过照（photosDeleted 为真），
    // 新照片也应该正常显示，而不是误报「已删除」。
    if (file.existsSync()) {
      return InteractiveViewer(
        minScale: 1,
        maxScale: 5,
        child: Center(
          child: Image.file(
            file,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const Center(
              child: Icon(Icons.broken_image_outlined,
                  size: 40, color: AppColors.textSecondary),
            ),
          ),
        ),
      );
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_photosDeleted
              ? Icons.delete_outline
              : Icons.broken_image_outlined,
              size: 40, color: AppColors.textSecondary),
          const SizedBox(height: 8),
          Text(_photosDeleted ? '原照片已删除' : '照片文件不存在',
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 13)),
          if (_photosDeleted)
            const Text('文字内容已完整保留',
                style: TextStyle(
                    color: AppColors.textSecondary, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.outline)),
        ),
        child: Row(
          children: [
            OutlinedButton(
              onPressed: _busy || _index <= 0 ? null : () => _goTo(_index - 1),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textPrimary,
                side: const BorderSide(color: AppColors.outline),
              ),
              child: const Text('上一页'),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: _busy || _index >= _pages.length - 1
                  ? null
                  : () => _goTo(_index + 1),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textPrimary,
                side: const BorderSide(color: AppColors.outline),
              ),
              child: const Text('下一页'),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: _busy ? null : () => _saveCurrent(),
              icon: const Icon(Icons.save_outlined, size: 16),
              label: const Text('保存本页'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.gold,
                foregroundColor: AppColors.background,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

import 'dart:io';

import 'package:flutter/material.dart' hide Page;

import '../data/app_database.dart';
import '../data/book_repository.dart';
import '../theme/app_theme.dart';
import 'book_detail_page.dart';
import 'book_edit_page.dart';
import 'book_links_graph.dart';
import 'listen_page.dart';
import 'reader_page.dart';

/// 书的预览页：封皮 + 作者信息模块 + 章节直达阅读；
/// 扳手进编辑界面（导入/删除/校对），关联图标管理八爪鱼书关联。
class BookPreviewPage extends StatefulWidget {
  const BookPreviewPage({
    super.key,
    required this.repository,
    required this.book,
  });

  final BookRepository repository;
  final Book book;

  @override
  State<BookPreviewPage> createState() => _BookPreviewPageState();
}

class _BookPreviewPageState extends State<BookPreviewPage> {
  Book? _book;
  List<Chapter> _chapters = const [];
  List<Page> _pages = const [];
  List<Tag> _tags = const [];
  Map<int, Set<int>> _bookTagMap = const {};

  @override
  void initState() {
    super.initState();
    _book = widget.book;
    widget.repository.watchBook(widget.book.id).listen((b) {
      if (mounted && b != null) {
        setState(() => _book = b);
      }
    });
    widget.repository.watchChapters(widget.book.id).listen((chapters) {
      if (mounted) {
        setState(() => _chapters = chapters);
      }
    });
    widget.repository.watchPages(widget.book.id).listen((pages) {
      if (mounted) {
        setState(() => _pages = pages);
      }
    });
    widget.repository.watchTags().listen((tags) {
      if (mounted) {
        setState(() => _tags = tags);
      }
    });
    widget.repository.watchBookTagMap().listen((map) {
      if (mounted) {
        setState(() => _bookTagMap = map);
      }
    });
  }

  Book get book => _book ?? widget.book;

  /// 章节第一页在全书页序中的下标。
  int _chapterStartIndex(int chapterId) {
    final start = _pages
        .where((pg) => pg.chapterId == chapterId)
        .map((pg) => pg.orderIndex)
        .fold<int>(1 << 30, (m, o) => o < m ? o : m);
    final index = _pages.indexWhere((pg) => pg.orderIndex == start);
    return index < 0 ? 0 : index;
  }

  int _chapterPageCount(int chapterId) {
    return _pages.where((pg) => pg.chapterId == chapterId).length;
  }

  void _openReader({int initialPageIndex = 0}) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ReaderPage(
          repository: widget.repository,
          book: book,
          initialPageIndex: initialPageIndex,
        ),
      ),
    );
  }

  void _openEditor() {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            BookDetailPage(repository: widget.repository, book: book),
      ),
    );
  }

  void _openLinks() {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            BookLinksGraphPage(repository: widget.repository, book: book),
      ),
    );
  }

  void _openListen() {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            ListenPage(repository: widget.repository, book: book),
      ),
    );
  }

  List<String> _tagPaths() {
    final tagIds = _bookTagMap[book.id] ?? const <int>{};
    final byId = {for (final t in _tags) t.id: t};
    final paths = <String>[];
    for (final id in tagIds) {
      final parts = <String>[];
      int? cur = id;
      while (cur != null) {
        final tag = byId[cur];
        if (tag == null) {
          break;
        }
        parts.insert(0, tag.name);
        cur = tag.parentId;
      }
      paths.add(parts.join('/'));
    }
    paths.sort();
    return paths;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            backgroundColor: AppColors.background,
            title: Text(book.title),
            actions: [
              IconButton(
                tooltip: '编辑界面（导入/删除/校对）',
                onPressed: _openEditor,
                icon: const Icon(Icons.build_outlined,
                    size: 20, color: AppColors.textSecondary),
              ),
              IconButton(
                tooltip: '书关联（去往下一本）',
                onPressed: _openLinks,
                icon: const Icon(Icons.hub_outlined,
                    size: 20, color: AppColors.textSecondary),
              ),
            ],
          ),
          SliverToBoxAdapter(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildContent() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildCover(),
          const SizedBox(height: 16),
          _buildAuthorModule(),
          const SizedBox(height: 16),
          _buildReadButton(),
          const SizedBox(height: 20),
          _buildChapterList(),
        ],
      ),
    );
  }

  Widget _buildCover() {
    final cover = book.coverPath;
    final hasCover = cover != null && File(cover).existsSync();
    return Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 160,
          height: 220,
          color: AppColors.surfaceHigh,
          child: hasCover
              ? Image.file(File(cover), fit: BoxFit.cover)
              : const Center(
                  child: Icon(Icons.auto_stories_outlined,
                      size: 48, color: AppColors.textSecondary),
                ),
        ),
      ),
    );
  }

  Widget _buildAuthorModule() {
    final tags = _tagPaths();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  book.title,
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w700),
                ),
              ),
              InkWell(
                onTap: () async {
                  final changed = await Navigator.push<bool>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => BookEditPage(
                          repository: widget.repository, book: book),
                    ),
                  );
                  if (changed == true && mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('书籍信息已更新')),
                    );
                  }
                },
                borderRadius: BorderRadius.circular(6),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    children: [
                      Icon(Icons.edit_outlined,
                          size: 15, color: AppColors.gold),
                      SizedBox(width: 4),
                      Text('编辑',
                          style: TextStyle(
                              color: AppColors.gold, fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _infoRow(Icons.person_outline, '作者',
              book.author.isEmpty ? '未填写' : book.author),
          _infoRow(Icons.public_outlined, '国家',
              book.authorCountry.isEmpty ? '未填写' : book.authorCountry),
          _infoRow(Icons.history_edu_outlined, '出版时间',
              book.authorEra.isEmpty ? '未填写' : book.authorEra),
          if (book.totalReadSeconds > 0) ...[
            const SizedBox(height: 6),
            Text(
              '累计阅读 ${_fmtDuration(book.totalReadSeconds)}',
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 12),
            ),
          ],
          if (tags.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final path in tags)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.gold),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(path,
                        style: const TextStyle(
                            color: AppColors.gold, fontSize: 11)),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 15, color: AppColors.textSecondary),
          const SizedBox(width: 8),
          Text(label,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 13)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    color: AppColors.textPrimary, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _buildReadButton() {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: () => _openReader(),
        icon: const Icon(Icons.menu_book_outlined, size: 18),
        label: Text(_pages.isEmpty ? '开始阅读' : '开始阅读（${_pages.length} 页）'),
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.gold,
          foregroundColor: AppColors.background,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );
  }

  Widget _buildChapterList() {
    if (_chapters.isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('目录',
              style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          for (final c in _chapters)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.bookmark_outline,
                  size: 18, color: AppColors.gold),
              title: Text(c.title,
                  style: const TextStyle(
                      color: AppColors.textPrimary, fontSize: 14)),
              subtitle: Text('${_chapterPageCount(c.id)} 页',
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 11)),
              trailing: const Icon(Icons.chevron_right,
                  size: 18, color: AppColors.textSecondary),
              onTap: () => _openReader(
                  initialPageIndex: _chapterStartIndex(c.id)),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton.icon(
                onPressed: _openListen,
                icon: const Icon(Icons.headphones_outlined,
                    size: 16, color: AppColors.gold),
                label: const Text('听这本书',
                    style:
                        TextStyle(color: AppColors.gold, fontSize: 13)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _fmtDuration(int seconds) {
    final minutes = seconds ~/ 60;
    if (minutes < 60) {
      return '$minutes 分钟';
    }
    return '${minutes ~/ 60} 小时 ${minutes % 60} 分';
  }
}

import 'dart:async';

import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../data/book_repository.dart';
import '../theme/app_theme.dart';
import '../widgets/book_card.dart';
import 'book_edit_page.dart';
import 'book_preview_page.dart';
import 'category_browse_page.dart';
import 'tag_manage_page.dart';

/// 书架：封面卡片陈列，支持搜索、分类筛选、置顶。
class BookshelfPage extends StatefulWidget {
  const BookshelfPage({super.key, this.repository});

  /// 可注入的数据仓库（测试用）；为空时使用全局数据库实例。
  final BookRepository? repository;

  @override
  State<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends State<BookshelfPage> {
  late final _repo = widget.repository ?? BookRepository(AppDatabase.instance);
  final _searchCtrl = TextEditingController();

  String _query = '';
  bool _categoryView = false; // true = 分类卡片浏览，false = 最近读的卡片页（默认）

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      setState(() => _query = _searchCtrl.text.trim());
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _confirmDelete(Book book) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('删除这本书？',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
        content: Text(
          '将删除《${book.title}》及其全部页面与笔记，此操作不可恢复。',
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
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
      await _repo.deleteBook(book.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_categoryView ? '书架 · 分类' : '书架'),
        actions: [
          if (_categoryView)
            IconButton(
              tooltip: '管理分类',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => TagManagePage(repository: _repo),
                ),
              ),
              icon: const Icon(Icons.tune,
                  size: 20, color: AppColors.textSecondary),
            ),
        ],
      ),
      body: Column(
        children: [
          // 搜索框
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _searchCtrl,
              style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
              decoration: InputDecoration(
                hintText: '搜索书名 / 作者 / 国家 / 年代',
                hintStyle: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 13),
                prefixIcon: const Icon(Icons.search,
                    color: AppColors.textSecondary, size: 20),
                isDense: true,
                filled: true,
                fillColor: AppColors.surface,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: AppColors.outline),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: AppColors.accentRed),
                ),
              ),
            ),
          ),
          Expanded(
            child:
                _categoryView ? _buildCategoryRoot() : _buildRecentCards(),
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 视图切换：最近读卡片页 ↔ 分类卡片浏览
          FloatingActionButton.small(
            heroTag: 'viewSwitch',
            tooltip: _categoryView ? '回到最近读卡片页' : '按分类浏览',
            onPressed: () =>
                setState(() => _categoryView = !_categoryView),
            backgroundColor: AppColors.surfaceHigh,
            foregroundColor: AppColors.gold,
            child: Icon(_categoryView
                ? Icons.auto_stories_outlined
                : Icons.category_outlined),
          ),
          const SizedBox(height: 12),
          FloatingActionButton(
            heroTag: 'addBook',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => BookEditPage(repository: _repo),
                ),
              );
            },
            backgroundColor: AppColors.accentRed,
            foregroundColor: AppColors.textPrimary,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }

  void _openBook(Book book) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => BookPreviewPage(repository: _repo, book: book),
      ),
    );
  }

  /// 默认视图：按最近读的书排布的卡片页。
  Widget _buildRecentCards() {
    return StreamBuilder<List<Book>>(
      stream: _repo.watchAll(),
      builder: (context, snapshot) {
        final books = snapshot.data ?? const <Book>[];
        if (books.isEmpty) {
          return const _EmptyShelf();
        }
        final sorted = [...books]..sort((a, b) {
            final ar = a.lastReadAt;
            final br = b.lastReadAt;
            if (ar != null && br != null) {
              return br.compareTo(ar);
            }
            if (ar != null) {
              return -1;
            }
            if (br != null) {
              return 1;
            }
            return b.createdAt.compareTo(a.createdAt);
          });
        final filtered = sorted.where((b) {
          if (_query.isEmpty) {
            return true;
          }
          final q = _query.toLowerCase();
          final hay = '${b.title} ${b.author} ${b.authorCountry} ${b.authorEra}'
              .toLowerCase();
          return hay.contains(q);
        }).toList();
        if (filtered.isEmpty) {
          return const _EmptyShelf(searching: true);
        }
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: 0.62,
          ),
          itemCount: filtered.length,
          itemBuilder: (context, index) {
            final book = filtered[index];
            return BookCard(
              book: book,
              onTap: () => _openBook(book),
              onTogglePinned: () =>
                  _repo.setPinned(book.id, !book.pinned),
              onDelete: () => _confirmDelete(book),
            );
          },
        );
      },
    );
  }

  /// 分类视图根：一级分类卡片，点卡片进入下一级。
  Widget _buildCategoryRoot() {
    return StreamBuilder<List<Tag>>(
      stream: _repo.watchTags(),
      builder: (context, snapshot) {
        final tags = snapshot.data ?? const <Tag>[];
        final roots = tags.where((t) => t.parentId == null).toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
        if (roots.isEmpty) {
          return const Center(
            child: Text(
              '还没有分类\n新建书时输入分类（如：小说/中国/当代）即可',
              textAlign: TextAlign.center,
              style:
                  TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
          );
        }
        return FutureBuilder<Map<int, int>>(
          future: _repo.tagSubtreeBookCounts(),
          builder: (context, countSnapshot) {
            final counts = countSnapshot.data ?? const <int, int>{};
            return GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                childAspectRatio: 1.7,
              ),
              itemCount: roots.length,
              itemBuilder: (context, index) {
                final tag = roots[index];
                return _CategoryCard(
                  title: tag.name,
                  count: counts[tag.id] ?? 0,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => CategoryBrowsePage(
                        repository: _repo,
                        tagId: tag.id,
                        title: tag.name,
                      ),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

/// 分类卡片（书架分类浏览用）。
class _CategoryCard extends StatelessWidget {
  const _CategoryCard({
    required this.title,
    required this.count,
    required this.onTap,
  });

  final String title;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.outline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.folder_outlined,
                size: 20, color: AppColors.gold),
            const SizedBox(height: 8),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text('$count 本',
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

/// 书架空状态。
class _EmptyShelf extends StatelessWidget {
  const _EmptyShelf({this.searching = false});

  final bool searching;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.auto_stories_outlined,
              size: 56, color: AppColors.textSecondary),
          const SizedBox(height: 16),
          Text(
            searching ? '没有找到匹配的书' : '书架空空如也',
            style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary),
          ),
          const SizedBox(height: 8),
          Text(
            searching ? '换个关键词试试' : '点击右下角 + 新建你的第一本书',
            style: const TextStyle(
                fontSize: 13, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

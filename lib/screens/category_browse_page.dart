import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../data/book_repository.dart';
import '../theme/app_theme.dart';
import '../widgets/book_card.dart';
import 'book_preview_page.dart';

/// 分类浏览：显示某分类下的子分类卡片与书籍，点子分类卡片继续深入。
class CategoryBrowsePage extends StatefulWidget {
  const CategoryBrowsePage({
    super.key,
    required this.repository,
    required this.tagId,
    required this.title,
  });

  final BookRepository repository;
  final int tagId;
  final String title;

  @override
  State<CategoryBrowsePage> createState() => _CategoryBrowsePageState();
}

class _CategoryBrowsePageState extends State<CategoryBrowsePage> {
  List<Tag> _tags = const [];
  Map<int, Set<int>> _tagMap = const {};
  List<Book> _books = const [];

  @override
  void initState() {
    super.initState();
    widget.repository.watchTags().listen((tags) {
      if (mounted) {
        setState(() => _tags = tags);
      }
    });
    widget.repository.watchBookTagMap().listen((map) {
      if (mounted) {
        setState(() => _tagMap = map);
      }
    });
    widget.repository.watchAll().listen((books) {
      if (mounted) {
        setState(() => _books = books);
      }
    });
  }

  /// 本分类及其全部子分类 id。
  Set<int> _subtreeIds() {
    final childrenOf = <int, List<int>>{};
    for (final t in _tags) {
      childrenOf.putIfAbsent(t.parentId ?? 0, () => []).add(t.id);
    }
    final result = <int>{};
    void collect(int id) {
      result.add(id);
      for (final c in childrenOf[id] ?? const <int>[]) {
        collect(c);
      }
    }

    collect(widget.tagId);
    return result;
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
      await widget.repository.deleteBook(book.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final children = _tags
        .where((t) => t.parentId == widget.tagId)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final subtree = _subtreeIds();
    final books = _booksInSubtree(subtree);
    return Scaffold(
      appBar: AppBar(title: Text('分类 · ${widget.title}')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          if (children.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('子分类',
                  style: TextStyle(
                      color: AppColors.gold,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.7,
              ),
              itemCount: children.length,
              itemBuilder: (context, index) =>
                  _childCard(children[index]),
            ),
            const SizedBox(height: 16),
          ],
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('书籍（${books.length}）',
                style: const TextStyle(
                    color: AppColors.gold,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
          ),
          if (books.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text('这个分类下还没有书',
                    style: TextStyle(
                        color: AppColors.textSecondary, fontSize: 13)),
              ),
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                childAspectRatio: 0.62,
              ),
              itemCount: books.length,
              itemBuilder: (context, index) {
                final book = books[index];
                return BookCard(
                  book: book,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => BookPreviewPage(
                          repository: widget.repository, book: book),
                    ),
                  ),
                  onTogglePinned: () => widget.repository
                      .setPinned(book.id, !book.pinned),
                  onDelete: () => _confirmDelete(book),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _childCard(Tag tag) {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => CategoryBrowsePage(
            repository: widget.repository,
            tagId: tag.id,
            title: '${widget.title} / ${tag.name}',
          ),
        ),
      ),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surfaceHigh,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.outline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.folder_open_outlined,
                size: 18, color: AppColors.gold),
            const SizedBox(height: 6),
            Text(
              tag.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600),
            ),
            Text('${_countOf(tag.id)} 本',
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  int _countOf(int tagId) {
    final childrenOf = <int, List<int>>{};
    for (final t in _tags) {
      childrenOf.putIfAbsent(t.parentId ?? 0, () => []).add(t.id);
    }
    final subtree = <int>{};
    void collect(int id) {
      subtree.add(id);
      for (final c in childrenOf[id] ?? const <int>[]) {
        collect(c);
      }
    }

    collect(tagId);
    final seenBooks = <int>{};
    for (final entry in _tagMap.entries) {
      if (entry.value.intersection(subtree).isNotEmpty) {
        seenBooks.add(entry.key);
      }
    }
    return seenBooks.length;
  }

  List<Book> _booksInSubtree(Set<int> subtree) {
    final result = _books.where((b) {
      final bookTags = _tagMap[b.id] ?? const <int>{};
      return bookTags.intersection(subtree).isNotEmpty;
    }).toList()
      ..sort((a, b) {
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
    return result;
  }
}


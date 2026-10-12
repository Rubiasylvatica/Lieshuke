import 'dart:io';

import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../data/book_repository.dart';
import '../theme/app_theme.dart';
import 'book_preview_page.dart';

/// 书关联页：本书出发指向的书（八爪鱼多出边）可增删改、标已读/未读、点击跳转；
/// 指向本书的书只读展示（入边由别的书决定）。
class BookLinksPage extends StatefulWidget {
  const BookLinksPage({
    super.key,
    required this.repository,
    required this.book,
  });

  final BookRepository repository;
  final Book book;

  @override
  State<BookLinksPage> createState() => _BookLinksPageState();
}

class _BookLinksPageState extends State<BookLinksPage> {
  Book get book => widget.book;

  void _openBook(Book target) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            BookPreviewPage(repository: widget.repository, book: target),
      ),
    );
  }

  Future<void> _addLink(List<Book> allBooks) async {
    // 过滤：排除自己与已关联的书
    final existing = <int>{};
    for (final (_, target) in await widget.repository
        .watchOutLinks(book.id)
        .first) {
      existing.add(target.id);
    }
    final candidates =
        allBooks.where((b) => b.id != book.id && !existing.contains(b.id)).toList();
    if (!mounted) {
      return;
    }
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有可关联的书了')));
      return;
    }
    Book? chosen;
    final noteCtrl = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('这本书接着去往哪一本？',
              style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioGroup<int>(
                groupValue: chosen?.id,
                onChanged: (v) => setDlg(() =>
                    chosen = candidates.firstWhere((b) => b.id == v)),
                child: SizedBox(
                height: 220,
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: candidates.length,
                  itemBuilder: (ctx, i) {
                    final b = candidates[i];
                    return RadioListTile<int>(
                      dense: true,
                      value: b.id,
                      activeColor: AppColors.gold,
                      title: Text(b.title,
                          style: const TextStyle(
                              color: AppColors.textPrimary, fontSize: 14)),
                      subtitle: b.author.isEmpty
                          ? null
                          : Text(b.author,
                              style: const TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 11)),
                    );
                  },
                ),
              ),
              ),
              TextField(
                controller: noteCtrl,
                style: const TextStyle(color: AppColors.textPrimary),
                decoration: const InputDecoration(
                  hintText: '关系备注（如：提到了这本书）',
                  hintStyle: TextStyle(color: AppColors.textSecondary),
                  filled: true,
                  fillColor: AppColors.surfaceHigh,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消',
                  style: TextStyle(color: AppColors.textSecondary)),
            ),
            TextButton(
              onPressed: chosen == null
                  ? null
                  : () => Navigator.pop(ctx, true),
              child: const Text('添加关联',
                  style: TextStyle(color: AppColors.gold)),
            ),
          ],
        ),
      ),
    );
    if (result == true && chosen != null) {
      await widget.repository
          .addLink(book.id, chosen!.id, noteCtrl.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('关联 · ${book.title}'),
        actions: [
          IconButton(
            tooltip: '添加关联',
            onPressed: () async {
              final all = await widget.repository.watchAll().first;
              await _addLink(all);
            },
            icon: const Icon(Icons.add_link,
                size: 20, color: AppColors.gold),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('从这本书出发（八爪鱼）',
                style: TextStyle(
                    color: AppColors.gold,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
          ),
          StreamBuilder<List<(BookLink, Book)>>(
            stream: widget.repository.watchOutLinks(book.id),
            builder: (context, snapshot) {
              final links = snapshot.data ?? const <(BookLink, Book)>[];
              if (links.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('还没有关联。点右上角「＋」添加下一本要读的书。',
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 13)),
                );
              }
              return Column(
                children: [
                  for (final (link, target) in links)
                    _linkTile(link, target, editable: true),
                ],
              );
            },
          ),
          const SizedBox(height: 20),
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('指向这本书的（由别的书决定）',
                style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
          ),
          StreamBuilder<List<(BookLink, Book)>>(
            stream: widget.repository.watchInLinks(book.id),
            builder: (context, snapshot) {
              final links = snapshot.data ?? const <(BookLink, Book)>[];
              if (links.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('还没有别的书指向这本。',
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 13)),
                );
              }
              return Column(
                children: [
                  for (final (link, fromBook) in links)
                    _linkTile(link, fromBook, editable: false),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _linkTile(BookLink link, Book target,
      {required bool editable}) {
    final cover = target.coverPath;
    final hasCover = cover != null && File(cover).existsSync();
    return GestureDetector(
      onTap: () => _openBook(target),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.outline),
        ),
        child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Container(
              width: 44,
              height: 62,
              color: AppColors.surfaceHigh,
              child: hasCover
                  ? Image.file(File(cover), fit: BoxFit.cover)
                  : const Icon(Icons.auto_stories_outlined,
                      size: 20, color: AppColors.textSecondary),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(target.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
                if (link.note.isNotEmpty)
                  Text(link.note,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.textSecondary, fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (editable)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert,
                  size: 18, color: AppColors.textSecondary),
              onSelected: (v) => _linkAction(link, v),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'read', child: Text('标记已读/未读')),
                PopupMenuItem(value: 'edit', child: Text('修改备注')),
                PopupMenuItem(value: 'delete', child: Text('删除关联')),
              ],
            ),
          if (editable)
            GestureDetector(
              onTap: () => widget.repository
                  .setLinkRead(link.id, !link.read),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  border: Border.all(
                      color: link.read
                          ? AppColors.textSecondary
                          : AppColors.gold),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  link.read ? '已读' : '未读',
                  style: TextStyle(
                      fontSize: 11,
                      color: link.read
                          ? AppColors.textSecondary
                          : AppColors.gold),
                ),
              ),
            ),
          if (!editable)
            const Icon(Icons.subdirectory_arrow_right,
                size: 16, color: AppColors.textSecondary),
        ],
        ),
      ),
    );
  }

  Future<void> _linkAction(BookLink link, String action) async {
    if (action == 'read') {
      await widget.repository.setLinkRead(link.id, !link.read);
    } else if (action == 'edit') {
      final ctrl = TextEditingController(text: link.note);
      final result = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('修改关系备注',
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
              child: const Text('保存', style: TextStyle(color: AppColors.gold)),
            ),
          ],
        ),
      );
      if (result != null) {
        await widget.repository.updateLinkNote(link.id, result);
      }
    } else if (action == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('删除这条关联？',
              style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
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
        await widget.repository.deleteLink(link.id);
      }
    }
  }
}

import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../data/book_repository.dart';
import '../theme/app_theme.dart';

/// 标签管理：树形列表，可重命名、删除（连带子分类）。
class TagManagePage extends StatefulWidget {
  const TagManagePage({super.key, required this.repository});

  final BookRepository repository;

  @override
  State<TagManagePage> createState() => _TagManagePageState();
}

class _TagManagePageState extends State<TagManagePage> {
  List<Tag> _tags = [];
  Map<int, int> _counts = {};

  @override
  void initState() {
    super.initState();
    widget.repository.watchTags().listen((tags) {
      if (mounted) {
        setState(() => _tags = tags);
        _refreshCounts();
      }
    });
    widget.repository.watchBookTagMap().listen((map) {
      if (mounted) {
        _refreshCounts();
      }
    });
  }

  Future<void> _refreshCounts() async {
    final counts = await widget.repository.tagSubtreeBookCounts();
    if (mounted) {
      setState(() => _counts = counts);
    }
  }

  Map<int, List<Tag>> get _childrenOf {
    final map = <int, List<Tag>>{};
    for (final t in _tags) {
      map.putIfAbsent(t.parentId ?? 0, () => []).add(t);
    }
    return map;
  }

  Future<void> _rename(Tag tag) async {
    final ctrl = TextEditingController(text: tag.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('重命名分类',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: InputDecoration(
            hintText: '新的分类名',
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
            child: const Text('确定',
                style: TextStyle(color: AppColors.gold)),
          ),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty && newName != tag.name) {
      await widget.repository.renameTag(tag.id, newName);
    }
  }

  Future<void> _delete(Tag tag) async {
    final hasKids = (_childrenOf[tag.id] ?? []).isNotEmpty;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('删除分类？',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
        content: Text(
          hasKids
              ? '「${tag.name}」还有子分类，删除会一并删除其全部子分类和与书的关联。'
              : '将删除「${tag.name}」及与书的关联。',
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
      await widget.repository.deleteTagWithSubtree(tag.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final childrenOf = _childrenOf;
    final roots = childrenOf[0] ?? const <Tag>[];
    return Scaffold(
      appBar: AppBar(title: const Text('管理标签')),
      body: _tags.isEmpty
          ? const Center(
              child: Text('还没有分类，新建书时可以输入路径创建',
                  style: TextStyle(
                      color: AppColors.textSecondary, fontSize: 13)))
          : ListView(
              children: [
                for (final root in roots) _node(root, 0, childrenOf),
              ],
            ),
    );
  }

  Widget _node(Tag tag, int depth, Map<int, List<Tag>> childrenOf) {
    final kids = childrenOf[tag.id] ?? const <Tag>[];
    final count = _counts[tag.id] ?? 0;
    return Column(
      children: [
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.only(left: 16.0 + depth * 22, right: 8),
          leading: kids.isEmpty
              ? const Icon(Icons.label_outline,
                  size: 18, color: AppColors.textSecondary)
              : const Icon(Icons.folder_outlined,
                  size: 18, color: AppColors.gold),
          title: Text(
            tag.name,
            style: const TextStyle(
                fontSize: 14, color: AppColors.textPrimary),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$count 本',
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textSecondary),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert,
                    size: 18, color: AppColors.textSecondary),
                color: AppColors.surfaceHigh,
                onSelected: (v) {
                  if (v == 'rename') {
                    _rename(tag);
                  } else if (v == 'delete') {
                    _delete(tag);
                  }
                },
                itemBuilder: (ctx) => [
                  const PopupMenuItem(
                    value: 'rename',
                    child: Text('重命名',
                        style: TextStyle(
                            color: AppColors.textPrimary, fontSize: 14)),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text('删除',
                        style: TextStyle(
                            color: AppColors.accentRedPressed, fontSize: 14)),
                  ),
                ],
              ),
            ],
          ),
        ),
        for (final kid in kids) _node(kid, depth + 1, childrenOf),
      ],
    );
  }
}

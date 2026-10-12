import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../data/book_repository.dart';
import '../theme/app_theme.dart';

/// 分类筛选面板：树形展示，点选节点即筛选（含其全部子分类）。
/// 返回：0 = 全部；-1 = 打开标签管理；其他 = 选中分类 id。
class TagFilterSheet extends StatefulWidget {
  const TagFilterSheet({
    super.key,
    required this.repository,
    this.selectedTagId,
  });

  final BookRepository repository;
  final int? selectedTagId;

  @override
  State<TagFilterSheet> createState() => _TagFilterSheetState();
}

class _TagFilterSheetState extends State<TagFilterSheet> {
  final Set<int> _expanded = {};
  List<Tag> _tags = [];

  @override
  void initState() {
    super.initState();
    widget.repository.watchTags().listen((tags) {
      if (mounted) {
        setState(() => _tags = tags);
      }
    });
  }

  Map<int, List<Tag>> get _childrenOf {
    final map = <int, List<Tag>>{};
    for (final t in _tags) {
      map.putIfAbsent(t.parentId ?? 0, () => []).add(t);
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    final childrenOf = _childrenOf;
    final roots = childrenOf[0] ?? const <Tag>[];
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.66,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                '按分类筛选',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.menu_book_outlined,
                  color: AppColors.textSecondary),
              title: const Text('全部',
                  style: TextStyle(
                      color: AppColors.textPrimary, fontSize: 14)),
              trailing: widget.selectedTagId == null
                  ? const Icon(Icons.check, color: AppColors.gold, size: 18)
                  : null,
              onTap: () => Navigator.pop(context, 0),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.edit_outlined,
                  color: AppColors.textSecondary),
              title: const Text('管理标签',
                  style: TextStyle(
                      color: AppColors.textSecondary, fontSize: 14)),
              onTap: () => Navigator.pop(context, -1),
            ),
            const Divider(height: 1, color: AppColors.outline),
            Expanded(
              child: _tags.isEmpty
                  ? const Center(
                      child: Text('还没有分类，新建书时可以输入路径创建',
                          style: TextStyle(
                              color: AppColors.textSecondary, fontSize: 13)))
                  : ListView(
                      children: [
                        for (final root in roots)
                          _node(context, root, 0, childrenOf),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _node(
      BuildContext ctx, Tag tag, int depth, Map<int, List<Tag>> childrenOf) {
    final kids = childrenOf[tag.id] ?? const <Tag>[];
    final hasKids = kids.isNotEmpty;
    final expanded = _expanded.contains(tag.id);
    final selected = widget.selectedTagId == tag.id;
    return Column(
      children: [
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.only(left: 16.0 + depth * 22, right: 8),
          leading: hasKids
              ? InkWell(
                  onTap: () => setState(() {
                    expanded
                        ? _expanded.remove(tag.id)
                        : _expanded.add(tag.id);
                  }),
                  child: Icon(
                    expanded ? Icons.expand_more : Icons.chevron_right,
                    color: AppColors.textSecondary,
                    size: 22,
                  ),
                )
              : const SizedBox(width: 22),
          title: Text(
            tag.name,
            style: TextStyle(
              fontSize: 14,
              color: selected ? AppColors.gold : AppColors.textPrimary,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
          trailing: selected
              ? const Icon(Icons.check, color: AppColors.gold, size: 18)
              : null,
          onTap: () => Navigator.pop(ctx, tag.id),
        ),
        if (hasKids && expanded)
          for (final kid in kids) _node(ctx, kid, depth + 1, childrenOf),
      ],
    );
  }
}

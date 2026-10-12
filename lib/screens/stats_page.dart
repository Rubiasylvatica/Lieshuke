import 'dart:async';

import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../data/book_repository.dart';
import '../theme/app_theme.dart';

/// 统计页：只保留每本书「加入时间」与「读完时间」。
class StatsPage extends StatefulWidget {
  const StatsPage({super.key, this.repository});

  final BookRepository? repository;

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  late final _repo = widget.repository ?? BookRepository(AppDatabase.instance);
  StreamSubscription<List<Book>>? _booksSub;

  List<Book> _books = const [];

  @override
  void initState() {
    super.initState();
    _booksSub = _repo.watchAll().listen((books) {
      if (mounted) {
        setState(() => _books = books);
      }
    });
  }

  @override
  void dispose() {
    _booksSub?.cancel();
    super.dispose();
  }

  static String _formatDate(DateTime t) {
    return '${t.year}年${t.month}月${t.day}日';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('统计')),
      body: _books.isEmpty
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.history_outlined,
                      size: 48, color: AppColors.textSecondary),
                  SizedBox(height: 12),
                  Text('还没有书籍',
                      style: TextStyle(
                          color: AppColors.textPrimary, fontSize: 15)),
                  SizedBox(height: 6),
                  Text('添加书籍后，这里会显示加入和读完的时间',
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 12)),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                for (final b in _books)
                  Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.outline),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          b.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        _row(Icons.library_add_outlined, '加入时间',
                            _formatDate(b.createdAt)),
                        const SizedBox(height: 4),
                        _row(
                          Icons.check_circle_outline,
                          '读完时间',
                          b.finishedAt == null
                              ? '未读完'
                              : _formatDate(b.finishedAt!),
                          valueColor: b.finishedAt == null
                              ? AppColors.textSecondary
                              : AppColors.gold,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _row(IconData icon, String label, String value,
      {Color valueColor = AppColors.textPrimary}) {
    return Row(
      children: [
        Icon(icon, size: 14, color: AppColors.gold),
        const SizedBox(width: 6),
        Text(label,
            style: const TextStyle(
                color: AppColors.textSecondary, fontSize: 12)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: TextStyle(color: valueColor, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

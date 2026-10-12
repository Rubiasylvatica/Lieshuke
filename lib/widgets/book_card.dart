import 'dart:io';

import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../theme/app_theme.dart';

/// 书架封面卡片：2:3 封面 + 底部渐变叠书名 + 置顶标记。
class BookCard extends StatelessWidget {
  const BookCard({
    super.key,
    required this.book,
    required this.onTap,
    required this.onTogglePinned,
    required this.onDelete,
  });

  final Book book;
  final VoidCallback onTap;
  final VoidCallback onTogglePinned;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: () => _showMenu(context),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border.all(color: AppColors.outline),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildCover(),
              // 底部渐变叠书名
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(10, 28, 10, 10),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0xD91F1A16)],
                    ),
                  ),
                  child: Text(
                    book.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              // 置顶标记
              if (book.pinned)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: const Color(0xB31F1A16),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(
                      Icons.push_pin,
                      size: 14,
                      color: AppColors.gold,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCover() {
    final path = book.coverPath;
    if (path == null || path.isEmpty || !File(path).existsSync()) {
      return Container(
        color: AppColors.surfaceHigh,
        child: const Center(
          child: Icon(
            Icons.auto_stories_outlined,
            size: 40,
            color: AppColors.textSecondary,
          ),
        ),
      );
    }
    return Image.file(
      File(path),
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => Container(
        color: AppColors.surfaceHigh,
        child: const Center(
          child: Icon(
            Icons.broken_image_outlined,
            size: 32,
            color: AppColors.textSecondary,
          ),
        ),
      ),
    );
  }

  void _showMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Text(
              book.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: Icon(
                book.pinned ? Icons.push_pin_outlined : Icons.push_pin,
                color: book.pinned ? AppColors.gold : AppColors.textSecondary,
              ),
              title: Text(
                book.pinned ? '取消置顶' : '置顶',
                style: const TextStyle(color: AppColors.textPrimary),
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                onTogglePinned();
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline,
                color: AppColors.accentRedPressed,
              ),
              title: const Text(
                '删除这本书',
                style: TextStyle(color: AppColors.accentRedPressed),
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                onDelete();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

import 'dart:io';

import 'package:flutter/material.dart' hide Page;

import '../data/app_database.dart';
import '../data/book_repository.dart';
import '../theme/app_theme.dart';

/// 原页照片查看：整页原图（含插图）完整显示，可左右翻页、双指缩放。
/// 阅读器与校对页都可从这里查看某一页的原始版面。
class PhotoViewerPage extends StatefulWidget {
  const PhotoViewerPage({
    super.key,
    required this.repository,
    required this.book,
    this.initialIndex = 0,
  });

  final BookRepository repository;
  final Book book;
  final int initialIndex;

  @override
  State<PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<PhotoViewerPage> {
  List<Page> _pages = const [];
  int _index = 0;
  late final PageController _controller;

  @override
  void initState() {
    super.initState();
    _controller = PageController(initialPage: widget.initialIndex);
    _index = widget.initialIndex;
    widget.repository.watchPages(widget.book.id).first.then((pages) {
      if (mounted) {
        setState(() {
          _pages = pages;
          _index = _index.clamp(0, pages.isEmpty ? 0 : pages.length - 1);
        });
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        title: Text('原页照片 · ${widget.book.title}'),
        actions: [
          if (_pages.isNotEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Text('${_index + 1} / ${_pages.length}',
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 13)),
              ),
            ),
        ],
      ),
      body: _pages.isEmpty
          ? const Center(
              child: Text('没有照片',
                  style: TextStyle(
                      color: AppColors.textSecondary, fontSize: 14)),
            )
          : PageView.builder(
              controller: _controller,
              itemCount: _pages.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, i) => _buildPhoto(_pages[i]),
            ),
    );
  }

  Widget _buildPhoto(Page page) {
    final file = File(page.imagePath);
    if (!file.existsSync()) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.image_not_supported_outlined,
                size: 48, color: AppColors.textSecondary),
            SizedBox(height: 12),
            Text('原照片已删除',
                style: TextStyle(
                    color: AppColors.textSecondary, fontSize: 13)),
          ],
        ),
      );
    }
    return InteractiveViewer(
      minScale: 1,
      maxScale: 5,
      child: Center(
        child: Image.file(
          file,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => const Center(
            child: Icon(Icons.broken_image_outlined,
                size: 48, color: AppColors.textSecondary),
          ),
        ),
      ),
    );
  }
}

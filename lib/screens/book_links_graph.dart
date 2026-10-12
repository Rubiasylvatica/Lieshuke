import 'dart:io';

import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../data/book_repository.dart';
import '../theme/app_theme.dart';
import 'book_preview_page.dart';

/// 书关联（链式图）：
/// - 无右上角按钮：直接点击“虚线框 + 加号”选择要关联的书；
/// - 中央是本书，右侧依次生长：书 → 虚线框 → 书 → 虚线框…（链式、可横滑）；
/// - 每本关联书右上角有“小三角”角标：绿色=已读完、金色=阅读中、灰色=未读；
/// - 下方是来源（指向本书的书，保留“来源在下”的语义）；
/// - 点关联书弹出操作（打开 / 改备注 / 删除）。
class BookLinksGraphPage extends StatefulWidget {
  const BookLinksGraphPage({
    super.key,
    required this.repository,
    required this.book,
  });

  final BookRepository repository;
  final Book book;

  @override
  State<BookLinksGraphPage> createState() => _BookLinksGraphPageState();
}

class _BookLinksGraphPageState extends State<BookLinksGraphPage> {
  List<(BookLink, Book)> _out = const [];
  List<(BookLink, Book)> _in = const [];

  Book get book => widget.book;

  @override
  void initState() {
    super.initState();
    widget.repository.watchOutLinks(book.id).listen((links) {
      if (mounted) {
        setState(() => _out = links);
      }
    });
    widget.repository.watchInLinks(book.id).listen((links) {
      if (mounted) {
        setState(() => _in = links);
      }
    });
  }

  /// 阅读状态角标颜色：已读完=绿，阅读中=金，未读=灰。
  static Color _readColor(Book b) {
    if (b.readPercent >= 95) {
      return const Color(0xFF7FA86B);
    }
    if (b.readPercent <= 0) {
      return AppColors.textSecondary;
    }
    return AppColors.gold;
  }

  static String _readLabel(Book b) {
    if (b.readPercent >= 95) {
      return '已读完';
    }
    if (b.readPercent <= 0) {
      return '未读';
    }
    return '阅读中 ${b.readPercent}%';
  }

  void _openBook(Book target) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            BookPreviewPage(repository: widget.repository, book: target),
      ),
    );
  }

  /// 点“虚线框 + 加号”选择下一本关联书（替代原右上角按钮）。
  Future<void> _pickNext() async {
    final allBooks = await widget.repository.watchAll().first;
    final existing = _out.map((e) => e.$2.id).toSet();
    final candidates = allBooks
        .where((b) => b.id != book.id && !existing.contains(b.id))
        .toList();
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
          title: const Text('接下来去读哪一本？',
              style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioGroup<int>(
                groupValue: chosen?.id,
                onChanged: (v) => setDlg(
                    () => chosen = candidates.firstWhere((b) => b.id == v)),
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
                  hintText: '备注（为什么接着读这本）',
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
              onPressed:
                  chosen == null ? null : () => Navigator.pop(ctx, true),
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

  Future<void> _linkMenu(BookLink link, Book target) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Text('《${target.title}》',
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
            if (link.note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(link.note,
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 12)),
              ),
            ListTile(
              leading: const Icon(Icons.menu_book_outlined,
                  color: AppColors.textSecondary),
              title: const Text('打开这本书',
                  style: TextStyle(color: AppColors.textPrimary)),
              onTap: () => Navigator.pop(ctx, 'open'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_note,
                  color: AppColors.textSecondary),
              title: const Text('修改备注',
                  style: TextStyle(color: AppColors.textPrimary)),
              onTap: () => Navigator.pop(ctx, 'note'),
            ),
            ListTile(
              leading: const Icon(Icons.link_off,
                  color: AppColors.accentRedPressed),
              title: const Text('删除这条关联',
                  style: TextStyle(color: AppColors.accentRedPressed)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null || !mounted) {
      return;
    }
    if (action == 'open') {
      _openBook(target);
    } else if (action == 'note') {
      final ctrl = TextEditingController(text: link.note);
      final result = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('修改备注',
              style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: const InputDecoration(
              hintText: '为什么接着读这本…',
              hintStyle: TextStyle(color: AppColors.textSecondary),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('关联 · ${book.title}')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // —— 上三分之一：关联书 + 虚框（与书图标同尺寸的竖向矩形，可横滑）——
          // 底部 stem 的横线即“T”的横梁，节点底部有短竖线接入横梁。
          Expanded(
            flex: 3,
            child: _buildOutLane(),
          ),
          // —— 中央竖线：从上方横梁一路连到本书顶部（连续不断开）——
          Expanded(
            flex: 1,
            child: SizedBox(
              width: double.infinity,
              child: CustomPaint(painter: _VerticalLinkPainter()),
            ),
          ),
          // —— 本书：顶部贴着竖线底端 ——
          Expanded(
            flex: 3,
            child: Align(
              alignment: Alignment.topCenter,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _bookNode(
                    width: 120,
                    height: 164,
                    target: book,
                    self: true,
                  ),
                  const SizedBox(height: 8),
                  Text('本书',
                      style: TextStyle(
                          color: AppColors.textSecondary
                              .withValues(alpha: 0.85),
                          fontSize: 11)),
                ],
              ),
            ),
          ),
          // —— 来源区（下方）：指向本书的书 ——
          if (_in.isNotEmpty)
            SizedBox(
              height: 150,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                itemCount: _in.length,
                itemBuilder: (ctx, j) => Padding(
                  padding: const EdgeInsets.only(right: 14),
                  child: _bookNode(
                    width: 78,
                    height: 106,
                    target: _in[j].$2,
                    self: false,
                    onTap: () => _openBook(_in[j].$2),
                  ),
                ),
              ),
            )
          else
            const SizedBox(height: 12),
        ],
      ),
    );
  }

  /// 上方横向阅读路径：关联书与“加号虚框”同尺寸（100×140 竖向矩形），
  /// 底部一条实线把各节点相连，并经 [_VerticalLinkPainter] 接到本书。
  Widget _buildOutLane() {
    const double nodeW = 100;
    const double nodeH = 140;
    const double gap = 16; // 节点间距（也是每侧 stem 伸出量）
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < _out.length; i++)
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _bookNode(
                  width: nodeW,
                  height: nodeH,
                  target: _out[i].$2,
                  self: false,
                  onTap: () => _linkMenu(_out[i].$1, _out[i].$2),
                  note: _out[i].$1.note,
                ),
                _stem(width: nodeW + gap, height: 26),
              ],
            ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _addSlot(width: nodeW, height: nodeH, onTap: _pickNext),
              _stem(width: nodeW + gap, height: 26),
            ],
          ),
          const SizedBox(width: 24),
        ],
      ),
    );
  }

  /// 节点底部的连接段：中央竖线 + 向两侧各伸出半个间距的横线，
  /// 相邻节点的横线首尾相接，形成一条贯穿的实线。
  Widget _stem({required double width, required double height}) {
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        painter: _StemPainter(),
      ),
    );
  }

  Widget _addSlot({
    required double width,
    required double height,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: width,
        height: height,
        child: CustomPaint(
          painter: const _DashedBorderPainter(),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.add, size: 30, color: AppColors.gold),
                const SizedBox(height: 8),
                Text('添加关联',
                    style: TextStyle(
                        color: AppColors.gold.withValues(alpha: 0.9),
                        fontSize: 11)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bookNode({
    required double width,
    required double height,
    required Book target,
    required bool self,
    VoidCallback? onTap,
    String note = '',
  }) {
    final cover = target.coverPath;
    final hasCover = cover != null && File(cover).existsSync();
    final node = SizedBox(
      width: width,
      height: height,
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: width,
              height: height,
              color: AppColors.surfaceHigh,
              child: hasCover
                  ? Image.file(File(cover), fit: BoxFit.cover)
                  : const Center(
                      child: Icon(Icons.auto_stories_outlined,
                          size: 26, color: AppColors.textSecondary),
                    ),
            ),
          ),
          // 封面下沿书名条
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
              decoration: const BoxDecoration(
                color: Color(0xCC1F1A16),
                borderRadius:
                    BorderRadius.vertical(bottom: Radius.circular(8)),
              ),
              child: Text(
                target.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.textPrimary, fontSize: 10),
              ),
            ),
          ),
          // 右上角小三角角标（仅关联书）：绿=已读完，金=阅读中，灰=未读
          if (!self)
            Positioned(
              top: 0,
              right: 0,
              child: Tooltip(
                message: _readLabel(target),
                child: CustomPaint(
                  painter: _TriangleBadgePainter(_readColor(target)),
                  size: const Size(24, 24),
                ),
              ),
            ),
        ],
      ),
    );
    return GestureDetector(onTap: onTap, child: node);
  }
}

/// 节点底部连接段：中央竖线 + 贯穿左右的横线。
class _StemPainter extends CustomPainter {
  const _StemPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.gold.withValues(alpha: 0.6)
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final cx = size.width / 2;
    // 竖线：从节点底部到横线
    canvas.drawLine(Offset(cx, 0), Offset(cx, size.height), paint);
    // 横线：贯穿整个连接段（相邻节点首尾相接成总线）
    canvas.drawLine(
        Offset(0, size.height), Offset(size.width, size.height), paint);
  }

  @override
  bool shouldRepaint(_StemPainter oldDelegate) => false;
}

/// 中央竖线：从上方横梁（本区域顶部，即总线所在）一路画到本区域底部，
/// 底部紧贴本书顶部，视觉上与横梁形成连续不断的“T”形。
class _VerticalLinkPainter extends CustomPainter {
  const _VerticalLinkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.gold.withValues(alpha: 0.6)
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final cx = size.width / 2;
    // 整条竖线：顶端与上方 stem 横线相接，底端正好落在本书顶部。
    canvas.drawLine(Offset(cx, 0), Offset(cx, size.height), paint);
  }

  @override
  bool shouldRepaint(_VerticalLinkPainter oldDelegate) => false;
}

/// 右上角小三角角标。
class _TriangleBadgePainter extends CustomPainter {
  const _TriangleBadgePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = Path()
      ..moveTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(size.width - size.height * 0.62, 0)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_TriangleBadgePainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 虚线圆角边框（加号框）。
class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final dashPaint = Paint()
      ..color = AppColors.gold
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    const dash = 6.0;
    const gap = 4.0;
    const pad = 10.0;
    double pos = pad;
    while (pos < size.width - pad - dash) {
      canvas.drawLine(Offset(pos, 1), Offset(pos + dash, 1), dashPaint);
      pos += dash + gap;
    }
    pos = pad;
    while (pos < size.width - pad - dash) {
      canvas.drawLine(Offset(pos, size.height - 1),
          Offset(pos + dash, size.height - 1), dashPaint);
      pos += dash + gap;
    }
    pos = pad;
    while (pos < size.height - pad - dash) {
      canvas.drawLine(Offset(1, pos), Offset(1, pos + dash), dashPaint);
      pos += dash + gap;
    }
    pos = pad;
    while (pos < size.height - pad - dash) {
      canvas.drawLine(Offset(size.width - 1, pos),
          Offset(size.width - 1, pos + dash), dashPaint);
      pos += dash + gap;
    }
    final corner = Paint()
      ..color = AppColors.gold
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    const r = 8.0;
    final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(1, 1, size.width - 2, size.height - 2),
        const Radius.circular(r));
    for (final arcRect in [
      Rect.fromLTWH(1, 1, r * 2, r * 2),
      Rect.fromLTWH(size.width - 2 - r * 2, 1, r * 2, r * 2),
      Rect.fromLTWH(1, size.height - 2 - r * 2, r * 2, r * 2),
      Rect.fromLTWH(
          size.width - 2 - r * 2, size.height - 2 - r * 2, r * 2, r * 2),
    ]) {
      canvas.drawArc(arcRect, 0, 3.14, false, corner);
    }
    canvas.drawRRect(
        rrect, corner..color = corner.color.withValues(alpha: 0));
  }

  @override
  bool shouldRepaint(_DashedBorderPainter oldDelegate) => false;
}

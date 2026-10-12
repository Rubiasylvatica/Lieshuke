import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Value;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/app_database.dart';

/// 页图副本服务：把每页原照片压缩成缩略图副本，存到独立目录。
/// 阅读时插图显示用的是副本——删除原照片后插图仍然保留。
class ThumbService {
  ThumbService(this.db);

  final AppDatabase db;

  static const int _maxSide = 1200;

  /// 为某页生成缩略图副本，返回副本路径（原图不存在返回 null）。
  Future<String?> makeThumbForPage(Page page) async {
    final src = File(page.imagePath);
    if (!src.existsSync()) {
      return null;
    }
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'pages', 'book_${page.bookId}', 'thumbs'));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final dest = p.join(dir.path, 'page_${page.id}.png');
    try {
      final bytes = await src.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final scale = _maxSide / (image.width > image.height ? image.width : image.height);
      final targetW = (image.width * scale).round().clamp(1, _maxSide);
      final targetH = (image.height * scale).round().clamp(1, _maxSide);
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImageRect(
        image,
        ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        ui.Rect.fromLTWH(0, 0, targetW.toDouble(), targetH.toDouble()),
        ui.Paint(),
      );
      final outImage = await recorder
          .endRecording()
          .toImage(targetW, targetH);
      final data = await outImage.toByteData(
          format: ui.ImageByteFormat.png);
      image.dispose();
      outImage.dispose();
      if (data == null) {
        return null;
      }
      await File(dest).writeAsBytes(data.buffer.asUint8List(), flush: true);
      return dest;
    } catch (_) {
      return null;
    }
  }

  /// 为书的全部页补生成缺失的缩略图（幂等，可后台调用）。
  Future<void> ensureThumbsForBook(int bookId) async {
    final pages = await (db.select(db.pages)
          ..where((pg) => pg.bookId.equals(bookId)))
        .get();
    for (final page in pages) {
      if (page.thumbPath != null && File(page.thumbPath!).existsSync()) {
        continue;
      }
      final path = await makeThumbForPage(page);
      if (path != null) {
        await (db.update(db.pages)..where((pg) => pg.id.equals(page.id)))
            .write(PagesCompanion(thumbPath: Value(path)));
      }
    }
  }
}

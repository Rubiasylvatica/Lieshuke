import 'dart:async';

import 'package:drift/drift.dart';

import '../data/app_database.dart';
import '../data/book_repository.dart';
import 'ocr_engine.dart';

/// 批量 OCR 服务：逐页识别，支持进度回调、暂停、继续、取消。
/// 失败页保持 pending 状态，重新运行时可自动重试（断点续传）。
class OcrService {
  OcrService(this.db, this.engine, {this.repository});

  final AppDatabase db;
  final OcrEngine engine;

  /// 数据仓库：用于识别后套用校对词库（可空，测试用）。
  final BookRepository? repository;

  bool _paused = false;
  bool _cancelled = false;

  /// 处理某本书全部待识别页面。
  /// [onProgress] 回调 (已完成数, 总数, 状态说明)。
  Future<void> processBook(
    int bookId, {
    void Function(int done, int total, String status)? onProgress,
  }) async {
    _paused = false;
    _cancelled = false;
    final pending = await (db.select(db.pages)
          ..where(
              (pg) => pg.bookId.equals(bookId) & pg.status.equals('pending'))
          ..orderBy([(pg) => OrderingTerm.asc(pg.orderIndex)]))
        .get();
    final total = pending.length;
    var done = 0;
    onProgress?.call(done, total, '准备开始');

    for (final page in pending) {
      if (_cancelled) {
        break;
      }
      while (_paused && !_cancelled) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      if (_cancelled) {
        break;
      }
      onProgress?.call(done, total, '识别第 ${page.orderIndex} 页…');
      try {
        var text = await engine.recognize(page.imagePath);
        // 自学习校正：套用用户校对积累的词库规则
        final repo = repository;
        if (repo != null) {
          text = await repo.applyCorrectionRules(text);
        }
        await (db.update(db.pages)..where((pg) => pg.id.equals(page.id)))
            .write(PagesCompanion(
          content: Value(text),
          status: const Value('recognized'),
        ));
      } catch (_) {
        // 识别失败：保持 pending，下次运行自动重试
      }
      done++;
      onProgress?.call(done, total, '已完成 $done / $total');
    }
    onProgress?.call(done, total, _cancelled ? '已取消' : '全部完成');
  }

  void pause() {
    _paused = true;
  }

  void resume() {
    _paused = false;
  }

  void cancel() {
    _cancelled = true;
    _paused = false;
  }
}

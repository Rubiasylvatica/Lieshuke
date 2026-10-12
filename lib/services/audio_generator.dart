import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/app_database.dart';
import 'tts_service.dart';

/// 朗读音频生成器：按页调用 TTS 生成 mp3 保存本地。
/// 支持暂停 / 继续 / 取消、断点续传（已有音频的页跳过）、失败重试（每页最多 3 次）。
class AudioGenerator {
  AudioGenerator(this.db, this.engine);

  final AppDatabase db;
  final TtsEngine engine;

  bool _paused = false;
  bool _cancelled = false;

  /// 遇到「引擎不支持生成文件」等致命错误时的原因（非空 = 已中止）。
  String? abortReason;

  /// 生成结果：已生成数 / 失败数 / 跳过数（已有）。
  Future<(int, int, int)> generateForBook(
    int bookId, {
    String voice = '云希',
    void Function(int done, int total, String status)? onProgress,
  }) async {
    _paused = false;
    _cancelled = false;
    final pages = await (db.select(db.pages)
          ..where((pg) => pg.bookId.equals(bookId))
          ..orderBy([(pg) => OrderingTerm.asc(pg.orderIndex)]))
        .get();
    final docs = await getApplicationDocumentsDirectory();
    final audioDir = Directory(p.join(docs.path, 'audio', 'book_$bookId'));
    if (!audioDir.existsSync()) {
      audioDir.createSync(recursive: true);
    }

    var done = 0;
    var failed = 0;
    var skipped = 0;
    final total = pages.length;
    for (final page in pages) {
      while (_paused && !_cancelled) {
        onProgress?.call(done, total, '已暂停');
        await Future.delayed(const Duration(milliseconds: 300));
      }
      if (_cancelled) {
        onProgress?.call(done, total, '已停止');
        break;
      }
      if (page.content.trim().isEmpty) {
        done++;
        continue;
      }
      // 断点续传：已有文件跳过
      if (page.audioPath != null && File(page.audioPath!).existsSync()) {
        done++;
        skipped++;
        onProgress?.call(done, total, '第 ${page.orderIndex} 页已有音频，跳过');
        continue;
      }
      onProgress?.call(done, total, '第 ${page.orderIndex} 页语音生成中…');
      final dest = p.join(audioDir.path,
          'page_${page.id}.${engine.fileExt}');
      var success = false;
      Object? lastError;
      for (var attempt = 0; attempt < 3 && !_cancelled && !success; attempt++) {
        try {
          final data = await engine.synthesize(page.content, voice);
          await File(dest).writeAsBytes(data);
          await (db.update(db.pages)..where((pg) => pg.id.equals(page.id)))
              .write(PagesCompanion(audioPath: Value(dest)));
          success = true;
        } on TtsFileNotSupportedException catch (e) {
          // 引擎根本不支持写文件：再试也白搭，直接中止
          abortReason = e.toString();
          _cancelled = true;
          break;
        } catch (e) {
          lastError = e;
          await Future.delayed(const Duration(milliseconds: 800));
        }
      }
      if (_cancelled && abortReason != null) {
        break;
      }
      if (success) {
        done++;
      } else {
        failed++;
        onProgress?.call(done, total,
            '第 ${page.orderIndex} 页失败（${lastError ?? '未知错误'}），可稍后重试');
      }
    }
    return (done, failed, skipped);
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

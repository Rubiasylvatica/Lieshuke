import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../data/app_database.dart';

/// 备份与恢复服务（批次 14：备份导出 / 从备份恢复）。
///
/// 备份内容 = 数据库一致性快照（VACUUM INTO）+ 应用文档目录（封面、书页照片、
/// 缩略图、批注相关文件）。语音模型不备份（恢复后联网重下即可）。
class BackupService {
  BackupService._();

  static final BackupService instance = BackupService._();

  /// 数据库文件名（drift_flutter：<文档目录>/lieshuke.sqlite）。
  static const String dbFileName = 'lieshuke.sqlite';

  AppDatabase get _db => AppDatabase.instance;

  static String _timeStamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  /// 生成数据库一致性快照（VACUUM INTO，避免直接复制活跃数据库导致损坏）。
  Future<File> _snapshotDb(Directory outDir) async {
    final target = File(p.join(outDir.path, dbFileName));
    if (target.existsSync()) {
      target.deleteSync();
    }
    final escaped = target.path.replaceAll("'", "''");
    await _db.customStatement("VACUUM INTO '$escaped'");
    return target;
  }

  /// 导出备份 zip：数据库快照 + 文档目录（跳过活跃数据库文件）。
  Future<File> exportBackup() async {
    final docs = await getApplicationDocumentsDirectory();
    final tmp = await getTemporaryDirectory();
    final outFile =
        File(p.join(tmp.path, 'lieshuke_backup_${_timeStamp()}.zip'));

    final snapshot = await _snapshotDb(tmp);

    final encoder = ZipFileEncoder();
    encoder.create(outFile.path, level: ZipFileEncoder.gzip);
    // 1) 文档目录（封面 / 书页照片 / 缩略图等；跳过活跃数据库，用快照代替）
    // 手动遍历、只添加文件，不写“目录条目”（addDirectory 会为每个
    // 子目录写入以 / 结尾的目录条目，部分手机自带文件管理器遇到目录
    // 条目会报“指定压缩文件格式不支持此操作”）。
    await for (final entity
        in docs.list(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final name = p.basename(entity.path);
      if (name == dbFileName || name.startsWith('$dbFileName-')) {
        continue; // 活跃数据库及 -wal/-shm 用快照代替
      }
      final rel = p.relative(entity.path, from: docs.path);
      await encoder.addFile(entity, rel.replaceAll('\\', '/'));
    }
    // 2) 数据库一致性快照
    await encoder.addFile(snapshot, dbFileName);
    await encoder.close();

    try {
      snapshot.deleteSync();
    } catch (_) {}
    return outFile;
  }

  /// 调起系统分享面板发送备份文件。
  Future<void> shareBackup(File zip) async {
    // 只分享文件本身（不带 text 正文）：部分手机分享面板在
    // “文件 + 文本”混合分享时会提示“无法使用直接分享功能”。
    await SharePlus.instance.share(ShareParams(
      files: [XFile(zip.path, mimeType: 'application/zip')],
      subject: '猎书客数据备份',
    ));
  }

  /// 校验备份 zip：必须包含可读的数据库（books 表存在）。
  Future<void> _validateZip(File zip) async {
    final input = InputFileStream(zip.path);
    final archive = ZipDecoder().decodeStream(input);
    ArchiveFile? dbEntry;
    for (final entry in archive) {
      if (entry.isFile && entry.name == dbFileName) {
        dbEntry = entry;
        break;
      }
    }
    if (dbEntry == null) {
      throw Exception('备份文件无效：缺少数据库文件');
    }
    final bytes = dbEntry.readBytes();
    if (bytes == null || bytes.isEmpty) {
      throw Exception('备份文件无效：数据库为空');
    }

    final tmp = await getTemporaryDirectory();
    final probe =
        File(p.join(tmp.path, 'restore_probe_${_timeStamp()}.sqlite'));
    await probe.writeAsBytes(bytes, flush: true);
    sqlite.Database? conn;
    try {
      conn = sqlite.sqlite3.open(probe.path);
      final rows = conn.select(
          "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='books'");
      final ok = rows.isNotEmpty && (rows.first.columnAt(0) as int) > 0;
      if (!ok) {
        throw Exception('备份文件无效：数据库校验失败');
      }
    } finally {
      conn?.close();
      try {
        probe.deleteSync();
      } catch (_) {}
    }
  }

  /// 从备份 zip 恢复（覆盖当前数据；成功后需重启 App）。
  Future<void> restoreFromZip(File zip) async {
    // 1) 先完整校验备份
    await _validateZip(zip);

    // 2) 关闭当前数据库，释放文件句柄
    await _db.close();

    final docs = await getApplicationDocumentsDirectory();
    final bakDir = Directory(
        p.join(docs.parent.path, 'lieshuke_docs_prev_${_timeStamp()}'));

    try {
      // 3) 当前数据整体挪到回滚目录，重建文档目录
      docs.renameSync(bakDir.path);
      Directory(docs.path).createSync(recursive: true);

      // 4) 解压备份写入（条目为相对路径）
      final input = InputFileStream(zip.path);
      final archive = ZipDecoder().decodeStream(input);
      for (final entry in archive) {
        if (!entry.isFile) {
          continue;
        }
        final data = entry.readBytes();
        if (data == null) {
          continue;
        }
        final out = File(p.join(docs.path, entry.name));
        out.parent.createSync(recursive: true);
        await out.writeAsBytes(data, flush: true);
      }

      // 5) 复核恢复后的数据库可读
      sqlite.Database? conn;
      try {
        conn = sqlite.sqlite3.open(p.join(docs.path, dbFileName));
        conn.select('SELECT count(*) FROM books');
      } finally {
        conn?.close();
      }

      // 6) 成功：删除回滚目录
      try {
        bakDir.deleteSync(recursive: true);
      } catch (_) {}
    } catch (_) {
      // 回滚：删掉新数据，把旧数据挪回来
      try {
        Directory(docs.path).deleteSync(recursive: true);
      } catch (_) {}
      if (bakDir.existsSync()) {
        try {
          bakDir.renameSync(docs.path);
        } catch (_) {}
      }
      rethrow;
    }
  }
}

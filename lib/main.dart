import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'data/app_database.dart';
import 'data/book_repository.dart';
import 'screens/home_shell.dart';
import 'services/book_audio_handler.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 加载 sherpa-onnx 离线语音原生库（每个 isolate 只需一次；失败不阻断其它功能）。
  try {
    sherpa.initBindings();
  } catch (e) {
    debugPrint('sherpa-onnx bindings init failed: $e');
  }
  // 初始化本地数据库（drift 会在首次使用时自动建库建表）。
  AppDatabase.instance;
  // 启动时清理残留的孤儿分类。
  unawaited(BookRepository(AppDatabase.instance).cleanupOrphanTags());
  // 清理已下线音色（华言 / 超文）的残留模型，释放手机空间。
  unawaited(_cleanupLegacyVoiceModels());
  // 初始化后台播放处理器（通知栏 / 锁屏控制）。
  bookAudioHandler = await AudioService.init(
    builder: BookAudioHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.lieshuke.audio',
      androidNotificationChannelName: '猎书客听书',
      androidNotificationOngoing: true,
    ),
  );
  if (kDebugMode) {
    _debugDbSelftest();
  }
  runApp(const LieshukeApp());
}

/// 删除已下线音色的残留模型目录（华言 / 超文，2026-10-11 起不再提供）。
Future<void> _cleanupLegacyVoiceModels() async {
  try {
    final support = await getApplicationSupportDirectory();
    for (final name in [
      'vits-piper-zh_CN-huayan-medium',
      'vits-piper-zh_CN-chaowen-medium',
    ]) {
      final dir = Directory(p.join(support.path, 'tts_models', name));
      if (dir.existsSync()) {
        try {
          dir.deleteSync(recursive: true);
          debugPrint('已清理旧音色模型: $name');
        } catch (e) {
          debugPrint('旧音色模型清理失败 $name: $e');
        }
      }
    }
  } catch (e) {
    debugPrint('旧音色模型清理失败: $e');
  }
}

/// 调试模式下的数据库自检：验证建表成功（结果输出到 logcat，仅开发版生效）。
Future<void> _debugDbSelftest() async {
  try {
    final db = AppDatabase.instance;
    final books = await db.books.count().getSingle();
    final pages = await db.pages.count().getSingle();
    final tags = await db.tags.count().getSingle();
    debugPrint('DB-SELFTEST-OK books=$books pages=$pages tags=$tags');
  } catch (e) {
    debugPrint('DB-SELFTEST-FAIL $e');
  }
}

/// 猎书客 App 根组件。
class LieshukeApp extends StatelessWidget {
  const LieshukeApp({super.key, this.database});

  /// 可注入的数据库实例（测试用）；为空时使用全局实例。
  final AppDatabase? database;

  @override
  Widget build(BuildContext context) {
    // 生产环境始终使用真实数据库与仓库；仅测试时走注入。
    final db = database ?? AppDatabase.instance;
    final repository = BookRepository(db);
    return MaterialApp(
      title: '猎书客',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      home: HomeShell(bookshelfRepository: repository),
    );
  }
}

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'tables.dart';

part 'app_database.g.dart';

/// 猎书客本地数据库。
///
/// 版本化增量迁移：只增不改，禁止破坏性改表（见 docs/architecture.md）。
@DriftDatabase(
  tables: [
    Books,
    Tags,
    BookTags,
    Pages,
    Chapters,
    ChapterAudioChunks,
    Annotations,
    ReadingSessions,
    BookLinks,
    AppSettings,
    CorrectionRules,
  ],
)
class AppDatabase extends _$AppDatabase {
  /// 应用内全局唯一实例（首次使用前需 WidgetsFlutterBinding.ensureInitialized）。
  static final AppDatabase instance = AppDatabase();

  /// 构造：使用 drift_flutter 提供的默认本地连接（数据库名 lieshuke.db）。

  AppDatabase() : super(driftDatabase(name: 'lieshuke'));

  /// 测试用：传入内存数据库等自定义执行器。
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 10;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        onUpgrade: (m, from, to) async {
          // 版本化增量迁移：只增不改（见 docs/architecture.md）
          if (from < 2) {
            // v2：分类升级为树状结构（多级分类）
            await m.addColumn(tags, tags.parentId);
          }
          if (from < 3) {
            // v3：书页增加章节归属
            await m.addColumn(pages, pages.chapterId);
          }
          if (from < 4) {
            // v4：批注存原文片段（改字后重新定位）
            await m.addColumn(annotations, annotations.anchorText);
          }
          if (from < 5) {
            // v5：批注分组（跨页批注）
            await m.addColumn(annotations, annotations.groupId);
            // 历史批注每条自成一组（否则都会并到 0 组里）
            await m.database
                .customStatement('UPDATE annotations SET group_id = id');
          }
          if (from < 6) {
            // v6：书页朗读音频路径（批次 11）
            await m.addColumn(pages, pages.audioPath);
          }
          if (from < 7) {
            // v7：页图副本路径（插图嵌入）+ 关联已读标记
            await m.addColumn(pages, pages.thumbPath);
            await m.addColumn(bookLinks, bookLinks.read);
          }
          if (from < 8) {
            // v8：阅读进度百分比
            await m.addColumn(books, books.readPercent);
          }
          if (from < 9) {
            // v9：校对词库（自学习校正）
            await m.createTable(correctionRules);
          }
          if (from < 10) {
            // v10：读完时间（统计页只保留加入/读完两个时间）
            await m.addColumn(books, books.finishedAt);
          }
        },
      );
}

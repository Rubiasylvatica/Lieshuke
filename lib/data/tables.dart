import 'package:drift/drift.dart';

/// 书：书架上的每一本书（对应一个照片文件夹）。
class Books extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text().withLength(min: 1, max: 200)();
  TextColumn get author => text().withDefault(const Constant(''))();
  TextColumn get authorCountry => text().withDefault(const Constant(''))();
  TextColumn get authorEra => text().withDefault(const Constant(''))();
  TextColumn get coverPath => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();
  IntColumn get sortKey => integer().withDefault(const Constant(0))();
  BoolColumn get proofreadDone => boolean().withDefault(const Constant(false))();
  BoolColumn get photosDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get lastReadAt => dateTime().nullable()();
  IntColumn get totalReadSeconds => integer().withDefault(const Constant(0))();
  /// 阅读进度百分比（0-100），阅读器退出时保存
  IntColumn get readPercent => integer().withDefault(const Constant(0))();
  /// 读完时间（进度首次达到 95% 时记录一次，用于统计页）
  DateTimeColumn get finishedAt => dateTime().nullable()();
}

/// 分类标签：树状结构（如 长篇小说→中国→当代），parentId 指向上级分类。
class Tags extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 50)();
  IntColumn get parentId => integer().nullable().references(Tags, #id)();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// 书与分类的多对多关联。
class BookTags extends Table {
  IntColumn get bookId => integer().references(Books, #id)();
  IntColumn get tagId => integer().references(Tags, #id)();

  @override
  Set<Column> get primaryKey => {bookId, tagId};
}

/// 页面识别状态：待识别 / 识别中 / 已识别 / 已校对。
enum PageStatus { pending, processing, recognized, proofread }

/// 书页：一张照片对应一页，content 为 OCR 结果。
class Pages extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get bookId => integer().references(Books, #id)();
  /// 所属章节（可空，空 = 未分章）
  IntColumn get chapterId => integer().nullable().references(Chapters, #id)();
  IntColumn get orderIndex => integer()();
  TextColumn get imagePath => text()();
  /// OCR 识别出的正文（列名用 content，避免与 drift 内置 text() 冲突）
  TextColumn get content => text().withDefault(const Constant(''))();
  /// 本页朗读音频文件路径（空 = 未生成，见批次 11）
  TextColumn get audioPath => text().nullable()();
  /// 本页缩略图副本路径（插图嵌入电子书用；删原照片后保留）
  TextColumn get thumbPath => text().nullable()();
  /// 存 PageStatus.name（pending / processing / recognized / proofread）
  TextColumn get status => text().withDefault(const Constant('pending'))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// 音频生成状态：未生成 / 生成中 / 已生成。
enum AudioGenStatus { none, generating, done }

/// 章节：按页码范围组织朗读（默认整本一段）。
class Chapters extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get bookId => integer().references(Books, #id)();
  TextColumn get title => text().withDefault(const Constant(''))();
  IntColumn get startPage => integer()();
  IntColumn get endPage => integer()();
  /// 存 AudioGenStatus.name（none / generating / done）
  TextColumn get audioGenerated => text().withDefault(const Constant('none'))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// 章节音频分块：跨块连续播放。
class ChapterAudioChunks extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get chapterId => integer().references(Chapters, #id)();
  IntColumn get orderIndex => integer()();
  TextColumn get filePath => text()();
}

/// 批注类型：下划线 / 高亮 / 批注。
enum AnnotationType { underline, highlight, note }

/// 批注：锚定「页码 + 字符偏移」，文字编辑时同步重算偏移。
class Annotations extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get pageId => integer().references(Pages, #id)();
  /// 存 AnnotationType.name（underline / highlight / note）
  TextColumn get type => text()();
  TextColumn get color => text().withDefault(const Constant(''))();
  IntColumn get startOffset => integer()();
  IntColumn get endOffset => integer()();
  /// 被标注的原文片段：文字修改后靠它在附近重新定位（R5.4）
  TextColumn get anchorText => text().withDefault(const Constant(''))();
  /// 批注组：跨页批注会拆成多行，同组共享一个 groupId（0 = 无组）
  IntColumn get groupId => integer().withDefault(const Constant(0))();
  TextColumn get noteText => text().withDefault(const Constant(''))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// 阅读记录：静默计时会话。
class ReadingSessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get bookId => integer().references(Books, #id)();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime()();
  IntColumn get durationSeconds => integer()();
}

/// 校对词库（自学习校正）：用户在校对中改过的「错字 → 正确字」规则。
/// OCR 识别完成后自动套用；命中次数累计。
class CorrectionRules extends Table {
  IntColumn get id => integer().autoIncrement()();
  /// 识别出的错误写法（最长 20 字）
  TextColumn get wrong => text().withLength(min: 1, max: 20)();
  /// 用户改成的正确写法（最长 20 字）
  TextColumn get right => text().withLength(min: 1, max: 20)();
  /// 累计命中次数（每次 OCR 应用时增加）
  IntColumn get hitCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// 书关联边：如「A 提到了 B」，带关系备注。
class BookLinks extends Table {
  IntColumn get id => integer().autoIncrement()();
  @ReferenceName('linkFrom')
  IntColumn get fromBookId => integer().references(Books, #id)();
  @ReferenceName('linkTo')
  IntColumn get toBookId => integer().references(Books, #id)();
  TextColumn get note => text().withDefault(const Constant(''))();
  /// 是否已读（从本书出发指向的书）
  BoolColumn get read => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// 应用设置（音色 / 语速 / 字号等键值对）。
class AppSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

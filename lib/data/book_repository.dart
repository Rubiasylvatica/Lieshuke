import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_database.dart';

/// 书籍数据仓库：书架页、新建书表单共用的数据入口。
class BookRepository {
  BookRepository(this.db);

  final AppDatabase db;

  /// 全部书籍：置顶优先，同组内按加入时间倒序（响应式）。
  Stream<List<Book>> watchAll() {
    final q = db.select(db.books)
      ..orderBy([
        (b) => OrderingTerm.desc(b.pinned),
        (b) => OrderingTerm.desc(b.createdAt),
      ]);
    return q.watch();
  }

  /// 某本书（响应式）。
  Stream<Book?> watchBook(int bookId) {
    final q = db.select(db.books)..where((b) => b.id.equals(bookId));
    return q.watchSingleOrNull();
  }

  /// 全部分类（按创建时间升序，响应式）。
  Stream<List<Tag>> watchTags() {
    final q = db.select(db.tags)
      ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]);
    return q.watch();
  }

  /// 每本书对应的分类 id 集合（响应式），用于分类筛选。
  Stream<Map<int, Set<int>>> watchBookTagMap() {
    return db.select(db.bookTags).watch().map((rows) {
      final map = <int, Set<int>>{};
      for (final r in rows) {
        map.putIfAbsent(r.bookId, () => <int>{}).add(r.tagId);
      }
      return map;
    });
  }

  /// 新建书，返回 id。
  Future<int> createBook({
    required String title,
    String author = '',
    String country = '',
    String era = '',
    String? coverPath,
  }) {
    return db.into(db.books).insert(BooksCompanion.insert(
          title: title,
          author: Value(author),
          authorCountry: Value(country),
          authorEra: Value(era),
          coverPath: Value(coverPath),
        ));
  }

  /// 更新书的资料（书名 / 作者 / 国家 / 出版时间 / 封面）。
  /// 传 null 的 coverPath 表示“保持原封面”，不会被清空。
  Future<void> updateBookInfo(
    int bookId, {
    required String title,
    String author = '',
    String country = '',
    String era = '',
    String? coverPath,
  }) {
    return db.update(db.books).write(BooksCompanion(
          title: Value(title),
          author: Value(author),
          authorCountry: Value(country),
          authorEra: Value(era),
          coverPath: coverPath == null
              ? const Value.absent()
              : Value(coverPath),
        ));
  }

  /// 设置书的分类集合（整体替换）。
  /// 注意：不在此时清理孤儿标签（避免误删其他书尚未使用的分类）；
  /// 孤儿清理在删除书与 App 启动维护时进行。
  Future<void> setBookTags(int bookId, Set<int> tagIds) async {
    await db.transaction(() async {
      await (db.delete(db.bookTags)..where((bt) => bt.bookId.equals(bookId)))
          .go();
      for (final tagId in tagIds) {
        await db.into(db.bookTags).insert(
            BookTagsCompanion.insert(bookId: bookId, tagId: tagId));
      }
    });
  }

  /// 取分类（不存在则创建），返回 id。仅用于平级标签。
  Future<int> ensureTag(String name) async {
    final trimmed = name.trim();
    final existing = await (db.select(db.tags)..where((t) => t.name.equals(trimmed)))
        .getSingleOrNull();
    if (existing != null) {
      return existing.id;
    }
    return db.into(db.tags).insert(TagsCompanion.insert(name: trimmed));
  }

  /// 按路径创建/取分类（如「长篇小说/中国/当代」），返回最末级标签 id。
  /// 每一级自动创建，同名同级复用。
  Future<int> ensureTagPath(String path) async {
    final parts = path
        .split('/')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) {
      throw ArgumentError('分类路径为空: $path');
    }
    int? parentId;
    for (final part in parts) {
      final matches = parentId == null
          ? await (db.select(db.tags)
                  ..where((t) => t.name.equals(part) & t.parentId.isNull()))
              .getSingleOrNull()
          : await (db.select(db.tags)
                  ..where((t) =>
                      t.name.equals(part) & t.parentId.equals(parentId!)))
              .getSingleOrNull();
      if (matches != null) {
        parentId = matches.id;
      } else {
        parentId = await db.into(db.tags).insert(
            TagsCompanion.insert(name: part, parentId: Value(parentId)));
      }
    }
    return parentId!;
  }

  /// 清理孤儿标签：反复删除「未被任何书关联、且没有子分类」的标签，
  /// 直到没有可删的为止（子级删掉后父级也可能成为孤儿）。
  Future<void> cleanupOrphanTags() async {
    await db.transaction(() async {
      var changed = true;
      while (changed) {
        changed = false;
        final usedIds =
            (await db.select(db.bookTags).map((bt) => bt.tagId).get()).toSet();
        final parentIds =
            (await db.select(db.tags).map((t) => t.parentId).get())
                .whereType<int>()
                .toSet();
        final allTags = await db.select(db.tags).get();
        for (final tag in allTags) {
          if (!usedIds.contains(tag.id) && !parentIds.contains(tag.id)) {
            await (db.delete(db.tags)..where((t) => t.id.equals(tag.id))).go();
            changed = true;
          }
        }
      }
    });
  }

  /// 重命名分类。
  Future<void> renameTag(int tagId, String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) {
      return;
    }
    await (db.update(db.tags)..where((t) => t.id.equals(tagId)))
        .write(TagsCompanion(name: Value(trimmed)));
  }

  /// 删除分类及其全部子分类（与书的关联一并清除）。
  Future<void> deleteTagWithSubtree(int rootId) async {
    final allTags = await db.select(db.tags).get();
    final childrenOf = <int, List<int>>{};
    for (final tag in allTags) {
      if (tag.parentId != null) {
        childrenOf.putIfAbsent(tag.parentId!, () => []).add(tag.id);
      }
    }
    final toDelete = <int>{};
    void collect(int id) {
      toDelete.add(id);
      for (final c in childrenOf[id] ?? const <int>[]) {
        collect(c);
      }
    }

    collect(rootId);
    await db.transaction(() async {
      for (final id in toDelete) {
        await (db.delete(db.bookTags)..where((bt) => bt.tagId.equals(id))).go();
        await (db.delete(db.tags)..where((t) => t.id.equals(id))).go();
      }
    });
  }

  /// 每个分类的累计书籍数量（包含其全部子分类下的书）。
  Future<Map<int, int>> tagSubtreeBookCounts() async {
    final tags = await db.select(db.tags).get();
    final tagRows = await db.select(db.bookTags).get();
    final childrenOf = <int, List<int>>{};
    for (final t in tags) {
      childrenOf.putIfAbsent(t.parentId ?? 0, () => []).add(t.id);
    }
    final result = <int, int>{};
    for (final tag in tags) {
      final subtree = <int>{};
      void collect(int id) {
        subtree.add(id);
        for (final c in childrenOf[id] ?? const <int>[]) {
          collect(c);
        }
      }

      collect(tag.id);
      final seenBooks = <int>{};
      for (final r in tagRows) {
        if (subtree.contains(r.tagId)) {
          seenBooks.add(r.bookId);
        }
      }
      result[tag.id] = seenBooks.length;
    }
    return result;
  }

  /// 置顶 / 取消置顶。
  Future<void> setPinned(int bookId, bool pinned) {
    return (db.update(db.books)..where((b) => b.id.equals(bookId)))
        .write(BooksCompanion(pinned: Value(pinned)));
  }

  /// 删除书及其全部关联数据（含页面图片与封面文件）。
  Future<void> deleteBook(int bookId) async {
    final book =
        await (db.select(db.books)..where((b) => b.id.equals(bookId)))
            .getSingleOrNull();
    final pages = await (db.select(db.pages)..where((pg) => pg.bookId.equals(bookId)))
        .get();
    await db.transaction(() async {
      final pageIds = await (db.select(db.pages)..where((pg) => pg.bookId.equals(bookId)))
          .map((r) => r.id)
          .get();
      for (final pid in pageIds) {
        await (db.delete(db.annotations)..where((a) => a.pageId.equals(pid)))
            .go();
      }
      await (db.delete(db.pages)..where((pg) => pg.bookId.equals(bookId))).go();
      await (db.delete(db.chapters)..where((c) => c.bookId.equals(bookId))).go();
      await (db.delete(db.bookLinks)
            ..where((l) => l.fromBookId.equals(bookId) | l.toBookId.equals(bookId)))
          .go();
      await (db.delete(db.readingSessions)..where((s) => s.bookId.equals(bookId)))
          .go();
      await (db.delete(db.bookTags)..where((bt) => bt.bookId.equals(bookId)))
          .go();
      await (db.delete(db.books)..where((b) => b.id.equals(bookId))).go();
    });
    // 清理照片文件与封面文件
    for (final page in pages) {
      final f = File(page.imagePath);
      if (f.existsSync()) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    }
    final cover = book?.coverPath;
    if (cover != null) {
      final f = File(cover);
      if (f.existsSync()) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    }
    await cleanupOrphanTags();
  }

  /// 把选中的封面照片复制到应用私有目录，返回保存路径。
  Future<String> saveCover(String sourcePath, int bookId) async {
    final dir = await getApplicationDocumentsDirectory();
    final coversDir = Directory(p.join(dir.path, 'covers'));
    if (!coversDir.existsSync()) {
      coversDir.createSync(recursive: true);
    }
    final ext =
        p.extension(sourcePath).isEmpty ? '.jpg' : p.extension(sourcePath);
    final dest = p.join(coversDir.path, 'book_$bookId$ext');
    await File(sourcePath).copy(dest);
    return dest;
  }

  /// 某本书的全部页面（按 orderIndex 升序，响应式）。
  /// [chapterId] 不为空时只看该章节；[chapterNull] 为 true 时只看未分章的页。
  Stream<List<Page>> watchPages(
    int bookId, {
    int? chapterId,
    bool chapterNull = false,
  }) {
    final q = db.select(db.pages)
      ..where((pg) {
        Expression<bool> base = pg.bookId.equals(bookId);
        if (chapterId != null) {
          base = base & pg.chapterId.equals(chapterId);
        } else if (chapterNull) {
          base = base & pg.chapterId.isNull();
        }
        return base;
      })
      ..orderBy([(pg) => OrderingTerm.asc(pg.orderIndex)]);
    return q.watch();
  }

  /// 某本书的章节列表（按创建时间，响应式）。
  Stream<List<Chapter>> watchChapters(int bookId) {
    final q = db.select(db.chapters)
      ..where((c) => c.bookId.equals(bookId))
      ..orderBy([(c) => OrderingTerm.asc(c.createdAt)]);
    return q.watch();
  }

  /// 新建章节。
  Future<int> createChapter(int bookId, String title) {
    return db.into(db.chapters).insert(ChaptersCompanion.insert(
          bookId: bookId,
          title: Value(title),
          startPage: 0,
          endPage: 0,
          audioGenerated: const Value('none'),
        ));
  }

  /// 重命名章节。
  Future<void> renameChapter(int chapterId, String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) {
      return;
    }
    await (db.update(db.chapters)..where((c) => c.id.equals(chapterId)))
        .write(ChaptersCompanion(title: Value(trimmed)));
  }

  /// 删除章节（其下页面变为未分章，页面本身保留）。
  Future<void> deleteChapter(int chapterId) async {
    await db.transaction(() async {
      await (db.update(db.pages)..where((pg) => pg.chapterId.equals(chapterId)))
          .write(const PagesCompanion(chapterId: Value(null)));
      await (db.delete(db.chapters)..where((c) => c.id.equals(chapterId))).go();
    });
  }

  /// 批量导入照片：复制到应用私有目录并创建页面记录（追加到末尾）。
  /// [chapterId] 不为空时归属到该章节。
  Future<int> addPagesFromPaths(
    int bookId,
    List<String> sourcePaths, {
    int? chapterId,
  }) async {
    final docs = await getApplicationDocumentsDirectory();
    final pagesDir = Directory(p.join(docs.path, 'pages', 'book_$bookId'));
    if (!pagesDir.existsSync()) {
      pagesDir.createSync(recursive: true);
    }
    final existing = await (db.select(db.pages)..where((pg) => pg.bookId.equals(bookId))).get();
    var nextOrder = existing.fold<int>(0, (m, pg) => pg.orderIndex > m ? pg.orderIndex : m) + 1;
    var added = 0;
    await db.transaction(() async {
      for (final src in sourcePaths) {
        final ext = p.extension(src).isEmpty ? '.jpg' : p.extension(src);
        final dest = p.join(pagesDir.path, 'page_$nextOrder$ext');
        await File(src).copy(dest);
        await db.into(db.pages).insert(PagesCompanion.insert(
              bookId: bookId,
              chapterId: Value(chapterId),
              orderIndex: nextOrder,
              imagePath: dest,
              status: const Value('pending'),
            ));
        nextOrder++;
        added++;
      }
    });
    if (added > 0) {
      // 又有新照片了：复位「照片已删除」标记，避免误报。
      await (db.update(db.books)..where((b) => b.id.equals(bookId)))
          .write(const BooksCompanion(photosDeleted: Value(false)));
    }
    return added;
  }

  /// 导入电子书文本（.txt）：按空行分段后每若干段合成一页，
  /// 直接以「已校对」状态入库（无照片页，imagePath 为空）。
  /// 返回新增页数。
  Future<int> addTextPages(
    int bookId,
    String text, {
    int? chapterId,
  }) async {
    final paras = text
        .split(RegExp(r'\n\s*\n'))
        .map((e) => e.replaceAll('\r', '').trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (paras.isEmpty) {
      return 0;
    }
    final existing = await (db.select(db.pages)
          ..where((pg) => pg.bookId.equals(bookId)))
        .get();
    var nextOrder =
        existing.fold<int>(0, (m, pg) => pg.orderIndex > m ? pg.orderIndex : m) +
            1;

    // 每页最多 12 段且不超过约 1500 字，超出另起一页
    const maxParasPerPage = 12;
    const maxCharsPerPage = 1500;
    final pages = <String>[];
    var buf = <String>[];
    var chars = 0;
    for (final para in paras) {
      if (buf.isNotEmpty &&
          (buf.length >= maxParasPerPage ||
              chars + para.length > maxCharsPerPage)) {
        pages.add(buf.join('\n\n'));
        buf = <String>[];
        chars = 0;
      }
      buf.add(para);
      chars += para.length;
    }
    if (buf.isNotEmpty) {
      pages.add(buf.join('\n\n'));
    }

    var added = 0;
    await db.transaction(() async {
      for (final content in pages) {
        await db.into(db.pages).insert(PagesCompanion.insert(
              bookId: bookId,
              chapterId: Value(chapterId),
              orderIndex: nextOrder,
              imagePath: '',
              content: Value(content),
              status: const Value('proofread'),
            ));
        nextOrder++;
        added++;
      }
    });
    if (added > 0) {
      await (db.update(db.books)..where((b) => b.id.equals(bookId)))
          .write(const BooksCompanion(photosDeleted: Value(false)));
    }
    return added;
  }

  /// 把书的所有页重置为待识别（重新识别用；音频、图片不动）。
  Future<void> resetPagesToPending(int bookId) async {
    await (db.update(db.pages)..where((pg) => pg.bookId.equals(bookId)))
        .write(const PagesCompanion(status: Value('pending')));
  }

  /// 批量删除页面（记录 + 图片文件）。
  Future<void> deletePages(List<int> pageIds) async {
    if (pageIds.isEmpty) {
      return;
    }
    final pages = await (db.select(db.pages)
          ..where((pg) => pg.id.isIn(pageIds)))
        .get();
    await db.transaction(() async {
      for (final id in pageIds) {
        await (db.delete(db.annotations)..where((a) => a.pageId.equals(id)))
            .go();
        await (db.delete(db.pages)..where((pg) => pg.id.equals(id))).go();
      }
      if (pages.isNotEmpty) {
        // 删除后重排页码：剩余页按顺序连续编号
        await _renumberPages(pages.first.bookId);
      }
    });
    for (final page in pages) {
      final f = File(page.imagePath);
      if (f.existsSync()) {
        try {
          f.deleteSync();
        } catch (_) {
          // 删除文件失败不影响数据层
        }
      }
    }
  }

  /// 交换两页的顺序。
  Future<void> swapPageOrder(int pageA, int pageB) async {
    if (pageA == pageB) {
      return;
    }
    final a = await (db.select(db.pages)..where((pg) => pg.id.equals(pageA)))
        .getSingleOrNull();
    final b = await (db.select(db.pages)..where((pg) => pg.id.equals(pageB)))
        .getSingleOrNull();
    if (a == null || b == null) {
      return;
    }
    await db.transaction(() async {
      await (db.update(db.pages)..where((pg) => pg.id.equals(a.id)))
          .write(PagesCompanion(orderIndex: Value(b.orderIndex)));
      await (db.update(db.pages)..where((pg) => pg.id.equals(b.id)))
          .write(PagesCompanion(orderIndex: Value(a.orderIndex)));
    });
  }

  /// 批量把页面移动到章节（chapterId 为空表示移到未分章）。
  Future<void> movePagesToChapter(List<int> pageIds, int? chapterId) async {
    await db.transaction(() async {
      for (final id in pageIds) {
        await (db.update(db.pages)..where((pg) => pg.id.equals(id)))
            .write(PagesCompanion(chapterId: Value(chapterId)));
      }
    });
  }

  /// 删除单页（记录 + 图片文件）。
  Future<void> deletePage(int pageId) async {
    final page = await (db.select(db.pages)..where((pg) => pg.id.equals(pageId)))
        .getSingleOrNull();
    if (page == null) {
      return;
    }
    await db.transaction(() async {
      await (db.delete(db.annotations)..where((a) => a.pageId.equals(pageId)))
          .go();
      await (db.delete(db.pages)..where((pg) => pg.id.equals(pageId))).go();
      // 删除后重排页码：剩余页按顺序连续编号（删 9 后 10 变 9）
      await _renumberPages(page.bookId);
    });
    final f = File(page.imagePath);
    if (f.existsSync()) {
      try {
        f.deleteSync();
      } catch (_) {
        // 删除文件失败不影响数据层
      }
    }
  }

  /// 把某本书全部页面按当前顺序重新编号为 1..N（删除/移动后调用）。
  Future<void> _renumberPages(int bookId) async {
    final pages = await (db.select(db.pages)
          ..where((pg) => pg.bookId.equals(bookId))
          ..orderBy([(pg) => OrderingTerm.asc(pg.orderIndex)]))
        .get();
    for (var i = 0; i < pages.length; i++) {
      final want = i + 1;
      if (pages[i].orderIndex != want) {
        await (db.update(db.pages)..where((pg) => pg.id.equals(pages[i].id)))
            .write(PagesCompanion(orderIndex: Value(want)));
      }
    }
  }

  /// 上移/下移页面（与相邻页交换 orderIndex）。
  Future<void> movePage(int bookId, int pageId, {required bool up}) async {
    final pages = await (db.select(db.pages)..where((pg) => pg.bookId.equals(bookId)))
        .get()
      ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    final idx = pages.indexWhere((pg) => pg.id == pageId);
    if (idx < 0) {
      return;
    }
    final target = up ? idx - 1 : idx + 1;
    if (target < 0 || target >= pages.length) {
      return;
    }
    final a = pages[idx];
    final b = pages[target];
    await db.transaction(() async {
      await (db.update(db.pages)..where((pg) => pg.id.equals(a.id)))
          .write(PagesCompanion(orderIndex: Value(b.orderIndex)));
      await (db.update(db.pages)..where((pg) => pg.id.equals(b.id)))
          .write(PagesCompanion(orderIndex: Value(a.orderIndex)));
    });
  }

  // ===== 校对与删图（批次 8） =====

  /// 保存校对文字：写入内容并把该页状态置为「已校对」。
  /// 同时：1) 重新定位该页上的批注（R5.4：改字后批注不漂移）；
  ///      2) 从编辑差异中提取「错字 → 正确字」规则存入词库（自学习校正）。
  Future<void> savePageContent(int pageId, String content) async {
    final row = await (db.select(db.pages)..where((pg) => pg.id.equals(pageId)))
        .getSingleOrNull();
    if (row != null) {
      for (final (wrong, right) in extractCorrectionRules(row.content, content)) {
        await addCorrectionRule(wrong, right);
      }
    }
    await (db.update(db.pages)..where((pg) => pg.id.equals(pageId)))
        .write(PagesCompanion(
      content: Value(content),
      status: const Value('proofread'),
    ));
    await reanchorAnnotations(pageId, content);
  }

  // ===== 校对词库（自学习校正） =====

  /// 从「旧→新」的编辑差异中提取替换规则（最多 12 字、不含换行）。
  /// 按行对齐逐行提取，避免整段差异过大导致一条规则都学不到；
  /// 纯增删（某侧为空）说明是增补文字而非改错，跳过。
  static List<(String, String)> extractCorrectionRules(
      String oldText, String newText) {
    final rules = <(String, String)>[];
    final oldLines = oldText.split('\n');
    final newLines = newText.split('\n');
    final n =
        oldLines.length > newLines.length ? oldLines.length : newLines.length;
    for (var i = 0; i < n; i++) {
      final oldL = i < oldLines.length ? oldLines[i] : '';
      final newL = i < newLines.length ? newLines[i] : '';
      if (oldL == newL) {
        continue;
      }
      var o = oldL;
      var nn = newL;
      var guard = 0;
      while (o != nn && guard < 20) {
        guard++;
        var j = 0;
        final maxLen = o.length < nn.length ? o.length : nn.length;
        while (j < maxLen && o[j] == nn[j]) {
          j++;
        }
        var a = o.length - 1;
        var b = nn.length - 1;
        while (a >= j && b >= j && o[a] == nn[b]) {
          a--;
          b--;
        }
        final wrong = o.substring(j, a + 1);
        final right = nn.substring(j, b + 1);
        // 过滤：空串（纯增删）、无变化、太长
        if (wrong.trim().isEmpty ||
            right.trim().isEmpty ||
            wrong == right ||
            wrong.length > 12 ||
            right.length > 12) {
          break;
        }
        rules.add((wrong, right));
        // 消掉这一处，继续找同一行里的下一处修改
        o = o.substring(0, j) + right + o.substring(a + 1);
        nn = nn.substring(0, j) + right + nn.substring(b + 1);
      }
    }
    return rules;
  }

  /// 新增/更新一条词库规则（同「错字」只保留最新一条）。
  Future<void> addCorrectionRule(String wrong, String right) async {
    await (db.delete(db.correctionRules)..where((r) => r.wrong.equals(wrong)))
        .go();
    await db.into(db.correctionRules).insert(
        CorrectionRulesCompanion.insert(wrong: wrong, right: right));
  }

  /// 把词库规则套用到识别结果上（按错字长度降序，长词优先），
  /// 返回校正后的文字。命中规则的 hitCount +1。
  Future<String> applyCorrectionRules(String text) async {
    final rules = await (db.select(db.correctionRules)
          ..orderBy([(r) => OrderingTerm.desc(r.wrong.length)]))
        .get();
    var result = text;
    for (final r in rules) {
      if (result.contains(r.wrong)) {
        result = result.replaceAll(r.wrong, r.right);
        await (db.update(db.correctionRules)..where((x) => x.id.equals(r.id)))
            .write(CorrectionRulesCompanion(hitCount: Value(r.hitCount + 1)));
      }
    }
    return result;
  }

  /// 词库规则（响应式，按创建时间倒序）。
  Stream<List<CorrectionRule>> watchCorrectionRules() {
    final q = db.select(db.correctionRules)
      ..orderBy([(r) => OrderingTerm.desc(r.createdAt)]);
    return q.watch();
  }

  /// 删除一条规则。
  Future<void> deleteCorrectionRule(int id) {
    return (db.delete(db.correctionRules)..where((r) => r.id.equals(id))).go();
  }

  /// 清空词库。
  Future<void> clearCorrectionRules() {
    return db.delete(db.correctionRules).go();
  }

  /// 标记全书校对完成。
  Future<void> markProofreadDone(int bookId) {
    return (db.update(db.books)..where((b) => b.id.equals(bookId)))
        .write(const BooksCompanion(proofreadDone: Value(true)));
  }

  /// 尚未保存文字的页数（照片删除前的安全校验）。
  Future<int> pagesWithoutText(int bookId) async {
    final rows = await (db.select(db.pages)
          ..where((pg) => pg.bookId.equals(bookId) & pg.content.equals('')))
        .get();
    return rows.length;
  }

  /// 原照片文件总占用空间（字节）。
  Future<int> photosTotalBytes(int bookId) async {
    final pages =
        await (db.select(db.pages)..where((pg) => pg.bookId.equals(bookId))).get();
    var total = 0;
    for (final page in pages) {
      final f = File(page.imagePath);
      if (f.existsSync()) {
        try {
          total += f.lengthSync();
        } catch (_) {
          // 文件读不到就不计
        }
      }
    }
    return total;
  }

  /// 删除原照片：先校验每页文字已保存，再置 photosDeleted 并删除图片文件。
  /// 页面记录与文字内容全部保留。校验失败抛 StateError。
  Future<void> deleteOriginalPhotos(int bookId) async {
    final missing = await pagesWithoutText(bookId);
    if (missing > 0) {
      throw StateError('还有 $missing 页没有保存文字，不能删除照片');
    }
    final pages =
        await (db.select(db.pages)..where((pg) => pg.bookId.equals(bookId))).get();
    await (db.update(db.books)..where((b) => b.id.equals(bookId)))
        .write(const BooksCompanion(photosDeleted: Value(true)));
    for (final page in pages) {
      final f = File(page.imagePath);
      if (f.existsSync()) {
        try {
          f.deleteSync();
        } catch (_) {
          // 删除文件失败不影响数据层
        }
      }
    }
  }

  // ===== 阅读器（批次 9） =====

  /// 某本书的全部批注（响应式）。
  Stream<List<Annotation>> watchAnnotations(int bookId) {
    final q = db.select(db.annotations).join([
      innerJoin(db.pages, db.pages.id.equalsExp(db.annotations.pageId)),
    ])
      ..where(db.pages.bookId.equals(bookId))
      ..orderBy([OrderingTerm.asc(db.pages.orderIndex), OrderingTerm.asc(db.annotations.startOffset)]);
    return q
        .watch()
        .map((rows) => rows.map((r) => r.readTable(db.annotations)).toList());
  }

  /// 新增批注（横线 / 高亮 / 批注），支持跨页：
  /// [segments] 为每页片段（pageId, 页内起, 页内止），[anchors] 一一对应原文片段。
  /// 同一条批注的各段共享一个 groupId，返回该组 id。
  Future<int> addAnnotationGroup({
    required List<(int, int, int)> segments,
    required List<String> anchors,
    required String type,
    String noteText = '',
    String color = '',
  }) async {
    final groupId = await _nextAnnotationGroupId();
    for (var i = 0; i < segments.length; i++) {
      final (pageId, s, e) = segments[i];
      if (s >= e || i >= anchors.length) {
        continue;
      }
      await db.into(db.annotations).insert(AnnotationsCompanion.insert(
            pageId: pageId,
            type: type,
            color: Value(color),
            startOffset: s,
            endOffset: e,
            anchorText: Value(anchors[i]),
            noteText: Value(noteText),
            groupId: Value(groupId),
          ));
    }
    return groupId;
  }

  Future<int> _nextAnnotationGroupId() async {
    final row = await db
        .customSelect('SELECT COALESCE(MAX(group_id), 0) AS m FROM annotations')
        .getSingle();
    return row.read<int>('m') + 1;
  }

  /// 修改同组批注的文字（读后感）。
  Future<void> updateGroupNote(int groupId, String noteText) {
    return (db.update(db.annotations)
          ..where((a) => a.groupId.equals(groupId)))
        .write(AnnotationsCompanion(noteText: Value(noteText)));
  }

  /// 删除同组批注（跨页批注的所有段一起删）。
  Future<void> deleteGroup(int groupId) {
    return (db.delete(db.annotations)
          ..where((a) => a.groupId.equals(groupId)))
        .go();
  }

  /// 文字修改后重新定位该页批注：优先在旧位置附近找原文片段，
  /// 找不到再全页找；都找不到就把偏移夹到合法范围，避免越界。
  Future<void> reanchorAnnotations(int pageId, String newContent) async {
    final anns = await (db.select(db.annotations)
          ..where((a) => a.pageId.equals(pageId)))
        .get();
    for (final a in anns) {
      if (a.anchorText.isEmpty) {
        continue;
      }
      var idx = _findNear(newContent, a.anchorText, a.startOffset);
      if (idx < 0) {
        idx = newContent.indexOf(a.anchorText);
      }
      if (idx >= 0) {
        await (db.update(db.annotations)..where((x) => x.id.equals(a.id)))
            .write(AnnotationsCompanion(
          startOffset: Value(idx),
          endOffset: Value(idx + a.anchorText.length),
        ));
      } else {
        final end =
            a.endOffset > newContent.length ? newContent.length : a.endOffset;
        final start =
            a.startOffset > end ? end : a.startOffset;
        await (db.update(db.annotations)..where((x) => x.id.equals(a.id)))
            .write(AnnotationsCompanion(
          startOffset: Value(start),
          endOffset: Value(end),
        ));
      }
    }
  }

  /// 在 [text] 的 [near] 附近（±150 字）找 [needle]，返回绝对位置，找不到 -1。
  int _findNear(String text, String needle, int near) {
    if (text.isEmpty || needle.isEmpty) {
      return -1;
    }
    final from = (near - 150).clamp(0, text.length).toInt();
    final to = (near + 150 + needle.length).clamp(0, text.length).toInt();
    final sub = text.substring(from, to);
    final rel = sub.indexOf(needle);
    return rel < 0 ? -1 : from + rel;
  }

  /// 读取设置项。
  Future<String?> getSetting(String key) async {
    final row = await (db.select(db.appSettings)
          ..where((s) => s.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  /// 写入设置项（存在则覆盖）。
  Future<void> setSetting(String key, String value) async {
    await db.into(db.appSettings).insertOnConflictUpdate(
        AppSettingsCompanion.insert(key: key, value: value));
  }

  // ===== 阅读计时与统计（批次 10） =====

  /// 开始一次阅读：更新书的最近阅读时间，并创建一条会话（时长 0）。
  Future<int> startReadingSession(int bookId) async {
    final now = DateTime.now();
    await (db.update(db.books)..where((b) => b.id.equals(bookId)))
        .write(BooksCompanion(lastReadAt: Value(now)));
    return db.into(db.readingSessions).insert(ReadingSessionsCompanion.insert(
          bookId: bookId,
          startedAt: now,
          endedAt: now,
          durationSeconds: 0,
        ));
  }

  /// 阅读过程中定期刷新会话时长（防 App 被杀丢数据）。
  Future<void> tickReadingSession(int sessionId, int seconds) {
    return (db.update(db.readingSessions)
          ..where((s) => s.id.equals(sessionId)))
        .write(ReadingSessionsCompanion(
      endedAt: Value(DateTime.now()),
      durationSeconds: Value(seconds),
    ));
  }

  /// 结束阅读会话：写入时长并累计到书的总时长。
  Future<void> finishReadingSession(int sessionId, int seconds) async {
    final session = await (db.select(db.readingSessions)
          ..where((s) => s.id.equals(sessionId)))
        .getSingleOrNull();
    if (session == null) {
      return;
    }
    final book = await (db.select(db.books)
          ..where((b) => b.id.equals(session.bookId)))
        .getSingleOrNull();
    if (book == null) {
      return;
    }
    await db.transaction(() async {
      await (db.update(db.readingSessions)
            ..where((s) => s.id.equals(sessionId)))
          .write(ReadingSessionsCompanion(
        endedAt: Value(DateTime.now()),
        durationSeconds: Value(seconds),
      ));
      await (db.update(db.books)..where((b) => b.id.equals(session.bookId)))
          .write(BooksCompanion(
        totalReadSeconds: Value(book.totalReadSeconds + seconds),
      ));
    });
  }

  /// 全部阅读会话（按开始时间倒序，响应式），用于统计时间轴。
  Stream<List<ReadingSession>> watchReadingSessions() {
    final q = db.select(db.readingSessions)
      ..orderBy([(s) => OrderingTerm.desc(s.startedAt)]);
    return q.watch();
  }

  // ===== 书关联（八爪鱼，批次 13 简化版） =====

  /// 本书出发指向的书（关联 + 目标书，响应式）。
  Stream<List<(BookLink, Book)>> watchOutLinks(int bookId) {
    final q = db.select(db.bookLinks).join([
      innerJoin(db.books, db.books.id.equalsExp(db.bookLinks.toBookId)),
    ])
      ..where(db.bookLinks.fromBookId.equals(bookId))
      ..orderBy([OrderingTerm.asc(db.bookLinks.createdAt)]);
    return q.watch().map((rows) => [
          for (final r in rows)
            (r.readTable(db.bookLinks), r.readTable(db.books)),
        ]);
  }

  /// 别的书指向本书的关联（关联 + 来源书，响应式）。
  Stream<List<(BookLink, Book)>> watchInLinks(int bookId) {
    final q = db.select(db.bookLinks).join([
      innerJoin(db.books, db.books.id.equalsExp(db.bookLinks.fromBookId)),
    ])
      ..where(db.bookLinks.toBookId.equals(bookId))
      ..orderBy([OrderingTerm.asc(db.bookLinks.createdAt)]);
    return q.watch().map((rows) => [
          for (final r in rows)
            (r.readTable(db.bookLinks), r.readTable(db.books)),
        ]);
  }

  /// 新增一条关联：从 [fromBookId] 指向 [toBookId]。
  Future<int> addLink(int fromBookId, int toBookId, String note) {
    return db.into(db.bookLinks).insert(BookLinksCompanion.insert(
          fromBookId: fromBookId,
          toBookId: toBookId,
          note: Value(note),
        ));
  }

  /// 修改关联备注。
  Future<void> updateLinkNote(int linkId, String note) {
    return (db.update(db.bookLinks)..where((l) => l.id.equals(linkId)))
        .write(BookLinksCompanion(note: Value(note)));
  }

  /// 标记关联书已读 / 未读。
  Future<void> setLinkRead(int linkId, bool read) {
    return (db.update(db.bookLinks)..where((l) => l.id.equals(linkId)))
        .write(BookLinksCompanion(read: Value(read)));
  }

  /// 删除一条关联。
  Future<void> deleteLink(int linkId) {
    return (db.delete(db.bookLinks)..where((l) => l.id.equals(linkId))).go();
  }

  /// 写入某页的缩略图副本路径。
  Future<void> setPageThumb(int pageId, String path) {
    return (db.update(db.pages)..where((pg) => pg.id.equals(pageId)))
        .write(PagesCompanion(thumbPath: Value(path)));
  }

  /// 保存阅读进度百分比（只增不减，防止误写小值）。
  /// 首次达到 95% 时记录“读完时间”（只记一次，之后不再覆盖）。
  Future<void> setBookReadPercent(int bookId, int percent) async {
    final book = await (db.select(db.books)
          ..where((b) => b.id.equals(bookId)))
        .getSingleOrNull();
    if (book == null) {
      return;
    }
    final next = percent > book.readPercent ? percent : book.readPercent;
    final finishedAt = next >= 95 && book.finishedAt == null
        ? DateTime.now()
        : null;
    await (db.update(db.books)..where((b) => b.id.equals(bookId)))
        .write(BooksCompanion(
      readPercent: Value(next),
      finishedAt: finishedAt == null
          ? const Value.absent()
          : Value(finishedAt),
    ));
  }
}

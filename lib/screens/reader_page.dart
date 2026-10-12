import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart' hide Page;
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../data/app_database.dart';
import '../data/book_repository.dart';
import '../services/book_audio_handler.dart';
import '../services/ocr_engine.dart';
import '../services/ocr_service.dart';
import '../services/sherpa_tts.dart';
import '../theme/app_theme.dart';
import 'listen_page.dart';
import 'photo_viewer_page.dart';
import 'proofread_page.dart';

/// 纸色方案：键 → (背景色, 文字色)
const Map<String, (Color, Color)> _papers = {
  'warm': (Color(0xFFF3E9D2), Color(0xFF3B3428)),
  'white': (Color(0xFFFBF8F1), Color(0xFF332E26)),
  'dark': (Color(0xFF211C17), Color(0xFFD9CDB8)),
};

/// 一段可点朗读的文字（页内偏移 + 全局段索引）。
class _Para {
  const _Para({
    required this.page,
    required this.globalIndex,
    required this.localStart,
    required this.localEnd,
  });

  final Page page;
  final int globalIndex; // 与 bookAudioHandler.segments 对齐
  final int localStart; // 在 page.content 中的起点
  final int localEnd;
}

/// 一个逻辑阅读页（照片页按字号/行距重排后的子页）。
class _LogicalPage {
  const _LogicalPage({
    required this.page,
    required this.startOffset,
    required this.endOffset,
  });

  /// 末尾的“导入书页”特殊页（page 为空）。
  const _LogicalPage.importSlot()
      : page = null,
        startOffset = 0,
        endOffset = 0;

  final Page? page;
  final int startOffset; // 在 page.content 内
  final int endOffset;
  bool get isImportSlot => page == null; // true = 永久位于最后的导入照片页
}

/// 阅读器：整本书纯文字连续排版，可调字号/行距/纸色；
/// 选中文字可加横线、红色高亮、批注（锚定原文位置）；
/// 可随时进入校对修改文字（批注位置自动跟随调整）。
///
/// 本轮升级：
/// - 页面模式按屏幕宽高 + 字号动态分页，字号变大后溢出内容自动成为新页；
/// - 听书内嵌：点任意一段即从该段开始朗读，朗读中该段高亮并滚动跟随，
///   底部迷你播放条控制播放/暂停/上一段/下一段/倍速/进度；
/// - 空书页直接提供“虚线框 + 加号”入口：拍摄或相册导入照片并自动识别。
class ReaderPage extends StatefulWidget {
  const ReaderPage({
    super.key,
    required this.repository,
    required this.book,
    this.initialPageIndex = 0,
  });

  final BookRepository repository;
  final Book book;

  /// 打开后定位到第几页（0 起，按全书页序；章节直达用）。
  final int initialPageIndex;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  final _scrollCtrl = ScrollController();
  late final PageController _pageCtrl;
  StreamSubscription<List<Page>>? _pagesSub;
  StreamSubscription<List<Annotation>>? _annsSub;
  StreamSubscription<int>? _curSegSub;

  List<Page> _pages = const [];
  List<Annotation> _annotations = const [];

  // 拼接文本的定位信息（滚动模式 build 时计算）
  final List<int> _pageStarts = [];
  List<int> _pageIds = const [];
  String _fullText = '';
  int _totalLen = 0;

  // 阅读设置（持久化到 AppSettings）
  double _fontSize = 17;
  double _lineHeight = 1.8;
  String _paper = 'warm';

  // 当前阅读页（逻辑页索引）
  int _currentPageIndex = 0;

  // 阅读模式：true = 左右翻页（默认），false = 连续滚动
  bool _pageMode = true;
  bool _initialJumpDone = false;

  // 动态分页缓存
  List<_LogicalPage> _logicalPages = const <_LogicalPage>[];
  List<_Para> _paras = const <_Para>[];
  final Map<int, List<(int, int)>> _pageParaCache = {};
  int _layoutVersion = 0;
  int _anchorPhotoIndex = 0;
  int? _pendingPhotoJump;

  // 照片导入 / OCR（空书时用）
  final _picker = ImagePicker();
  bool _ocrRunning = false;
  String _ocrStatus = '';

  // 已安装的离线音色（供迷你条切换）
  Map<String, bool> _voiceInstalled = <String, bool>{};

  Future<void> _refreshVoices() async {
    final m = <String, bool>{};
    for (final v in kSherpaVoices) {
      m[v.id] = await TtsModelManager.instance.isInstalled(v);
    }
    if (mounted) {
      setState(() => _voiceInstalled = m);
    }
  }

  /// 听书过程中切换音色（从当前段继续）。
  Future<void> _switchVoice(String voiceId) async {
    _snack('正在切换到「${sherpaVoiceById(voiceId).displayName}」…');
    final r = await bookAudioHandler.switchVoice(voiceId);
    if (!mounted) {
      return;
    }
    if (!r.ok) {
      _snack('切换失败，请重试');
      return;
    }
    await widget.repository.setSetting(kSherpaVoiceSetting, voiceId);
    setState(() {});
  }

  // 阅读计时
  int? _sessionId;
  DateTime? _sessionStart;
  Timer? _tickTimer;

  Book get book => widget.book;

  @override
  void initState() {
    super.initState();
    _currentPageIndex = 0;
    _anchorPhotoIndex = widget.initialPageIndex;
    _pageCtrl = PageController(initialPage: 0);
    _refreshVoices();
    _pagesSub = widget.repository.watchPages(book.id).listen((pages) {
      if (mounted) {
        setState(() => _pages = pages);
      }
    });
    _annsSub = widget.repository.watchAnnotations(book.id).listen((anns) {
      if (mounted) {
        setState(() => _annotations = anns);
      }
    });
    _curSegSub = bookAudioHandler.currentSegment.listen((idx) {
      if (!mounted || idx < 0 || _pageMode == false) {
        return;
      }
      _followSegment(idx);
    });
    _loadSettings();
    _scrollCtrl.addListener(_onScroll);
    _startSession();
  }

  @override
  void dispose() {
    _pagesSub?.cancel();
    _annsSub?.cancel();
    _curSegSub?.cancel();
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    _pageCtrl.dispose();
    _finishSession();
    super.dispose();
  }

  // ===== 阅读计时（批次 10） =====

  Future<void> _startSession() async {
    _sessionStart = DateTime.now();
    _sessionId = await widget.repository.startReadingSession(book.id);
    _tickTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      final id = _sessionId;
      final start = _sessionStart;
      if (id != null && start != null) {
        unawaited(widget.repository.tickReadingSession(
            id, DateTime.now().difference(start).inSeconds));
      }
    });
  }

  void _finishSession() {
    _tickTimer?.cancel();
    _tickTimer = null;
    final id = _sessionId;
    final start = _sessionStart;
    _sessionId = null;
    _sessionStart = null;
    if (id != null && start != null) {
      unawaited(widget.repository.finishReadingSession(
          id, DateTime.now().difference(start).inSeconds));
    }
    // 保存阅读进度百分比（按照片页）
    if (_pages.isNotEmpty) {
      final photo = _currentPhotoIndex();
      final percent =
          ((photo + 1) * 100 ~/ _pages.length).clamp(0, 100);
      unawaited(widget.repository.setBookReadPercent(book.id, percent));
    }
  }

  /// 当前逻辑页对应的照片页下标。
  int _currentPhotoIndex() {
    if (_logicalPages.isEmpty) {
      return _anchorPhotoIndex.clamp(0, math.max(0, _pages.length - 1));
    }
    final lp = _logicalPages[_currentPageIndex.clamp(
        0, _logicalPages.length - 1)];
    if (lp.page == null) {
      // 导入页：对应最后一张照片之后
      return math.max(0, _pages.length - 1);
    }
    final idx = _pageIds.indexOf(lp.page!.id);
    return idx < 0 ? 0 : idx;
  }

  /// 滚动时估算当前阅读页（按已滚长度占全文比例）。
  void _onScroll() {
    if (!_scrollCtrl.hasClients || _totalLen == 0) {
      return;
    }
    final max = _scrollCtrl.position.maxScrollExtent;
    final fraction =
        max <= 0 ? 0.0 : (_scrollCtrl.offset / max).clamp(0.0, 1.0);
    final global =
        (fraction * _totalLen).toInt().clamp(0, _totalLen - 1).toInt();
    final loc = _locate(global);
    if (loc == null) {
      return;
    }
    final idx = _pageIds.indexOf(loc.$1);
    if (idx >= 0 && idx != _currentPageIndex) {
      setState(() => _currentPageIndex = idx);
    }
  }

  Future<void> _loadSettings() async {
    final repo = widget.repository;
    final fontSize = await repo.getSetting('reader.fontSize');
    final lineHeight = await repo.getSetting('reader.lineHeight');
    final paper = await repo.getSetting('reader.paper');
    final pageMode = await repo.getSetting('reader.pageMode');
    if (mounted) {
      setState(() {
        _fontSize = double.tryParse(fontSize ?? '') ?? 17;
        _lineHeight = double.tryParse(lineHeight ?? '') ?? 1.8;
        _paper = _papers.containsKey(paper) ? paper! : 'warm';
        _pageMode = pageMode != 'scroll';
      });
    }
  }

  Future<void> _toggleMode() async {
    final keep = _currentPhotoIndex();
    setState(() {
      _pageMode = !_pageMode;
      _layoutVersion++;
      _pendingPhotoJump = keep;
    });
    await widget.repository
        .setSetting('reader.pageMode', _pageMode ? 'page' : 'scroll');
  }

  void _snack(String msg) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // ===== 段落 / 逻辑页构建 =====

  /// 页内段落边界（页内偏移），按连续两个换行切分。
  List<(int, int)> _pageParas(Page page) {
    final cached = _pageParaCache[page.id];
    if (cached != null) {
      return cached;
    }
    final c = page.content;
    final out = <(int, int)>[];
    var s = 0;
    for (var i = 0; i < c.length; i++) {
      if (c.codeUnitAt(i) == 10 &&
          i + 1 < c.length &&
          c.codeUnitAt(i + 1) == 10) {
        if (c.substring(s, i).trim().isNotEmpty) {
          out.add((s, i));
        }
        s = i + 2;
      }
    }
    if (c.substring(s).trim().isNotEmpty) {
      out.add((s, c.length));
    }
    _pageParaCache[page.id] = out;
    return out;
  }

  /// 全书段落流（与 bookAudioHandler.segments 顺序一致）。
  List<_Para> _buildParas() {
    final result = <_Para>[];
    var gi = 0;
    for (final page in _pages) {
      if (page.content.trim().isEmpty) {
        continue;
      }
      for (final (s, e) in _pageParas(page)) {
        result.add(_Para(
          page: page,
          globalIndex: gi++,
          localStart: s,
          localEnd: e,
        ));
      }
    }
    return result;
  }

  /// 按屏幕可用宽高 + 字号/行距把照片页内容重排成逻辑页。
  List<_LogicalPage> _layoutPages(double availW, double availH) {
    final fontSize = _fontSize;
    final charsPerLine = math.max(4, (availW / fontSize).floor());
    final lineH = fontSize * _lineHeight;
    final linesPerPage = math.max(4, (availH / lineH).floor());
    // 每页容量按「可视行数 - 1」估算：宁可少装一行，也绝不让最后一行
    // 溢出被裁掉（用户反馈横版翻页缺最后一行）。
    final capacity =
        math.max(24, (charsPerLine * (linesPerPage - 1) * 0.95).floor());

    final result = <_LogicalPage>[];
    for (final page in _pages) {
      final paras = _pageParas(page);
      var curStart = 0;
      var curLen = 0;
      for (final (s, e) in paras) {
        final segLen = e - s;
        if (curLen + segLen <= capacity) {
          curLen += segLen;
        } else {
          if (curLen > 0) {
            result.add(_LogicalPage(
                page: page, startOffset: curStart, endOffset: curStart + curLen));
          }
          if (segLen > capacity) {
            // 超长段硬切
            var cut = s;
            var rest = segLen;
            while (rest > capacity) {
              result.add(_LogicalPage(
                  page: page, startOffset: cut, endOffset: cut + capacity));
              cut += capacity;
              rest -= capacity;
            }
            curStart = cut;
            curLen = rest;
          } else {
            curStart = s;
            curLen = segLen;
          }
        }
      }
      if (curLen > 0) {
        result.add(_LogicalPage(
            page: page, startOffset: curStart, endOffset: curStart + curLen));
      }
    }
    if (result.isEmpty && _pages.isNotEmpty) {
      final page = _pages.first;
      result.add(_LogicalPage(page: page, startOffset: 0, endOffset: 0));
    }
    // 末尾永远保留一个“导入书页”页：翻到最后再翻一页即是。
    result.add(const _LogicalPage.importSlot());
    return result;
  }

  /// 段 → 包含它的第一个逻辑页下标。
  int _logicalIndexForPara(_Para para) {
    for (var i = 0; i < _logicalPages.length; i++) {
      final lp = _logicalPages[i];
      if (lp.page?.id == para.page.id &&
          lp.endOffset > para.localStart &&
          lp.startOffset <= para.localEnd) {
        return i;
      }
    }
    return -1;
  }

  /// 当前播放段变化时：高亮所在的逻辑页并滚动跟随。
  void _followSegment(int globalIndex) {
    if (_paras.isEmpty || _logicalPages.isEmpty) {
      return;
    }
    if (globalIndex < 0 || globalIndex >= _paras.length) {
      setState(() {});
      return;
    }
    final para = _paras[globalIndex];
    final lpIdx = _logicalIndexForPara(para);
    setState(() {});
    if (lpIdx >= 0 && lpIdx != _currentPageIndex) {
      if (_pageCtrl.hasClients) {
        _pageCtrl.animateToPage(
          lpIdx,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOut,
        );
      }
      setState(() => _currentPageIndex = lpIdx);
    }
  }

  // ===== 文本与批注渲染 =====

  (Color, Color) get _paperColors => _papers[_paper] ?? _papers['warm']!;

  TextStyle _baseStyle(Color fg) => TextStyle(
        color: fg,
        fontSize: _fontSize,
        height: _lineHeight,
      );

  TextStyle _annotationStyle(Annotation a, Color fg) {
    switch (a.type) {
      case 'highlight':
        return TextStyle(
          color: fg,
          fontSize: _fontSize,
          height: _lineHeight,
          backgroundColor: const Color(0x55B03A2B),
        );
      case 'underline':
        return TextStyle(
          color: fg,
          fontSize: _fontSize,
          height: _lineHeight,
          decoration: TextDecoration.underline,
          decorationColor: const Color(0xFFB03A2B),
          decorationThickness: 1.4,
        );
      case 'note':
        return TextStyle(
          color: fg,
          fontSize: _fontSize,
          height: _lineHeight,
          decoration: TextDecoration.underline,
          decorationColor: AppColors.gold,
          decorationStyle: TextDecorationStyle.dashed,
        );
      default:
        return _baseStyle(fg);
    }
  }

  /// 滚动模式：把所有页的文字连成一段，记录每页内容的全局起点。
  List<InlineSpan> _buildSpans(Color fg) {
    final spans = <InlineSpan>[];
    _pageStarts.clear();
    final annsByPage = <int, List<Annotation>>{};
    for (final a in _annotations) {
      annsByPage.putIfAbsent(a.pageId, () => []).add(a);
    }
    final buffer = StringBuffer();
    for (var i = 0; i < _pages.length; i++) {
      final page = _pages[i];
      if (i > 0) {
        buffer.write('\n\n');
        spans.add(const TextSpan(text: '\n\n'));
      }
      _pageStarts.add(buffer.length);
      buffer.write(page.content);
      final content = page.content;
      final anns = (annsByPage[page.id] ?? const <Annotation>[])
          .where((a) =>
              a.startOffset >= 0 &&
              a.startOffset < a.endOffset &&
              a.endOffset <= content.length)
          .toList()
        ..sort((a, b) => a.startOffset.compareTo(b.startOffset));
      var cursor = 0;
      for (final a in anns) {
        if (a.startOffset > cursor) {
          spans.add(TextSpan(text: content.substring(cursor, a.startOffset)));
        }
        spans.add(TextSpan(
          text: content.substring(a.startOffset, a.endOffset),
          style: _annotationStyle(a, fg),
        ));
        cursor = a.endOffset;
      }
      if (cursor < content.length) {
        spans.add(TextSpan(text: content.substring(cursor)));
      }
    }
    _pageIds = _pages.map((p) => p.id).toList();
    _fullText = buffer.toString();
    _totalLen = _fullText.length;
    return spans;
  }

  /// 全局偏移 → (页 id, 页内偏移)。
  (int, int)? _locate(int globalOffset) {
    if (_pageStarts.isEmpty) {
      return null;
    }
    var p = 0;
    for (var i = 0; i < _pageStarts.length; i++) {
      if (globalOffset >= _pageStarts[i]) {
        p = i;
      } else {
        break;
      }
    }
    final page = _pages[p];
    final local = (globalOffset - _pageStarts[p])
        .clamp(0, page.content.length)
        .toInt();
    return (page.id, local);
  }

  /// 区间内批注（裁剪到 [lo, hi) 并平移偏移）。
  List<Annotation> _annsIn(Page page, int lo, int hi) {
    final out = <Annotation>[];
    for (final a in _annotations) {
      if (a.pageId != page.id ||
          a.startOffset >= a.endOffset ||
          a.endOffset <= lo ||
          a.startOffset >= hi) {
        continue;
      }
      final s = math.max(a.startOffset, lo) - lo;
      final e = math.min(a.endOffset, hi) - lo;
      if (s < e) {
        out.add(Annotation(
          id: a.id,
          pageId: a.pageId,
          groupId: a.groupId,
          type: a.type,
          color: a.color,
          startOffset: s,
          endOffset: e,
          anchorText: a.anchorText,
          noteText: a.noteText,
          createdAt: a.createdAt,
        ));
      }
    }
    out.sort((a, b) => a.startOffset.compareTo(b.startOffset));
    return out;
  }

  /// 段内 spans（逻辑页/段共用）。
  List<InlineSpan> _spansFor(String text, List<Annotation> anns, Color fg) {
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final a in anns) {
      if (a.startOffset > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, a.startOffset)));
      }
      spans.add(TextSpan(
        text: text.substring(a.startOffset, a.endOffset),
        style: _annotationStyle(a, fg),
      ));
      cursor = a.endOffset;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    return spans;
  }

  // ===== 批注操作 =====

  void _handleSelection(EditableTextState state, String action) {
    final sel = state.textEditingValue.selection;
    state.hideToolbar();
    if (!sel.isValid || sel.isCollapsed) {
      _snack('先选中一段文字，再操作');
      return;
    }
    if (action == 'copy') {
      final text = _selectionText(sel.start, sel.end);
      Clipboard.setData(ClipboardData(text: text));
      return;
    }
    _annotate(sel.start, sel.end, action);
  }

  String _selectionText(int start, int end) {
    if (_fullText.isEmpty || start >= _fullText.length) {
      return '';
    }
    final to = end.clamp(0, _fullText.length).toInt();
    return _fullText.substring(start, to);
  }

  /// 添加批注（滚动模式）：支持跨页/跨行，自动按页拆成多个片段。
  Future<void> _annotate(int start, int end, String action) async {
    final locStart = _locate(start);
    final locEnd = _locate(end);
    if (locStart == null || locEnd == null) {
      _snack('先选中一段文字，再操作');
      return;
    }
    final startIdx = _pageIds.indexOf(locStart.$1);
    final endIdx = _pageIds.indexOf(locEnd.$1);
    if (startIdx < 0 || endIdx < 0) {
      _snack('找不到对应的书页，请重试');
      return;
    }
    final segments = <(int, int, int)>[];
    final anchors = <String>[];
    for (var i = startIdx; i <= endIdx; i++) {
      final page = _pages[i];
      final s = i == startIdx ? locStart.$2 : 0;
      final e = i == endIdx ? locEnd.$2 : page.content.length;
      if (s < e) {
        final anchor = page.content.substring(s, e).trim();
        if (anchor.isNotEmpty) {
          segments.add((page.id, s, e));
          anchors.add(anchor);
        }
      }
    }
    if (segments.isEmpty) {
      _snack('选中的文字太短，换个位置再试');
      return;
    }
    var noteText = '';
    if (action == 'note') {
      final ctrl = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('写批注 / 读后感',
              style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            maxLines: 4,
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: InputDecoration(
              hintText: '写在选中文字旁边的话…',
              hintStyle: const TextStyle(color: AppColors.textSecondary),
              filled: true,
              fillColor: AppColors.surfaceHigh,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppColors.outline),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消',
                  style: TextStyle(color: AppColors.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存', style: TextStyle(color: AppColors.gold)),
            ),
          ],
        ),
      );
      if (ok != true) {
        return;
      }
      noteText = ctrl.text.trim();
      if (noteText.isEmpty) {
        return;
      }
    }
    await widget.repository.addAnnotationGroup(
      segments: segments,
      anchors: anchors,
      type: action == 'underline'
          ? 'underline'
          : action == 'highlight'
              ? 'highlight'
              : 'note',
      noteText: noteText,
    );
    _snack(action == 'note'
        ? '批注已写好'
        : action == 'highlight'
            ? '已加红色高亮'
            : '已加横线');
  }

  Widget _menuBuilder(BuildContext context, EditableTextState state) {
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: [
        ContextMenuButtonItem(
          label: '横线',
          onPressed: () => _handleSelection(state, 'underline'),
        ),
        ContextMenuButtonItem(
          label: '红色高亮',
          onPressed: () => _handleSelection(state, 'highlight'),
        ),
        ContextMenuButtonItem(
          label: '写批注',
          onPressed: () => _handleSelection(state, 'note'),
        ),
        ContextMenuButtonItem(
          label: '复制',
          onPressed: () => _handleSelection(state, 'copy'),
        ),
      ],
    );
  }

  // ===== 批注列表 =====

  List<(int, List<Annotation>)> _annotationGroups() {
    final map = <int, List<Annotation>>{};
    for (final a in _annotations) {
      map.putIfAbsent(a.groupId, () => []).add(a);
    }
    final keys = map.keys.toList();
    return [for (final k in keys) (k, map[k]!)];
  }

  void _openAnnotationList() {
    if (_annotations.isEmpty) {
      _snack('还没有批注。选中一段文字长按即可添加');
      return;
    }
    final groups = _annotationGroups();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text('批注（${groups.length} 条）',
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final (groupId, list) in groups)
                    _annotationTile(ctx, groupId, list),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _annotationTile(
      BuildContext ctx, int groupId, List<Annotation> list) {
    final first = list.first;
    final last = list.last;
    final page = _pages.where((p) => p.id == first.pageId).toList();
    final firstOrder = page.isEmpty ? -1 : page.first.orderIndex;
    final lastPage = _pages.where((p) => p.id == last.pageId).toList();
    final lastOrder = lastPage.isEmpty ? -1 : lastPage.first.orderIndex;
    final icon = first.type == 'highlight'
        ? Icons.border_color
        : first.type == 'note'
            ? Icons.sticky_note_2_outlined
            : Icons.format_underline;
    final color =
        first.type == 'note' ? AppColors.gold : const Color(0xFFB03A2B);
    final anchorPreview = list.map((a) => a.anchorText).join(' … ').trim();
    final pageLabel =
        firstOrder == lastOrder ? '第 $firstOrder 页' : '第 $firstOrder-$lastOrder 页';
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 20, color: color),
      title: Text(
        anchorPreview.isEmpty ? '（空）' : anchorPreview,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
      ),
      subtitle: Text(
        '$pageLabel'
        '${first.noteText.isEmpty ? '' : ' · ${first.noteText}'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
      ),
      trailing: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert,
            size: 18, color: AppColors.textSecondary),
        onSelected: (v) => _annotationAction(groupId, first, v),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'jump', child: Text('跳到位置')),
          PopupMenuItem(value: 'edit', child: Text('修改批注文字')),
          PopupMenuItem(value: 'delete', child: Text('删除')),
        ],
      ),
      onTap: () {
        Navigator.pop(ctx);
        _jumpToAnnotation(first);
      },
    );
  }

  Future<void> _annotationAction(
      int groupId, Annotation first, String action) async {
    if (action == 'jump') {
      if (Navigator.canPop(context)) {
        Navigator.pop(context);
      }
      _jumpToAnnotation(first);
    } else if (action == 'edit') {
      final ctrl = TextEditingController(text: first.noteText);
      final result = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('修改批注文字',
              style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            maxLines: 4,
            style: const TextStyle(color: AppColors.textPrimary),
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
        await widget.repository.updateGroupNote(groupId, result);
      }
    } else if (action == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('删除这条批注？',
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
        await widget.repository.deleteGroup(groupId);
      }
    }
  }

  void _jumpToAnnotation(Annotation a) {
    if (_pageMode) {
      // 页面模式：跳到包含该页的第一个逻辑页
      for (var i = 0; i < _logicalPages.length; i++) {
        final lp = _logicalPages[i];
        if (lp.page?.id == a.pageId && lp.endOffset > a.startOffset) {
          _pageCtrl.animateToPage(
            i,
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOut,
          );
          setState(() => _currentPageIndex = i);
          return;
        }
      }
      return;
    }
    final idx = _pageIds.indexOf(a.pageId);
    if (idx < 0 || _totalLen == 0) {
      return;
    }
    final global = _pageStarts[idx] + a.startOffset;
    final fraction = (global / _totalLen).clamp(0.0, 1.0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtrl.hasClients) {
        return;
      }
      _scrollCtrl.animateTo(
        fraction * _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
      );
    });
  }

  // ===== 阅读设置 =====

  void _openSettings() {
    var fontSize = _fontSize;
    var lineHeight = _lineHeight;
    var paper = _paper;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Center(
                  child: Text('阅读设置',
                      style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                ),
                const SizedBox(height: 12),
                Text('字号 ${fontSize.round()}',
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 13)),
                Slider(
                  value: fontSize,
                  min: 13,
                  max: 24,
                  divisions: 11,
                  activeColor: AppColors.gold,
                  onChanged: (v) => setSheet(() => fontSize = v),
                ),
                Text('行距',
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 13)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    for (final opt in const [
                      (1.4, '紧凑'),
                      (1.8, '适中'),
                      (2.2, '宽松'),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(opt.$2),
                          selected: lineHeight == opt.$1,
                          onSelected: (_) =>
                              setSheet(() => lineHeight = opt.$1),
                          backgroundColor: AppColors.surfaceHigh,
                          selectedColor: AppColors.surface,
                          checkmarkColor: AppColors.gold,
                          showCheckmark: false,
                          side: BorderSide(
                              color: lineHeight == opt.$1
                                  ? AppColors.gold
                                  : AppColors.outline),
                          labelStyle: TextStyle(
                              fontSize: 13,
                              color: lineHeight == opt.$1
                                  ? AppColors.textPrimary
                                  : AppColors.textSecondary),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Text('纸色',
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 13)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    for (final opt in const [
                      ('warm', '暖黄'),
                      ('white', '纸白'),
                      ('dark', '墨色'),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(opt.$2),
                          selected: paper == opt.$1,
                          onSelected: (_) => setSheet(() => paper = opt.$1),
                          backgroundColor: AppColors.surfaceHigh,
                          selectedColor: AppColors.surface,
                          checkmarkColor: AppColors.gold,
                          showCheckmark: false,
                          side: BorderSide(
                              color: paper == opt.$1
                                  ? AppColors.gold
                                  : AppColors.outline),
                          labelStyle: TextStyle(
                              fontSize: 13,
                              color: paper == opt.$1
                                  ? AppColors.textPrimary
                                  : AppColors.textSecondary),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () async {
                      await widget.repository
                          .setSetting('reader.fontSize', fontSize.toString());
                      await widget.repository.setSetting(
                          'reader.lineHeight', lineHeight.toString());
                      await widget.repository
                          .setSetting('reader.paper', paper);
                      if (ctx.mounted) {
                        Navigator.pop(ctx);
                      }
                      if (mounted) {
                        final keep = _currentPhotoIndex();
                        setState(() {
                          _fontSize = fontSize;
                          _lineHeight = lineHeight;
                          _paper = paper;
                          _layoutVersion++;
                          _pendingPhotoJump = keep;
                        });
                      }
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.gold,
                      foregroundColor: AppColors.background,
                    ),
                    child: const Text('应用'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ===== 听书（内嵌） =====

  /// 打开本书听书（复用全局 handler），并开始播放。
  Future<void> _startListen() async {
    final r = await bookAudioHandler.openBook(widget.book);
    if (!mounted) {
      return;
    }
    if (r.modelMissing) {
      _snack('请先到「设置 → 离线语音」下载语音「${r.voiceName}」');
      return;
    }
    if (r.empty) {
      _snack('还没有可听的文字，先导入照片识别吧');
      return;
    }
    if (r.ok) {
      // 立即刷新界面，让迷你播放条与“正在准备”提示马上出现
      _refreshVoices();
      setState(() {});
      // 优先从上次记忆位置，否则从当前阅读段开始
      final memIdx = int.tryParse(
              await widget.repository.getSetting(
                      'listen.${book.id}.index') ??
                  '') ??
          -1;
      final startIdx = (memIdx >= 0 && memIdx < r.segmentCount)
          ? memIdx
          : _currentSegmentForPage();
      await bookAudioHandler.playFromSegment(startIdx);
    }
  }

  /// 当前阅读页内第一段的全局索引（无则 0）。
  int _currentSegmentForPage() {
    if (_paras.isEmpty) {
      return 0;
    }
    final lp = _logicalPages.isNotEmpty
        ? _logicalPages[_currentPageIndex
            .clamp(0, _logicalPages.length - 1)]
        : null;
    if (lp == null || lp.page == null) {
      return 0;
    }
    for (var i = 0; i < _paras.length; i++) {
      final para = _paras[i];
      if (para.page.id == lp.page!.id && para.localEnd > lp.startOffset) {
        return i;
      }
    }
    return 0;
  }

  /// 点击某段 → 从该段开始朗读。
  Future<void> _playSegment(int globalIndex) async {
    if (bookAudioHandler.currentBookId != '${book.id}') {
      final r = await bookAudioHandler.openBook(widget.book);
      if (!mounted) {
        return;
      }
        if (!r.ok) {
          if (r.modelMissing) {
            _snack('请先到「设置 → 离线语音」下载语音「${r.voiceName}」');
          } else {
            _snack(r.empty ? '还没有可听的文字' : '听书准备失败，请重试');
          }
          return;
        }
        _refreshVoices();
        setState(() {});
      }
    await bookAudioHandler.playFromSegment(globalIndex);
  }

  // ===== 照片导入（空书页） =====

  Future<void> _importFromGallery() async {
    try {
      final files = await _picker.pickMultiImage(
          imageQuality: 92, maxWidth: 2000, limit: 60);
      if (files.isNotEmpty) {
        await _importPaths(files.map((f) => f.path).toList());
      }
    } catch (e) {
      _snack('导入失败：$e');
    }
  }

  Future<void> _takePhoto() async {
    try {
      final file = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 3000,
        imageQuality: 92,
      );
      if (file != null) {
        await _importPaths([file.path]);
      }
    } catch (e) {
      _snack('拍照失败：$e');
    }
  }

  /// 导入照片的统一入口：询问加入当前章节还是新建一章，然后落库并识别。
  Future<void> _importPaths(List<String> paths) async {
    final asNewChapter = await _askImportTarget();
    if (asNewChapter == null) {
      return; // 用户取消
    }
    int? chapterId;
    if (asNewChapter) {
      final chapters =
          await widget.repository.watchChapters(book.id).first;
      final title = await _askChapterTitle('第 ${chapters.length + 1} 章');
      if (title == null) {
        return;
      }
      chapterId = await widget.repository.createChapter(book.id, title);
    }
    final firstNewPhotoIndex = _pages.length;
    await widget.repository.addPagesFromPaths(
      book.id,
      paths,
      chapterId: chapterId,
    );
    _snack(asNewChapter
        ? '已新建章节并导入 ${paths.length} 张照片，正在识别…'
        : '已导入 ${paths.length} 张照片，正在识别…');
    // 导入后定位到新照片的第一页
    _pendingPhotoJump = firstNewPhotoIndex;
    if (_pageMode) {
      _layoutVersion++; // 触发 PageView 重建以应用跳转
    }
    unawaited(_startOcr());
  }

  /// 询问导入目标：false=加入当前位置，true=新建一章，null=取消。
  Future<bool?> _askImportTarget() {
    return showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('导入到哪里？',
                    style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.menu_book_outlined,
                  color: AppColors.gold),
              title: const Text('继续本书（当前章节）',
                  style: TextStyle(color: AppColors.textPrimary)),
              onTap: () => Navigator.pop(ctx, false),
            ),
            ListTile(
              leading: const Icon(Icons.post_add_outlined,
                  color: AppColors.gold),
              title: const Text('作为新的一章导入',
                  style: TextStyle(color: AppColors.textPrimary)),
              onTap: () => Navigator.pop(ctx, true),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 输入新章节标题（带默认值），取消返回 null。
  Future<String?> _askChapterTitle(String defaultTitle) {
    final ctrl = TextEditingController(text: defaultTitle);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('新章节标题',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: const InputDecoration(
            hintText: '如：第一章 引言',
            hintStyle: TextStyle(color: AppColors.textSecondary),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child:
                const Text('确定', style: TextStyle(color: AppColors.gold)),
          ),
        ],
      ),
    );
  }

  Future<void> _startOcr() async {
    if (_ocrRunning) {
      return;
    }
    setState(() {
      _ocrRunning = true;
      _ocrStatus = '准备中…';
    });
    final engine = MlKitOcrEngine();
    final service = OcrService(AppDatabase.instance, engine,
        repository: widget.repository);
    try {
      await service.processBook(
        book.id,
        onProgress: (done, total, status) {
          if (mounted) {
            setState(() => _ocrStatus = status);
          }
        },
      );
    } finally {
      engine.dispose();
      if (mounted) {
        setState(() => _ocrRunning = false);
      }
    }
  }

  void _showImportMenu() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined,
                  color: AppColors.gold),
              title: const Text('拍摄书页',
                  style: TextStyle(color: AppColors.textPrimary)),
              onTap: () {
                Navigator.pop(ctx);
                _takePhoto();
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined,
                  color: AppColors.gold),
              title: const Text('从相册选择',
                  style: TextStyle(color: AppColors.textPrimary)),
              onTap: () {
                Navigator.pop(ctx);
                _importFromGallery();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ===== 页面 =====

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = _paperColors;
    _paras = _buildParas();
    if (!_initialJumpDone && _pages.isNotEmpty) {
      _initialJumpDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _jumpToPhoto(_anchorPhotoIndex);
      });
    }
    // 字号变化 / 新导入照片后，跳回目标照片页（两种阅读模式都处理）
    final pending = _pendingPhotoJump;
    if (pending != null) {
      _pendingPhotoJump = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        _jumpToPhoto(pending);
        setState(() {});
      });
    }
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        foregroundColor: fg,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              book.title,
              style: TextStyle(color: fg, fontSize: 16),
            ),
            if (_pageMode && _logicalPages.isNotEmpty)
              Text(
                _currentPageIndex >= _logicalPages.length - 1
                    ? '添加书页'
                    : '第 ${_currentPageIndex + 1} / ${_logicalPages.length - 1} 页',
                style: TextStyle(
                    color: fg.withValues(alpha: 0.65), fontSize: 11),
              ),
            if (!_pageMode && _pages.isNotEmpty)
              Text(
                '第 ${_currentPhotoIndex() + 1} / ${_pages.length} 页',
                style: TextStyle(
                    color: fg.withValues(alpha: 0.65), fontSize: 11),
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '听书（内嵌播放）',
            onPressed: _startListen,
            icon: Icon(Icons.headphones_outlined, color: fg, size: 20),
          ),
          IconButton(
            tooltip: _pageMode ? '切到连续滚动' : '切到左右翻页',
            onPressed: _toggleMode,
            icon: Icon(
                _pageMode ? Icons.view_agenda_outlined : Icons.auto_stories,
                color: fg,
                size: 20),
          ),
          IconButton(
            tooltip: '查看原页照片',
            onPressed: () {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => PhotoViewerPage(
                  repository: widget.repository,
                  book: book,
                  initialIndex: _currentPhotoIndex(),
                ),
              ));
            },
            icon: Icon(Icons.image_outlined, color: fg, size: 20),
          ),
          IconButton(
            tooltip: '批注列表',
            onPressed: _openAnnotationList,
            icon: Badge(
              isLabelVisible: _annotations.isNotEmpty,
              label: Text('${_annotationGroups().length}'),
              child: Icon(Icons.notes, color: fg, size: 20),
            ),
          ),
          IconButton(
            tooltip: '阅读设置',
            onPressed: _openSettings,
            icon: Icon(Icons.text_fields, color: fg, size: 20),
          ),
          IconButton(
            tooltip: '校对本页',
            onPressed: () {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ProofreadPage(
                  repository: widget.repository,
                  book: book,
                  initialIndex: _currentPhotoIndex(),
                ),
              ));
            },
            icon: Icon(Icons.fact_check_outlined, color: fg, size: 20),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _pageMode
                ? _buildPageMode(fg)
                : (_pages.isEmpty
                    ? Center(child: _buildEmptyImport(fg))
                    : SingleChildScrollView(
                        controller: _scrollCtrl,
                        padding:
                            const EdgeInsets.fromLTRB(20, 8, 20, 48),
                        child: Column(
                          children: [
                            SelectableText.rich(
                              TextSpan(
                                style: _baseStyle(fg),
                                children: _buildSpans(fg),
                              ),
                              contextMenuBuilder: _menuBuilder,
                            ),
                            _buildScrollImportBar(fg),
                          ],
                        ),
                      )),
          ),
          _buildMiniPlayer(fg),
        ],
      ),
    );
  }

  /// 上下翻页（滚动模式）尾部：也能加新照片。
  Widget _buildScrollImportBar(Color fg) {
    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: Column(
        children: [
          Text('继续补充书页',
              style: TextStyle(
                  color: fg.withValues(alpha: 0.5), fontSize: 11)),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _importFromGallery,
                icon: const Icon(Icons.photo_library_outlined,
                    size: 18, color: AppColors.gold),
                label: const Text('相册批量导入',
                    style: TextStyle(color: AppColors.gold, fontSize: 13)),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: _takePhoto,
                icon: const Icon(Icons.photo_camera_outlined,
                    size: 18, color: AppColors.gold),
                label: const Text('拍照',
                    style: TextStyle(color: AppColors.gold, fontSize: 13)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 空书 / 滚动模式空态：大虚线框 + 加号（略小于页面），点击导入 / 拍摄。
  Widget _buildEmptyImport(Color fg) {
    if (_ocrRunning) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: AppColors.gold),
          const SizedBox(height: 16),
          Text(_ocrStatus,
              style: TextStyle(
                  color: fg.withValues(alpha: 0.7), fontSize: 13)),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: GestureDetector(
        onTap: _showImportMenu,
        child: CustomPaint(
          painter: _DashedBorderPainter(
              color: fg.withValues(alpha: 0.55),
              radius: 20,
              strokeWidth: 1.6),
          child: Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 360),
            alignment: Alignment.center,
            padding:
                const EdgeInsets.symmetric(vertical: 56, horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add_a_photo_outlined,
                    size: 56, color: fg.withValues(alpha: 0.6)),
                const SizedBox(height: 16),
                Text('导入书页照片',
                    style: TextStyle(
                        color: fg.withValues(alpha: 0.75),
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text('拍摄或从相册选择，可加入当前章节或新建一章\n导入后自动识别文字',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: fg.withValues(alpha: 0.5), fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 按照片页下标定位（页面模式跳到该照片的第一个逻辑页）。
  void _jumpToPhoto(int photoIndex) {
    if (!_pageMode) {
      if (_scrollCtrl.hasClients && _totalLen > 0 && _pageStarts.isNotEmpty) {
        final idx = photoIndex.clamp(0, _pageStarts.length - 1);
        final global = _pageStarts[idx];
        final fraction = (global / _totalLen).clamp(0.0, 1.0);
        _scrollCtrl.jumpTo(fraction * _scrollCtrl.position.maxScrollExtent);
      }
      return;
    }
    if (photoIndex <= 0 || _pages.isEmpty || _logicalPages.isEmpty) {
      return;
    }
    final photo = _pages[photoIndex.clamp(0, _pages.length - 1)];
    final lpIdx = _logicalPages.indexWhere((lp) => lp.page?.id == photo.id);
    if (lpIdx >= 0 && _pageCtrl.hasClients) {
      _pageCtrl.jumpToPage(lpIdx);
      setState(() => _currentPageIndex = lpIdx);
    }
  }

  // ===== 左右翻页模式（动态分页） =====

  Widget _buildPageMode(Color fg) {
    return LayoutBuilder(builder: (context, constraints) {
      final availW = constraints.maxWidth - 40;
      final availH = constraints.maxHeight - 48;
      _logicalPages = _layoutPages(
          availW < 1 ? 360 : availW, availH < 1 ? 600 : availH);
      if (_logicalPages.isEmpty) {
        return const SizedBox.shrink();
      }
      return PageView.builder(
        key: ValueKey('reader_pv_$_layoutVersion'),
        controller: _pageCtrl,
        itemCount: _logicalPages.length,
        onPageChanged: (i) {
          if (i != _currentPageIndex) {
            setState(() => _currentPageIndex = i);
          }
        },
        itemBuilder: (context, index) {
          final lp = _logicalPages[index];
          return lp.isImportSlot
              ? _buildImportSlotCard(fg)
              : _buildLogicalPageCard(lp, fg);
        },
      );
    });
  }

  /// 末尾永久“导入书页”卡片：大虚线框，略小于页面。
  Widget _buildImportSlotCard(Color fg) {
    if (_ocrRunning) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: AppColors.gold),
            const SizedBox(height: 16),
            Text(_ocrStatus,
                style: TextStyle(
                    color: fg.withValues(alpha: 0.7), fontSize: 13)),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      child: GestureDetector(
        onTap: _showImportMenu,
        child: CustomPaint(
          painter: _DashedBorderPainter(
              color: fg.withValues(alpha: 0.55),
              radius: 20,
              strokeWidth: 1.6),
          child: Container(
            width: double.infinity,
            alignment: Alignment.center,
            padding:
                const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add_a_photo_outlined,
                    size: 56, color: fg.withValues(alpha: 0.6)),
                const SizedBox(height: 16),
                Text('导入书页照片',
                    style: TextStyle(
                        color: fg.withValues(alpha: 0.75),
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text('拍摄或从相册选择，可加入当前章节或新建一章\n导入后自动识别文字',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: fg.withValues(alpha: 0.5), fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLogicalPageCard(_LogicalPage lp, Color fg) {
    final page = lp.page;
    if (page == null) {
      return _buildImportSlotCard(fg);
    }
    final content = page.content;
    final text = content.substring(lp.startOffset, lp.endOffset);
    final anns = _annsIn(page, lp.startOffset, lp.endOffset);

    // 当前播放段（用于高亮）
    final curSeg = bookAudioHandler.currentSegment.value;
    final curPara = (curSeg >= 0 && curSeg < _paras.length)
        ? _paras[curSeg]
        : null;

    // 逻辑页内段落（页内偏移裁剪）
    final paras = _pageParas(page)
        .where((p) => p.$2 > lp.startOffset && p.$1 < lp.endOffset)
        .map((p) => (
              math.max(p.$1, lp.startOffset),
              math.min(p.$2, lp.endOffset)
            ))
        .toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
      children: [
        if (paras.isEmpty)
          SelectableText.rich(
            TextSpan(style: _baseStyle(fg), children: _spansFor(text, anns, fg)),
            contextMenuBuilder: (ctx, state) =>
                _logicalMenuBuilder(ctx, state, page, lp.startOffset),
          )
        else
          for (final (s, e) in paras)
            _paraWidget(page, lp, s, e, text, anns, fg, curPara),
      ],
    );
  }

  Widget _paraWidget(
      Page page,
      _LogicalPage lp,
      int segS,
      int segE,
      String logicalText,
      List<Annotation> anns,
      Color fg,
      _Para? curPara) {
    final lo = segS - lp.startOffset;
    final hi = segE - lp.startOffset;
    final segText = logicalText.substring(lo, hi);
    final segAnns = anns
        .where((a) => a.endOffset > lo && a.startOffset < hi)
        .map((a) => Annotation(
              id: a.id,
              pageId: a.pageId,
              groupId: a.groupId,
              type: a.type,
              color: a.color,
              startOffset: math.max(a.startOffset, lo) - lo,
              endOffset: math.min(a.endOffset, hi) - lo,
              anchorText: a.anchorText,
              noteText: a.noteText,
              createdAt: a.createdAt,
            ))
        .toList()
      ..sort((a, b) => a.startOffset.compareTo(b.startOffset));

    // 该段是否当前播放段
    final isCurrent = curPara != null &&
        curPara.page.id == page.id &&
        curPara.localEnd > segS &&
        curPara.localStart < segE;

    return GestureDetector(
      onTap: () {
        // 找到该段全局索引并播放
        for (var i = 0; i < _paras.length; i++) {
          final para = _paras[i];
          if (para.page.id == page.id &&
              para.localEnd > segS &&
              para.localStart < segE) {
            unawaited(_playSegment(para.globalIndex));
            return;
          }
        }
      },
      child: Container(
        decoration: isCurrent
            ? BoxDecoration(
                color: const Color(0x2EB08D57),
                borderRadius: BorderRadius.circular(4),
              )
            : null,
        padding: const EdgeInsets.symmetric(vertical: 1, horizontal: 2),
        child: SelectableText.rich(
          TextSpan(style: _baseStyle(fg), children: _spansFor(segText, segAnns, fg)),
          contextMenuBuilder: (ctx, state) =>
              _logicalMenuBuilder(ctx, state, page, lp.startOffset + lo),
        ),
      ),
    );
  }

  Widget _logicalMenuBuilder(BuildContext context, EditableTextState state,
      Page page, int baseOffset) {
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: [
        ContextMenuButtonItem(
          label: '横线',
          onPressed: () => _handleLogicalSelection(state, page, baseOffset, 'underline'),
        ),
        ContextMenuButtonItem(
          label: '红色高亮',
          onPressed: () => _handleLogicalSelection(state, page, baseOffset, 'highlight'),
        ),
        ContextMenuButtonItem(
          label: '写批注',
          onPressed: () => _handleLogicalSelection(state, page, baseOffset, 'note'),
        ),
        ContextMenuButtonItem(
          label: '复制',
          onPressed: () => _handleLogicalSelection(state, page, baseOffset, 'copy'),
        ),
      ],
    );
  }

  void _handleLogicalSelection(EditableTextState state, Page page,
      int baseOffset, String action) {
    final sel = state.textEditingValue.selection;
    state.hideToolbar();
    if (!sel.isValid || sel.isCollapsed) {
      _snack('先选中一段文字，再操作');
      return;
    }
    final s = (sel.start + baseOffset)
        .clamp(0, page.content.length)
        .toInt();
    final e =
        (sel.end + baseOffset).clamp(0, page.content.length).toInt();
    if (action == 'copy') {
      Clipboard.setData(
          ClipboardData(text: page.content.substring(s, e)));
      return;
    }
    unawaited(_annotateForPage(page, s, e, action));
  }

  /// 弹批注文字输入框，返回内容（取消返回 null）。
  Future<String?> _askNoteText() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('写批注 / 读后感',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 4,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: InputDecoration(
            hintText: '写在选中文字旁边的话…',
            hintStyle: const TextStyle(color: AppColors.textSecondary),
            filled: true,
            fillColor: AppColors.surfaceHigh,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppColors.outline),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存', style: TextStyle(color: AppColors.gold)),
          ),
        ],
      ),
    );
    if (ok != true) {
      return null;
    }
    final text = ctrl.text.trim();
    return text.isEmpty ? null : text;
  }

  /// 单页批注（翻页模式用）。
  Future<void> _annotateForPage(Page page, int s, int e, String action) async {
    if (s >= e) {
      _snack('选中的文字太短，换个位置再试');
      return;
    }
    final anchor = page.content.substring(s, e).trim();
    if (anchor.isEmpty) {
      _snack('选中的文字太短，换个位置再试');
      return;
    }
    var noteText = '';
    if (action == 'note') {
      noteText = await _askNoteText() ?? '';
      if (noteText.isEmpty) {
        return;
      }
    }
    await widget.repository.addAnnotationGroup(
      segments: [(page.id, s, e)],
      anchors: [anchor],
      type: action == 'underline'
          ? 'underline'
          : action == 'highlight'
              ? 'highlight'
              : 'note',
      noteText: noteText,
    );
    _snack(action == 'note'
        ? '批注已写好'
        : action == 'highlight'
            ? '已加红色高亮'
            : '已加横线');
  }

  // ===== 底部迷你播放条 =====

  Widget _buildMiniPlayer(Color fg) {
    final h = bookAudioHandler;
    final isThisBook = h.currentBookId == '${book.id}';
    if (!isThisBook && h.segmentCount == 0) {
      return const SizedBox.shrink();
    }
    return StreamBuilder<PrepStatus>(
      stream: h.prepSubject,
      initialData: h.prepSubject.value,
      builder: (context, prepSnap) {
        final prep = prepSnap.data;
        return Container(
          color: AppColors.surfaceHigh,
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: SafeArea(
            top: false,
            child: StreamBuilder<PlaybackState>(
              stream: h.playbackState,
              builder: (context, stSnap) {
                final st = stSnap.data;
                final playing = st?.playing ?? false;
                return StreamBuilder<int>(
                  stream: h.currentSegment,
                  initialData: h.currentSegment.value,
                  builder: (context, segSnap) {
                    final segIdx = segSnap.data ?? -1;
                    final qlen = h.queue.value.length;
                    final idx = st?.queueIndex ?? 0;
                    final hasPrev = idx > 0;
                    final hasNext = idx < qlen - 1;
                    return Row(
                      children: [
                        IconButton(
                          tooltip: playing ? '暂停' : '播放',
                          onPressed: () =>
                              playing ? h.pause() : h.play(),
                          icon: Icon(
                              playing
                                  ? Icons.pause_circle_filled
                                  : Icons.play_circle_filled,
                              color: AppColors.gold,
                              size: 34),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      segIdx >= 0
                                          ? '第 ${segIdx + 1} 段 · 共 ${h.segmentCount} 段'
                                          : (prep?.message ?? '准备中…'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: AppColors.textPrimary,
                                          fontSize: 12),
                                    ),
                                  ),
                                  if (h.currentVoice != null)
                                    Padding(
                                      padding:
                                          const EdgeInsets.only(left: 6),
                                      child: Text(
                                        '· ${h.currentVoice!.displayName.split(' ').first}',
                                        maxLines: 1,
                                        style: const TextStyle(
                                            color: AppColors.textSecondary,
                                            fontSize: 10),
                                      ),
                                    ),
                                ],
                              ),
                              // 准备进度（电子书界面也能看到“正在准备第 x 段”）
                              if (prep != null && prep.prepping)
                                Padding(
                                  padding:
                                      const EdgeInsets.only(top: 1, bottom: 1),
                                  child: Row(
                                    children: [
                                      const SizedBox(
                                        width: 10,
                                        height: 10,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 1.4,
                                            color: AppColors.gold),
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(prep.message,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                                color: AppColors.textSecondary,
                                                fontSize: 10)),
                                      ),
                                    ],
                                  ),
                                ),
                              StreamBuilder<Duration>(
                                stream: h.positionStream,
                                builder: (context, posSnap) {
                                  return StreamBuilder<Duration?>(
                                    stream: h.durationStream,
                                    builder: (context, durSnap) {
                                      final position =
                                          posSnap.data ?? Duration.zero;
                                      final duration =
                                          durSnap.data ?? Duration.zero;
                                      return Slider(
                                        value: duration.inMilliseconds == 0
                                            ? 0
                                            : position.inMilliseconds
                                                .clamp(0, duration
                                                    .inMilliseconds)
                                                .toDouble(),
                                        max: duration.inMilliseconds == 0
                                            ? 1
                                            : duration.inMilliseconds
                                                .toDouble(),
                                        activeColor: AppColors.gold,
                                        onChanged: duration.inMilliseconds == 0
                                            ? null
                                            : (v) => h.seek(Duration(
                                                milliseconds: v.toInt())),
                                      );
                                    },
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: '上一段',
                          onPressed: hasPrev ? h.skipToPrevious : null,
                          icon: Icon(Icons.skip_previous_outlined,
                              color: AppColors.textSecondary, size: 26),
                        ),
                        IconButton(
                          tooltip: '下一段',
                          onPressed: hasNext ? h.skipToNext : null,
                          icon: Icon(Icons.skip_next_outlined,
                              color: AppColors.textSecondary, size: 26),
                        ),
                        _buildVoiceSwitcher(),
                        PopupMenuButton<double>(
                          onSelected: (v) async {
                            await h.changeSpeed(v);
                            if (mounted) {
                              setState(() {});
                            }
                          },
                          itemBuilder: (_) => [
                            for (final s in const [
                              0.75, 1.0, 1.25, 1.5, 1.75, 2.0,
                            ])
                              PopupMenuItem(
                                value: s,
                                child: Text('$s x',
                                    style: TextStyle(
                                        color: h.speed == s
                                            ? AppColors.gold
                                            : AppColors.textPrimary)),
                              ),
                          ],
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Text('${h.speed} x',
                                style: TextStyle(
                                    color: AppColors.gold, fontSize: 12)),
                          ),
                        ),
                        IconButton(
                          tooltip: '全屏听书',
                          onPressed: () {
                            Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => ListenPage(
                                repository: widget.repository,
                                book: book,
                              ),
                            ));
                          },
                          icon: Icon(Icons.open_in_full,
                              color: AppColors.textSecondary, size: 20),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        );
      },
    );
  }

  /// 迷你条上的音色切换入口（只列已安装音色）。
  Widget _buildVoiceSwitcher() {
    final installed =
        kSherpaVoices.where((v) => _voiceInstalled[v.id] ?? false).toList();
    final currentId = bookAudioHandler.currentVoice?.id;
    return PopupMenuButton<String>(
      tooltip: '切换音色',
      icon: Icon(Icons.record_voice_over_outlined,
          color: AppColors.textSecondary, size: 20),
      onSelected: (id) {
        if (id != currentId) {
          _switchVoice(id);
        }
      },
      itemBuilder: (_) => [
        for (final v in installed)
          PopupMenuItem(
            value: v.id,
            child: Row(
              children: [
                Icon(
                  v.id == currentId
                      ? Icons.check_circle
                      : Icons.circle_outlined,
                  size: 16,
                  color: v.id == currentId
                      ? AppColors.gold
                      : AppColors.textSecondary,
                ),
                const SizedBox(width: 8),
                Text(v.displayName,
                    style: TextStyle(
                        color: v.id == currentId
                            ? AppColors.gold
                            : AppColors.textPrimary,
                        fontSize: 13)),
              ],
            ),
          ),
        if (installed.isEmpty)
          const PopupMenuItem(
            enabled: false,
            child: Text('暂无已下载音色',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
      ],
    );
  }
}

/// 虚线圆角边框画笔（空书导入框 / 关联页复用）。
class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({
    required this.color,
    this.radius = 12,
    this.strokeWidth = 1.2,
  });

  final Color color;
  final double radius;
  final double strokeWidth;
  static const double dash = 6;
  static const double gap = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(strokeWidth / 2, strokeWidth / 2,
            size.width - strokeWidth, size.height - strokeWidth),
        Radius.circular(radius));
    final path = Path()
      ..addRRect(rrect)
      ..close();
    for (final m in path.computeMetrics()) {
      var dist = 0.0;
      while (dist < m.length) {
        final end = math.min(dist + dash, m.length);
        canvas.drawPath(m.extractPath(dist, end), paint);
        dist = end + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.radius != radius ||
      oldDelegate.strokeWidth != strokeWidth;
}

import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:rxdart/rxdart.dart';

import '../data/app_database.dart';
import '../data/book_repository.dart';
import 'sherpa_tts.dart';

/// 一段可朗读的文字（一页中的一段）。
class AudioSegment {
  const AudioSegment({
    required this.pageId,
    required this.pageOrder,
    required this.paraIndex,
    required this.text,
  });

  final int pageId;
  final int pageOrder;
  final int paraIndex;
  final String text;
}

/// 听书准备状态（供页面显示进度）。
class PrepStatus {
  const PrepStatus({
    required this.done,
    required this.total,
    required this.prepping,
    required this.message,
  });

  final int done;
  final int total;
  final bool prepping;
  final String message;
}

/// 打开一本书的结果。
class OpenBookResult {
  const OpenBookResult({
    required this.ok,
    required this.empty,
    required this.modelMissing,
    required this.voiceName,
    this.segmentCount = 0,
  });

  final bool ok;
  final bool empty;
  final bool modelMissing;
  final String voiceName;
  final int segmentCount;
}

/// 把可读页面展开成「段」列表（页内按空行分段）。
List<AudioSegment> buildSegments(List<Page> pages) {
  final result = <AudioSegment>[];
  for (final page in pages) {
    final content = page.content;
    if (content.trim().isEmpty) {
      continue;
    }
    final paras = content.split('\n\n');
    var paraIndex = 0;
    for (final raw in paras) {
      final text = raw.replaceAll('\n', '').trim();
      if (text.isNotEmpty) {
        result.add(AudioSegment(
          pageId: page.id,
          pageOrder: page.orderIndex,
          paraIndex: paraIndex,
          text: text,
        ));
      }
      paraIndex++;
    }
  }
  return result;
}

/// 全局听书音频处理器：
/// - 常驻合成线程：语音模型只加载一次，逐段合成缓存、无缝连播；
/// - 渲染通知栏 / 锁屏控制；退出页面后继续后台播放；
/// - 记忆每本书的收听位置（段 + 段内秒数），可指定从任意段开始；
/// - 听书过程中可切换音色（缓存按音色隔离）。
class BookAudioHandler extends BaseAudioHandler with SeekHandler {
  BookAudioHandler() {
    _player.playbackEventStream.listen(_onEvent);
    _player.currentIndexStream.listen((idx) {
      if (idx == null) {
        return;
      }
      final q = queue.value;
      if (idx >= 0 && idx < q.length) {
        mediaItem.add(q[idx]);
      }
      currentSegment.add(idx);
      scheduleSave();
    });
  }

  final AudioPlayer _player = AudioPlayer();
  // 动态逐段加入、无缝连播仍需拼接播放源（新版仅提示弃用，功能正常）。
  // ignore: deprecated_member_use
  final ConcatenatingAudioSource _playlist =
      // ignore: deprecated_member_use
      ConcatenatingAudioSource(children: <AudioSource>[]);

  final BookRepository _repo = BookRepository(AppDatabase.instance);
  final BehaviorSubject<PrepStatus> prepSubject =
      BehaviorSubject<PrepStatus>.seeded(const PrepStatus(
          done: 0, total: 0, prepping: false, message: '准备中…'));

  /// 当前播放段（全局段索引），供阅读页高亮。
  final BehaviorSubject<int> currentSegment =
      BehaviorSubject<int>.seeded(-1);

  Book? _book;
  SherpaVoice? _voice;
  Directory? _cacheDir;
  List<AudioSegment> _segments = <AudioSegment>[];
  String _modelBase = '';

  /// 常驻合成线程（模型只加载一次）。
  final TtsWorker _worker = TtsWorker();
  String? _workerVoiceId;
  String? _workerBase;

  bool _sourceSet = false;
  bool _prepping = false;
  int _prepGeneration = 0;
  int _resumeIndex = -1;
  Duration _resumePos = Duration.zero;
  bool _resumeApplied = false;
  Timer? _saveTimer;

  String? get currentBookId => _book == null ? null : '${_book!.id}';
  SherpaVoice? get currentVoice => _voice;

  /// 当前书的段列表（阅读页同步段落索引用）。
  List<AudioSegment> get segments => _segments;
  int get segmentCount => _segments.length;

  // 供页面订阅的播放信息
  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<SequenceState?> get sequenceStream => _player.sequenceStateStream;
  double get speed => _player.speed;
  Future<void> changeSpeed(double v) => _player.setSpeed(v);

  /// 打开（或继续）一本书。
  Future<OpenBookResult> openBook(Book book) async {
    // 同一本书且已经在准备 / 播放 → 直接复用，不重启。
    if (currentBookId == '${book.id}' &&
        (_prepping || _playlist.length > 0)) {
      return OpenBookResult(
          ok: true,
          empty: false,
          modelMissing: false,
          voiceName: _voice?.displayName ?? '',
          segmentCount: _segments.length);
    }
    final vid = await _repo.getSetting(kSherpaVoiceSetting) ?? 'melo';
    return _openInternal(book, forcedVoiceId: vid, resumeSegment: -1);
  }

  /// 听书过程中切换音色：从当前段继续，用新音色重新合成并播放。
  Future<OpenBookResult> switchVoice(String voiceId) async {
    final b = _book;
    if (b == null) {
      return const OpenBookResult(
          ok: false, empty: true, modelMissing: false, voiceName: '');
    }
    final keep = currentSegment.value;
    return _openInternal(b,
        forcedVoiceId: voiceId, resumeSegment: keep, autoplay: true);
  }

  Future<OpenBookResult> _openInternal(Book book,
      {required String forcedVoiceId,
      required int resumeSegment,
      bool autoplay = false}) async {
    await _reset();
    _book = book;

    final pages = await _repo.watchPages(book.id).first;
    final readable =
        pages.where((pg) => pg.content.trim().isNotEmpty).toList();
    final segments = buildSegments(readable);
    if (segments.isEmpty) {
      prepSubject.add(const PrepStatus(
          done: 0, total: 0, prepping: false, message: '还没有可听的文字'));
      return const OpenBookResult(
          ok: false, empty: true, modelMissing: false, voiceName: '');
    }

    final voice = sherpaVoiceById(forcedVoiceId);
    final installed = await TtsModelManager.instance.isInstalled(voice);
    if (!installed) {
      prepSubject.add(PrepStatus(
          done: 0,
          total: segments.length,
          prepping: false,
          message: '离线语音未下载'));
      return OpenBookResult(
          ok: false,
          empty: false,
          modelMissing: true,
          voiceName: voice.displayName,
          segmentCount: segments.length);
    }

    final support = await getApplicationSupportDirectory();
    // 缓存按音色隔离：切换音色不会读到旧音色的音频。
    final cacheDir = Directory(p.join(
        support.path, 'tts_cache', 'book_${book.id}', voice.id));
    if (!cacheDir.existsSync()) {
      cacheDir.createSync(recursive: true);
    }

    _segments = segments;
    _cacheDir = cacheDir;
    _voice = voice;
    _modelBase = (await TtsModelManager.instance.dirFor(voice)).path;
    _autoplayAfterPrep = autoplay;

    if (!_sourceSet) {
      await _player.setAudioSource(_playlist);
      _sourceSet = true;
    }

    // 收听进度记忆（段 + 段内秒）
    if (resumeSegment >= 0) {
      _resumeIndex = resumeSegment;
      _resumePos = Duration.zero;
    } else {
      final si = await _repo.getSetting('listen.${book.id}.index');
      final sp = await _repo.getSetting('listen.${book.id}.pos');
      _resumeIndex = int.tryParse(si ?? '') ?? -1;
      _resumePos =
          Duration(milliseconds: int.tryParse(sp ?? '') ?? 0);
    }
    _resumeApplied = false;

    prepSubject.add(PrepStatus(
        done: 0,
        total: segments.length,
        prepping: true,
        message: '正在加载语音引擎…'));
    unawaited(_prep());
    return OpenBookResult(
        ok: true,
        empty: false,
        modelMissing: false,
        voiceName: voice.displayName,
        segmentCount: segments.length);
  }

  bool _autoplayAfterPrep = false;

  /// 从指定段开始播放（先保证该段已就绪）。
  Future<void> playFromSegment(int index) async {
    if (_book == null || index < 0 || index >= _segments.length) {
      return;
    }
    await _ensureSegmentPrepared(index);
    if (index < _playlist.length) {
      await _player.seek(Duration.zero, index: index);
    }
    await _player.play();
  }

  Future<void> _reset() async {
    _prepGeneration++; // 让正在进行的旧准备循环作废
    try {
      await _player.pause();
    } catch (_) {}
    try {
      // ignore: deprecated_member_use
      await _playlist.clear();
    } catch (_) {}
    queue.add(const <MediaItem>[]);
    mediaItem.add(null);
    currentSegment.add(-1);
    _voice = null;
    _book = null;
    _segments = <AudioSegment>[];
    _prepping = false;
    _autoplayAfterPrep = false;
  }

  /// 确保常驻合成线程已按当前音色启动（音色/路径变化时自动重建）。
  Future<void> _ensureWorker() async {
    final voice = _voice;
    if (voice == null) {
      throw StateError('尚未选择语音');
    }
    if (_worker.isReady &&
        _workerVoiceId == voice.id &&
        _workerBase == _modelBase) {
      return;
    }
    await _worker.dispose();
    _workerVoiceId = null;
    _workerBase = null;
    await _worker.start(voice.id, _modelBase);
    _workerVoiceId = voice.id;
    _workerBase = _modelBase;
  }

  /// 确保某段已合成入队（若还在后台准备中，则等待该段完成）。
  Future<void> _ensureSegmentPrepared(int index) async {
    // 若正在后台准备且该段尚未入队，则等待（上限 120s）。
    var waited = 0;
    while (_prepping && _playlist.length <= index && waited < 120000) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      waited += 120;
    }
    // 队列已就绪，但该段可能因合成失败缺失 → 尝试立即补合成一次。
    if (index >= _playlist.length) {
      final seg = index < _segments.length ? _segments[index] : null;
      if (seg != null) {
        try {
          await _ensureWorker();
          final wav = await _worker.synthesize(seg.text);
          final cache = _cacheFor(seg);
          await cache.writeAsBytes(wav);
          // ignore: deprecated_member_use
          await _playlist.add(AudioSource.file(cache.path));
          queue.add(<MediaItem>[
            ...queue.value,
            _mediaItemFor(index),
          ]);
        } catch (_) {
          // 补合成失败，交给上层提示
        }
      }
    }
  }

  File _cacheFor(AudioSegment seg) => File(p.join(
      _cacheDir!.path, 'p_${seg.pageId}_${seg.paraIndex}.wav'));

  MediaItem _mediaItemFor(int index) {
    return MediaItem(
      id: '${_book!.id}_s$index',
      album: _book!.title,
      title: '第 ${index + 1} 段',
      artist: _voice!.displayName,
    );
  }

  /// 加载引擎并逐段合成缓存、加入队列（全程后台，不阻塞 UI）。
  Future<void> _prep() async {
    final gen = _prepGeneration;
    _prepping = true;
    var failed = 0;
    try {
      prepSubject.add(PrepStatus(
          done: 0,
          total: _segments.length,
          prepping: true,
          message: '正在加载语音引擎…'));
      await _ensureWorker();
    } catch (e) {
      if (gen == _prepGeneration) {
        _prepping = false;
        prepSubject.add(PrepStatus(
            done: 0,
            total: _segments.length,
            prepping: false,
            message: '语音引擎加载失败：$e'));
      }
      return;
    }
    for (var i = 0; i < _segments.length; i++) {
      if (gen != _prepGeneration) {
        return; // 已切换音色 / 重新打开，旧循环作废
      }
      final seg = _segments[i];
      final cache = _cacheFor(seg);
      if (!cache.existsSync()) {
        try {
          prepSubject.add(PrepStatus(
              done: i,
              total: _segments.length,
              prepping: true,
              message: '正在准备第 ${i + 1} 段…'));
          final wav = await _worker.synthesize(seg.text);
          if (gen != _prepGeneration) {
            return;
          }
          await cache.writeAsBytes(wav);
        } catch (_) {
          failed++;
          continue;
        }
      }
      // ignore: deprecated_member_use
      await _playlist.add(AudioSource.file(cache.path));
      if (gen != _prepGeneration) {
        return;
      }
      queue.add(<MediaItem>[...queue.value, _mediaItemFor(i)]);

      // 恢复到上次收听位置 / 切换音色后从当前段继续（仅一次）
      if (!_resumeApplied &&
          _resumeIndex >= 0 &&
          _playlist.length > _resumeIndex) {
        await _player.seek(_resumePos, index: _resumeIndex);
        _resumeApplied = true;
        if (_autoplayAfterPrep) {
          await _player.play();
        }
      }
      if (gen != _prepGeneration) {
        return;
      }

      prepSubject.add(PrepStatus(
          done: i + 1,
          total: _segments.length,
          prepping: true,
          message: failed > 0
              ? '正在准备第 ${i + 2} 段…（$failed 段失败）'
              : (i + 1 < _segments.length
                  ? '正在准备第 ${i + 2} 段…'
                  : '全部就绪，可连续收听')));
    }
    if (gen != _prepGeneration) {
      return;
    }
    _prepping = false;
    prepSubject.add(PrepStatus(
        done: _segments.length,
        total: _segments.length,
        prepping: false,
        message: failed > 0
            ? '已就绪（$failed 段合成失败，可重下模型后重试）'
            : '全部就绪，可连续收听'));
  }

  void _onEvent(PlaybackEvent event) {
    playbackState.add(PlaybackState(
      controls: <MediaControl>[
        MediaControl.skipToPrevious,
        if (_player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const <MediaAction>{
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
        MediaAction.setSpeed,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const <ProcessingState, AudioProcessingState>{
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: event.currentIndex,
    ));
  }

  // ---- 媒体动作（UI / 通知 / 锁屏 / 耳机统一入口）----
  @override
  Future<void> play() async {
    await _player.play();
  }

  @override
  Future<void> pause() async {
    scheduleSave();
    await _player.pause();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() async {
    if (_player.hasNext) {
      await _player.seekToNext();
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (_player.hasPrevious) {
      await _player.seekToPrevious();
    }
  }

  @override
  Future<void> stop() async {
    scheduleSave();
    await _player.stop();
    await super.stop();
  }

  /// 划掉最近任务时：没在播放就结束，正在播放则继续后台听。
  @override
  Future<void> onTaskRemoved() async {
    if (!_player.playing) {
      await _player.stop();
    }
  }

  /// 节流保存收听进度。
  void scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), _doSave);
  }

  Future<void> _doSave() async {
    final b = _book;
    if (b == null) {
      return;
    }
    final idx = _player.currentIndex ?? 0;
    await _repo.setSetting('listen.${b.id}.index', '$idx');
    await _repo.setSetting(
        'listen.${b.id}.pos', '${_player.position.inMilliseconds}');
  }
}

/// 全局音频处理器（main 中初始化）。
late BookAudioHandler bookAudioHandler;

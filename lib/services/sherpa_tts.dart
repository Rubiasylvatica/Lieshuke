import 'dart:isolate';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'tts_service.dart';

/// 离线神经语音（sherpa-onnx）。
///
/// - 完全离线、免费、无需 API Key；在手机本地 CPU 合成。
/// - 模型首次使用时下载一次，之后永久离线；
/// - 合成时按中文标点切句、句间加停顿，避免“一字一顿”。
/// - 听书时使用常驻合成线程（[TtsWorker]），模型只加载一次，段间不卡顿。

/// 设置键：当前选用的离线音色 id（默认 melo）。
const String kSherpaVoiceSetting = 'tts.sherpa.voice';

/// 一个可下载的离线音色描述。
class SherpaVoice {
  const SherpaVoice({
    required this.id,
    required this.displayName,
    required this.gender,
    required this.downloadBytes,
    required this.url,
    required this.folder,
    required this.modelRel,
    required this.tokensRel,
    this.lexiconRel = '',
    this.multiLexiconRels = const <String>[],
    this.voicesRel = '',
    this.dataDirRel = '',
    this.dictDirRel = '',
    this.ruleFstsRel = const <String>[],
    this.kind = 'vits',
    this.sid = 0,
  });

  final String id;
  final String displayName;
  final String gender; // 女 / 男
  final int downloadBytes; // 压缩包字节数（用于显示与进度兜底）
  final String url; // tar.bz2 下载地址
  final String folder; // 解压后的顶层目录名

  // 相对 folder 的文件路径
  final String modelRel;
  final String tokensRel;
  final String lexiconRel; // 单个 lexicon，无则 ''
  final List<String> multiLexiconRels; // 多个 lexicon（如 Kokoro 中英双词典）
  final String voicesRel; // Kokoro 的 voices.bin，无则 ''
  final String dataDirRel; // espeak-ng-data，无则 ''
  final String dictDirRel; // 中文分词 dict 目录，无则 ''
  final List<String> ruleFstsRel; // 规则 fst，无则空
  final String kind; // 'vits' 或 'kokoro'
  final int sid; // 说话人 id（Kokoro 多说话人）

  /// 该音色的全部 lexicon 相对路径。
  List<String> get lexiconRels => multiLexiconRels.isNotEmpty
      ? multiLexiconRels
      : (lexiconRel.isEmpty ? const <String>[] : <String>[lexiconRel]);

  int get downloadMb => (downloadBytes / 1024 / 1024).ceil();
}

/// 可选离线音色目录。
///
/// - 若晚（MeloTTS）：44.1kHz 高保真、语调柔和自然（体积较大）。
/// - 小晓（Kokoro int8）：24kHz，四个中文女声中最响亮有力、偏硬朗。
/// （华言 / 超文已按用户要求下线；残留模型目录会在 App 启动时自动清理。）
const List<SherpaVoice> kSherpaVoices = <SherpaVoice>[
  SherpaVoice(
    id: 'melo',
    displayName: '若晚 · 柔和高保真',
    gender: '女',
    downloadBytes: 167006754,
    url:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-melo-tts-zh_en.tar.bz2',
    folder: 'vits-melo-tts-zh_en',
    modelRel: 'model.onnx',
    tokensRel: 'tokens.txt',
    lexiconRel: 'lexicon.txt',
    dictDirRel: 'dict',
    ruleFstsRel: <String>['date.fst', 'number.fst'],
  ),
  SherpaVoice(
    id: 'xiaoxiao',
    displayName: '小晓 · 明亮女声',
    gender: '女',
    downloadBytes: 132303094,
    url:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-multi-lang-v1_0.tar.bz2',
    folder: 'kokoro-int8-multi-lang-v1_0',
    modelRel: 'model.int8.onnx',
    tokensRel: 'tokens.txt',
    voicesRel: 'voices.bin',
    dataDirRel: 'espeak-ng-data',
    dictDirRel: 'dict',
    multiLexiconRels: <String>['lexicon-us-en.txt', 'lexicon-zh.txt'],
    ruleFstsRel: <String>['date-zh.fst', 'phone-zh.fst', 'number-zh.fst'],
    kind: 'kokoro',
    sid: 47, // zf_xiaoxiao，四个中文女声中最响亮有力
  ),
];

/// 按 id 查找音色（找不到返回第一个：若晚）。
SherpaVoice sherpaVoiceById(String id) {
  for (final v in kSherpaVoices) {
    if (v.id == id) {
      return v;
    }
  }
  return kSherpaVoices.first;
}

/// 根据音色与模型根目录构建 sherpa-onnx 引擎（可在主/后台 isolate 调用）。
sherpa.OfflineTts buildOfflineTts(SherpaVoice voice, String modelBase,
    {int numThreads = 2}) {
  String abs(String rel) =>
      rel.isEmpty ? '' : path.join(modelBase, rel);

  final sherpa.OfflineTtsModelConfig modelConfig;
  if (voice.kind == 'kokoro') {
    final kokoro = sherpa.OfflineTtsKokoroModelConfig(
      model: abs(voice.modelRel),
      voices: abs(voice.voicesRel),
      tokens: abs(voice.tokensRel),
      dataDir: abs(voice.dataDirRel),
      dictDir: abs(voice.dictDirRel),
      lexicon: voice.lexiconRels.map(abs).join(','),
    );
    modelConfig = sherpa.OfflineTtsModelConfig(
      kokoro: kokoro,
      numThreads: numThreads,
      debug: false,
    );
  } else {
    final vits = sherpa.OfflineTtsVitsModelConfig(
      model: abs(voice.modelRel),
      tokens: abs(voice.tokensRel),
      lexicon: abs(voice.lexiconRel),
      dataDir: abs(voice.dataDirRel),
      dictDir: abs(voice.dictDirRel),
    );
    modelConfig = sherpa.OfflineTtsModelConfig(
      vits: vits,
      numThreads: numThreads,
      debug: false,
    );
  }
  final ruleFsts = voice.ruleFstsRel.map(abs).join(',');
  final config = sherpa.OfflineTtsConfig(
    model: modelConfig,
    ruleFsts: ruleFsts,
  );
  return sherpa.OfflineTts(config);
}

/// 把一段文本切成适合逐句合成的短句：
/// - 去掉全角缩进空格与多余空白；
/// - 按中文/英文标点切分（保留标点）；
/// - 超长句（>40 字）硬切，避免单次合成过长导致卡顿。
List<String> splitSentences(String input) {
  var text = input
      .replaceAll(RegExp(r'[\u3000\u2000-\u200B\u00A0]+'), ' ')
      .trim();
  if (text.isEmpty) {
    return const <String>[];
  }
  final re = RegExp(r'[^。！？；!?;…]+[。！？；!?;…]?');
  final parts = <String>[];
  for (final m in re.allMatches(text)) {
    var s = m.group(0)!.trim();
    if (s.isEmpty) {
      continue;
    }
    while (s.length > 40) {
      parts.add(s.substring(0, 40));
      s = s.substring(40);
    }
    if (s.isNotEmpty) {
      parts.add(s);
    }
  }
  return parts;
}

/// 用已初始化的 [tts] 逐句合成 [text] 并拼接（句间 0.18s 停顿），返回 WAV 字节。
Uint8List generateWithSplitting(sherpa.OfflineTts tts, String text,
    {int sid = 0}) {
  final parts = splitSentences(text);
  final chunks = <Float32List>[];
  var rate = 22050;
  for (final part in parts) {
    if (part.isEmpty) {
      continue;
    }
    final audio = tts.generate(text: part, sid: sid, speed: 1.0);
    rate = audio.sampleRate;
    chunks.add(audio.samples);
    chunks.add(Float32List((rate * 0.18).round())); // 句间停顿
  }
  if (chunks.isEmpty) {
    return encodeWav(Float32List(0), rate);
  }
  var total = 0;
  for (final c in chunks) {
    total += c.length;
  }
  final all = Float32List(total);
  var off = 0;
  for (final c in chunks) {
    all.setAll(off, c);
    off += c.length;
  }
  // 峰值归一化：偏弱的音色（如 MeloTTS）整体放大到目标响度，
  // 最多放大 3 倍避免底噪被过度放大，且绝不削顶。
  var peak = 0.0;
  for (final s in all) {
    final a = s.abs();
    if (a > peak) {
      peak = a;
    }
  }
  if (peak > 0 && peak < 0.95) {
    final gain = (0.95 / peak).clamp(1.0, 3.0);
    for (var i = 0; i < all.length; i++) {
      all[i] = (all[i] * gain).clamp(-1.0, 1.0);
    }
  }
  return encodeWav(all, rate);
}

/// 在一次性后台 isolate 中合成 [text]（用于试听），返回 WAV 字节。
/// 首次调用需加载模型，耗时数秒，但不阻塞界面。
Future<Uint8List> synthesizeSpeechOnIsolate(
    String voiceId, String text, String modelBase) {
  return Isolate.run(() {
    sherpa.initBindings();
    final voice = sherpaVoiceById(voiceId);
    final tts = buildOfflineTts(voice, modelBase);
    try {
      return generateWithSplitting(tts, text, sid: voice.sid);
    } finally {
      tts.free();
    }
  });
}

// ===================== 常驻合成线程（听书） =====================

class _WorkerInit {
  _WorkerInit(this.voiceId, this.modelBase, this.replyTo);
  final String voiceId;
  final String modelBase;
  final SendPort replyTo;
}

/// 常驻后台 isolate：模型只加载一次，之后逐段合成，避免每段重载模型造成卡顿。
class TtsWorker {
  Isolate? _isolate;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;
  String? voiceId;

  bool get isReady => _toWorker != null;

  /// 启动并加载模型（可能耗时数秒）。[voiceId]/[modelBase] 变化时会自动重建。
  Future<void> start(String voiceId, String modelBase) async {
    await dispose();
    this.voiceId = voiceId;
    final fromWorker = ReceivePort();
    _fromWorker = fromWorker;
    final isolate = await Isolate.spawn(
      _workerEntry,
      _WorkerInit(voiceId, modelBase, fromWorker.sendPort),
      errorsAreFatal: false,
    );
    _isolate = isolate;
    // worker 加载完模型后回发 [SendPort, error?]
    final hello = await fromWorker.first as List;
    final err = hello.length > 1 ? hello[1] as String? : null;
    if (err != null) {
      await dispose();
      throw Exception(err);
    }
    _toWorker = hello[0] as SendPort;
  }

  /// 合成一段（内部已切句拼接），返回整段 WAV。
  Future<Uint8List> synthesize(String text) async {
    final toWorker = _toWorker;
    if (toWorker == null) {
      throw StateError('语音合成线程尚未就绪');
    }
    final rp = ReceivePort();
    toWorker.send(<String, Object>{'text': text, 'reply': rp.sendPort});
    final res = (await rp.first) as Map;
    rp.close();
    if (res['ok'] == true) {
      return res['wav'] as Uint8List;
    }
    throw Exception(res['err'] ?? '语音合成失败');
  }

  Future<void> dispose() async {
    _toWorker = null;
    _fromWorker?.close();
    _fromWorker = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }
}

/// worker 入口：加载一次模型，然后循环处理合成请求。
void _workerEntry(_WorkerInit init) {
  final rp = ReceivePort();
  sherpa.OfflineTts? tts;
  String? initErr;
  try {
    sherpa.initBindings();
    final voice = sherpaVoiceById(init.voiceId);
    tts = buildOfflineTts(voice, init.modelBase);
  } catch (e) {
    initErr = '$e';
  }
  // 无论成败都先回发握手消息
  init.replyTo.send(<Object?>[rp.sendPort, initErr]);
  if (initErr != null) {
    return;
  }
  final engine = tts!;
  final voice = sherpaVoiceById(init.voiceId);
  rp.listen((message) {
    final req = message as Map;
    final reply = req['reply'] as SendPort;
    try {
      final wav = generateWithSplitting(engine, req['text'] as String,
          sid: voice.sid);
      reply.send(<String, Object>{'ok': true, 'wav': wav});
    } catch (e) {
      reply.send(<String, Object>{'ok': false, 'err': '$e'});
    }
  });
}

/// 离线语音模型管理器：负责模型存放、下载、流式解压、校验与删除。
class TtsModelManager {
  TtsModelManager._();
  static final TtsModelManager instance = TtsModelManager._();

  Directory? _base;

  /// 所有模型的根目录：<应用支持目录>/tts_models。
  Future<Directory> baseDir() async {
    final existing = _base;
    if (existing != null) {
      return existing;
    }
    final support = await getApplicationSupportDirectory();
    final dir = Directory(path.join(support.path, 'tts_models'));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    _base = dir;
    return dir;
  }

  /// 某音色解压后所在目录。
  Future<Directory> dirFor(SherpaVoice v) async {
    final base = await baseDir();
    return Directory(path.join(base.path, v.folder));
  }

  /// 某音色要求的文件是否齐全。
  Future<bool> isInstalled(SherpaVoice v) async {
    final dir = (await dirFor(v)).path;
    // 路径可能是文件，也可能是目录（如 espeak-ng-data / dict），任一存在即可。
    bool exists(String rel) {
      if (rel.isEmpty) {
        return true;
      }
      final pth = path.join(dir, rel);
      return File(pth).existsSync() || Directory(pth).existsSync();
    }

    if (!exists(v.modelRel) || !exists(v.tokensRel)) {
      return false;
    }
    if (!exists(v.voicesRel)) {
      return false;
    }
    for (final lex in v.lexiconRels) {
      if (!exists(lex)) {
        return false;
      }
    }
    if (!exists(v.dataDirRel) || !exists(v.dictDirRel)) {
      return false;
    }
    for (final fst in v.ruleFstsRel) {
      if (!exists(fst)) {
        return false;
      }
    }
    return true;
  }

  /// 下载并流式解压某音色。[onProgress] 回调 0~1，[onStage] 提示当前阶段。
  Future<void> install(
    SherpaVoice v, {
    void Function(double progress)? onProgress,
    void Function(String stage)? onStage,
  }) async {
    final base = await baseDir();
    final tmp = File(path.join(base.path, '${v.folder}.tar.bz2.download'));

    // 1) 下载（带进度，边下边写盘，不在内存堆积）
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(v.url));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw HttpException('下载失败，HTTP ${resp.statusCode}');
      }
      final sink = tmp.openWrite();
      var received = 0;
      try {
        await for (final chunk in resp) {
          sink.add(chunk);
          received += chunk.length;
          final declared = resp.contentLength;
          final ratio = declared > 0
              ? received / declared
              : received / v.downloadBytes;
          onProgress?.call(ratio.clamp(0, 0.99));
        }
      } finally {
        await sink.close();
      }
    } finally {
      client.close();
    }

    // 2) 流式解压 tar.bz2：bz2 惰性解压 + tar 逐 entry 直接写盘，
    //    内存中只保留一个解压窗口，避免 100+MB 模型全量驻留导致闪退。
    onStage?.call('正在解压语音模型…');
    onProgress?.call(0.995);
    final bzInput = InputFileStream(tmp.path);
    try {
      final tarStream = BZip2Decoder().decodeLazy(bzInput);
      TarDecoder().decodeStream(tarStream, callback: (entry) {
        final name = entry.name;
        if (name.contains('..')) {
          return;
        }
        final outPath = path.join(base.path, name);
        if (entry.isFile) {
          final f = File(outPath);
          f.parent.createSync(recursive: true);
          final out = OutputFileStream(f.path);
          entry.writeContent(out, freeMemory: true);
          out.close();
        } else {
          Directory(outPath).createSync(recursive: true);
        }
      });
    } finally {
      bzInput.close();
    }

    // 3) 校验并清理
    final ok = await isInstalled(v);
    try {
      tmp.deleteSync();
    } catch (_) {
      // 清理失败无所谓
    }
    if (!ok) {
      throw const HttpException('模型解压后文件不完整，请重试');
    }
    onProgress?.call(1.0);
  }

  /// 删除某音色模型。
  Future<void> delete(SherpaVoice v) async {
    final dir = await dirFor(v);
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }
}

/// sherpa-onnx 离线神经 TTS 引擎，实现项目统一的 [TtsEngine] 接口。
/// 返回 16-bit PCM WAV 字节，供 just_audio 播放。
class SherpaTtsEngine implements TtsEngine {
  SherpaTtsEngine(this.voice, {this.numThreads = 2});

  final SherpaVoice voice;
  final int numThreads;
  sherpa.OfflineTts? _tts;

  Future<void> _ensure() async {
    final existing = _tts;
    if (existing != null) {
      return;
    }
    final installed = await TtsModelManager.instance.isInstalled(voice);
    if (!installed) {
      throw StateError('离线语音「${voice.displayName}」尚未下载');
    }
    final base = (await TtsModelManager.instance.dirFor(voice)).path;
    _tts = buildOfflineTts(voice, base, numThreads: numThreads);
  }

  @override
  String get fileExt => 'wav';

  @override
  Future<Uint8List> synthesize(String text, String voiceName) async {
    await _ensure();
    return generateWithSplitting(_tts!, text, sid: voice.sid);
  }

  /// 释放原生引擎。
  void dispose() {
    _tts?.free();
    _tts = null;
  }
}

/// 把单声道 float32（-1~1）PCM 编码为 16-bit PCM WAV 字节。
Uint8List encodeWav(Float32List samples, int sampleRate) {
  final n = samples.length;
  final bytes = Uint8List(44 + n * 2);
  final data = ByteData.view(bytes.buffer);

  void ascii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      bytes[offset + i] = s.codeUnitAt(i);
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + n * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little); // fmt 子块大小
  data.setUint16(20, 1, Endian.little); // PCM
  data.setUint16(22, 1, Endian.little); // 单声道
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little); // 字节率
  data.setUint16(32, 2, Endian.little); // 块对齐
  data.setUint16(34, 16, Endian.little); // 位深
  ascii(36, 'data');
  data.setUint32(40, n * 2, Endian.little);

  for (var i = 0; i < n; i++) {
    var s = samples[i];
    if (s > 1) {
      s = 1;
    } else if (s < -1) {
      s = -1;
    }
    data.setInt16(44 + i * 2, (s * 32767).round(), Endian.little);
  }
  return bytes;
}

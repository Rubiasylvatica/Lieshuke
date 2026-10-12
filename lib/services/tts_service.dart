import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// TTS 引擎抽象：输入文字与音色名，返回音频字节。
/// 便于测试注入假引擎（见 test/）。
abstract class TtsEngine {
  Future<Uint8List> synthesize(String text, String voice);

  /// 生成文件的扩展名（mp3 / wav）。
  String get fileExt;
}

/// 可选音色（需求 R6.1：默认云希，可切云健 / 云扬 / 晓墨）。
const Map<String, String> ttsVoices = {
  '云希': 'zh-CN-YunxiNeural',
  '云健': 'zh-CN-YunJianNeural',
  '云扬': 'zh-CN-YunyangNeural',
  '晓墨': 'zh-CN-XiaomoNeural',
};

/// 按设置键创建引擎：'edge' 云端（可能不可用），其他走系统离线。
TtsEngine makeTtsEngine(String key) =>
    key == 'edge' ? EdgeTtsEngine() : SystemTtsEngine();

/// 系统引擎不支持生成音频文件（华为等引擎不实现 synthesizeToFile），
/// 此时应改用直接朗读（speak）模式。
class TtsFileNotSupportedException implements Exception {
  TtsFileNotSupportedException(this.detail);
  final String detail;

  @override
  String toString() => detail;
}

/// 为引擎挑选可用的中文语言代码并设置，返回设置成功的代码（'' = 失败）。
/// 不同手机的引擎语言代码不同（华为 zh/zh-Hans、谷歌 zh-CN 等），
/// 依次尝试候选，用 setLanguage 的返回值（1=成功）确认。
Future<String> pickChineseLanguage(FlutterTts tts) async {
  const candidates = ['zh-CN', 'zh-Hans', 'zh-Hant', 'zh', 'cmn-Hans-CN'];
  var supported = const <String>[];
  try {
    final list = await tts.getLanguages;
    supported = ((list ?? const []) as List).map((e) => e.toString()).toList();
  } catch (_) {
    // 拿不到列表就逐个硬试
  }
  final lower = supported.map((e) => e.toLowerCase()).toList();
  for (final c in candidates) {
    if (lower.contains(c.toLowerCase())) {
      final ok = await tts.setLanguage(c);
      if (ok == 1) {
        return c;
      }
    }
  }
  for (final c in candidates) {
    final ok = await tts.setLanguage(c);
    if (ok == 1) {
      return c;
    }
  }
  return '';
}

/// 系统离线 TTS 引擎（免费、无需联网、无需 Key，音色由系统决定）。
/// 生成 wav 文件后读回字节，供 AudioGenerator 统一保存。
class SystemTtsEngine implements TtsEngine {
  final FlutterTts _tts = FlutterTts();
  bool _ready = false;
  String _lang = '';

  Future<void> _ensureReady() async {
    if (_ready) {
      return;
    }
    // synthesizeToFile 完成需要 awaitSynthCompletion（awaitSpeakCompletion 只等 speak）
    await _tts.awaitSynthCompletion(true);
    await _tts.awaitSpeakCompletion(true);
    _lang = await pickChineseLanguage(_tts);
    await _tts.setSpeechRate(0.5);
    await _tts.setPitch(1.0);
    _ready = true;
  }

  @override
  String get fileExt => 'wav';

  @override
  Future<Uint8List> synthesize(String text, String voice) async {
    await _ensureReady();
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path,
        'tts_${DateTime.now().microsecondsSinceEpoch}.wav'));
    try {
      await _tts.synthesizeToFile(text, file.path);
    } catch (e) {
      throw TtsFileNotSupportedException(
          '系统语音引擎不支持生成音频文件（$e）。\n'
          '请用「直接朗读」模式收听，或到系统设置更换语音引擎。');
    }
    // 引擎写盘是异步的：轮询等文件出现，最多等 5 秒
    var waited = 0;
    while ((!file.existsSync() || file.lengthSync() == 0) &&
        waited < 5000) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      waited += 200;
    }
    if (!file.existsSync() || file.lengthSync() == 0) {
      throw TtsFileNotSupportedException(
          '系统语音引擎没有生成音频文件（当前语言：${_lang.isEmpty ? '未匹配到中文' : _lang}），'
          '可能是引擎不支持「合成到文件」。\n'
          '本 App 已支持直接朗读（无需生成音频文件），'
          '也可以到手机 设置 → 辅助功能/无障碍 → 文字转语音 更换语音引擎。');
    }
    final bytes = await file.readAsBytes();
    try {
      file.deleteSync();
    } catch (_) {
      // 清理失败无所谓
    }
    return bytes;
  }
}

/// Edge-TTS 免费神经语音（微软 Edge 网页朗读接口，无需 API Key）。
/// 参考开源的 edge-tts 协议：WebSocket 上行 SSML，下行二进制音频帧。
/// 注意：接口可能因服务端轮换 TrustedClientToken 而 403，默认已改用系统离线引擎。
class EdgeTtsEngine implements TtsEngine {
  static const _wssBase =
      'wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1';
  static const _trustedToken = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
  static const _origin =
      'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold';
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0';

  /// 单次请求最长字符数（过长拆段合成再拼接）。
  static const _chunkSize = 500;

  @override
  String get fileExt => 'mp3';

  final Random _rng = Random();

  String _uuid() {
    final hex = _rng.nextInt(1 << 31).toRadixString(16);
    final time = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    return '$time$hex${_rng.nextInt(1 << 31).toRadixString(16)}';
  }

  String _timestamp() => DateTime.now().toUtc().toIso8601String();

  @override
  Future<Uint8List> synthesize(String text, String voice) async {
    // 分段合成，避免单次请求过长被服务拒绝
    final parts = <Uint8List>[];
    var rest = text;
    while (rest.length > _chunkSize) {
      var cut = _chunkSize;
      // 尽量在句末切，读起来自然
      final dot = rest.lastIndexOf('。', cut);
      final qm = rest.lastIndexOf('？', cut);
      final ex = rest.lastIndexOf('！', cut);
      var best = dot > qm ? dot : qm;
      best = ex > best ? ex : best;
      if (best > _chunkSize ~/ 2) {
        cut = best + 1;
      }
      parts.add(await _synthesizeOnce(rest.substring(0, cut), voice));
      rest = rest.substring(cut);
    }
    if (rest.isNotEmpty) {
      parts.add(await _synthesizeOnce(rest, voice));
    }
    final builder = BytesBuilder(copy: false);
    for (final part in parts) {
      builder.add(part);
    }
    return builder.takeBytes();
  }

  Future<Uint8List> _synthesizeOnce(String text, String voice) async {
    final voiceId = ttsVoices[voice] ?? ttsVoices['云希']!;
    final url = '$_wssBase?TrustedClientToken=$_trustedToken'
        '&ConnectionId=${_uuid()}';
    final ws = await WebSocket.connect(
      url,
      headers: {
        'Origin': _origin,
        'User-Agent': _userAgent,
      },
    ).timeout(const Duration(seconds: 15));

    final audio = <int>[];
    final done = Completer<void>();
    try {
      // 1) 会话配置
      final ts = _timestamp();
      ws.add('X-Timestamp:$ts\r\n'
          'Content-Type:application/json; charset=utf-8\r\n'
          'Path:speech.config\r\n\r\n'
          '{"context":{"synthesis":{"audio":{"metadataoptions":{'
          '"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},'
          '"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}');

      // 2) SSML 请求
      final escaped = text
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;')
          .replaceAll('\r\n', '')
          .replaceAll('\n', '');
      final ssml = "<speak version='1.0' "
          "xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='zh-CN'>"
          "<voice name='$voiceId'>$escaped</voice></speak>";
      ws.add('X-RequestId:${_uuid()}\r\n'
          'Content-Type:application/ssml+xml\r\n'
          'X-Timestamp:${_timestamp()}\r\n'
          'Path:ssml\r\n\r\n'
          '$ssml');

      await for (final message in ws.timeout(const Duration(seconds: 30))) {
        if (message is String) {
          // 文本消息：服务端错误（403 / 请求被拒等）通常以文本返回
          final lowered = message.toLowerCase();
          if (lowered.contains('error') ||
              lowered.contains('403') ||
              lowered.contains('denied')) {
            throw Exception('语音服务返回错误：$message');
          }
          continue;
        }
        final bytes = message as List<int>;
        if (bytes.length < 2) {
          continue;
        }
        final headerLen = (bytes[0] << 8) | bytes[1];
        if (bytes.length < 2 + headerLen) {
          continue;
        }
        final header = utf8.decode(
          bytes.sublist(2, 2 + headerLen),
          allowMalformed: true,
        );
        final body = bytes.sublist(2 + headerLen);
        if (header.contains('Path:audio')) {
          audio.addAll(body);
        } else if (header.contains('Path:turn.end')) {
          if (!done.isCompleted) {
            done.complete();
          }
          break;
        }
      }
      await done.future.timeout(const Duration(seconds: 30));
      if (audio.isEmpty) {
        throw Exception('语音服务没有返回音频');
      }
      return Uint8List.fromList(audio);
    } finally {
      await ws.close();
    }
  }
}

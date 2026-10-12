import 'dart:io';
import 'dart:math' as math;

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// OCR 引擎抽象（可替换，未来可增加云端高精度引擎，见 docs/tech-stack.md ADR-002）。
abstract class OcrEngine {
  Future<String> recognize(String imagePath);

  void dispose() {}
}

/// 离线中文识别引擎（Google ML Kit，免费离线）。
///
/// 识别前先做「3a OCR」图像预处理：
/// 1. 灰度化 + 自动对比度增强 + 轻锐化（改善低照度 / 模糊 / 泛黄纸张）；
/// 2. 用识别到的文字行做线性回归估计倾斜角，超过阈值即旋转矫正；
/// 3. 按文字区包围盒裁掉边缘留白（裁切矫正），再识别一次拿更准结果。
///
/// 排版重建：自动分栏、居中标题独立成行、正文段首加两个全角空格缩进、
/// 段内印刷行连句、空行分段、过滤页眉页码。
class MlKitOcrEngine implements OcrEngine {
  final TextRecognizer _recognizer =
      TextRecognizer(script: TextRecognitionScript.chinese);

  @override
  Future<String> recognize(String imagePath) async {
    // 1) 读取原图
    final bytes = File(imagePath).readAsBytesSync();
    final src = img.decodeImage(bytes);
    if (src == null) {
      return _recognizeFile(imagePath);
    }

    // 2) 预处理增强：灰度 → 对比度 → 锐化
    var proc = img.grayscale(src);
    proc = img.adjustColor(proc, contrast: 1.35);
    proc = _sharpen(proc);

    final tmpDir = await getTemporaryDirectory();
    String save(img.Image image, String tag) {
      final f = File(p.join(
          tmpDir.path,
          'ocr_${tag}_${DateTime.now().microsecondsSinceEpoch}.png'));
      f.writeAsBytesSync(img.encodePng(image));
      return f.path;
    }

    final pathA = save(proc, 'a');
    final rA = await _recognizer.processImage(InputImage.fromFilePath(pathA));

    // 3) 倾斜估计：行中心线性回归
    final angleDeg = _estimateSkewAngle(rA);

    // 4) 旋转矫正
    var finalImage = proc;
    var result = rA;
    if (angleDeg.abs() >= 0.3) {
      finalImage = img.copyRotate(finalImage,
          angle: -angleDeg, interpolation: img.Interpolation.linear);
      final pathB = save(finalImage, 'b');
      result =
          await _recognizer.processImage(InputImage.fromFilePath(pathB));
    }

    // 5) 裁切矫正：文字区四周留白过多时裁剪后复识
    final crop = _contentCrop(result, finalImage);
    if (crop != null) {
      finalImage = img.copyCrop(finalImage,
          x: crop.$1, y: crop.$2, width: crop.$3, height: crop.$4);
      final pathC = save(finalImage, 'c');
      result =
          await _recognizer.processImage(InputImage.fromFilePath(pathC));
    }

    return _rebuildParagraphs(result);
  }

  /// 不进图像预处理（解码失败时兜底）。
  Future<String> _recognizeFile(String imagePath) async {
    final result =
        await _recognizer.processImage(InputImage.fromFilePath(imagePath));
    return _rebuildParagraphs(result);
  }

  /// 3x3 锐化卷积（保留原亮度，增强边缘，文字更清晰）。
  img.Image _sharpen(img.Image src) {
    return img.convolution(
      src,
      filter: const <num>[
        0, -1, 0, //
        -1, 5, -1, //
        0, -1, 0, //
      ],
      div: 1,
      offset: 0,
    );
  }

  /// 用文字行中心点估计页面倾斜角（度）。返回正数表示行向右下倾斜。
  double _estimateSkewAngle(RecognizedText text) {
    final pts = <(double, double)>[];
    for (final block in text.blocks) {
      for (final line in block.lines) {
        final b = line.boundingBox;
        final len = line.text.trim().length;
        if (len < 3 || b.width <= 0) {
          continue;
        }
        pts.add(((b.left + b.right) / 2, (b.top + b.bottom) / 2));
      }
    }
    if (pts.length < 6) {
      return 0.0;
    }
    var sx = 0.0, sy = 0.0;
    for (final (x, y) in pts) {
      sx += x;
      sy += y;
    }
    final n = pts.length.toDouble();
    final mx = sx / n, my = sy / n;
    var cov = 0.0, varX = 0.0;
    for (final (x, y) in pts) {
      cov += (x - mx) * (y - my);
      varX += (x - mx) * (x - mx);
    }
    if (varX <= 0) {
      return 0.0;
    }
    final slope = cov / varX;
    final deg = math.atan(slope) * 180 / math.pi;
    // 限幅，避免异常检测
    if (deg > 8 || deg < -8) {
      return 0.0;
    }
    return deg;
  }

  /// 计算文字区包围盒；四周留白过大时返回裁切矩形（像素），否则 null。
  (int, int, int, int)? _contentCrop(RecognizedText text, img.Image image) {
    if (text.blocks.isEmpty) {
      return null;
    }
    final w = image.width.toDouble();
    final h = image.height.toDouble();
    var minL = w, minT = h, maxR = 0.0, maxB = 0.0;
    var has = false;
    for (final block in text.blocks) {
      for (final line in block.lines) {
        final b = line.boundingBox;
        minL = math.min(minL, b.left);
        minT = math.min(minT, b.top);
        maxR = math.max(maxR, b.right);
        maxB = math.max(maxB, b.bottom);
        has = true;
      }
    }
    if (!has) {
      return null;
    }
    // 顶部 / 底部 / 左右留白都超过阈值才裁（避免误裁双栏或页边批注）
    final needCrop = minT > h * 0.08 &&
        maxB < h * 0.92 &&
        minL > w * 0.04 &&
        maxR < w * 0.96;
    if (!needCrop) {
      return null;
    }
    const pad = 0.015;
    var x = ((minL / w - pad).clamp(0.0, 1.0) * w).floor();
    var y = ((minT / h - pad).clamp(0.0, 1.0) * h).floor();
    var cw = (((maxR / w + pad).clamp(0.0, 1.0)) * w - x).ceil();
    var ch = (((maxB / h + pad).clamp(0.0, 1.0)) * h - y).ceil();
    x = x.clamp(0, image.width - 1);
    y = y.clamp(0, image.height - 1);
    cw = cw.clamp(1, image.width - x);
    ch = ch.clamp(1, image.height - y);
    return (x, y, cw, ch);
  }

  /// 依据坐标重建贴近原书排版的文本：
  /// - 自动分栏（双页扫描 / 两栏排版）；
  /// - 识别居中标题、段首空两格；
  /// - 段内印刷行连为一句（去掉硬换行），段落间空一行；
  /// - 正文段首自动加两个全角空格（符合中文排版习惯）；
  /// - 过滤页眉（顶部窄短行）与页码（底部数字短行）。
  String _rebuildParagraphs(RecognizedText result) {
    final all = <(TextLine, int)>[];
    var blockIndex = 0;
    for (final block in result.blocks) {
      for (final line in block.lines) {
        all.add((line, blockIndex));
      }
      blockIndex++;
    }
    if (all.isEmpty) {
      return result.text;
    }

    // 页面尺寸估算（ML Kit 为图片像素坐标，取最右下角）
    var imgH = 0.0;
    var imgW = 0.0;
    for (final (line, _) in all) {
      if (line.boundingBox.bottom > imgH) {
        imgH = line.boundingBox.bottom;
      }
      if (line.boundingBox.right > imgW) {
        imgW = line.boundingBox.right;
      }
    }

    // 过滤页眉与页码
    final kept = <(TextLine, int)>[];
    for (final (line, bi) in all) {
      final box = line.boundingBox;
      final text = line.text.trim();
      final isHeader = imgH > 0 &&
          box.top < imgH * 0.10 &&
          box.width < imgW * 0.5;
      final isPageNumber = imgH > 0 &&
          box.bottom > imgH * 0.92 &&
          text.length <= 8 &&
          RegExp(r'^[\d\s·\-—–.]+$').hasMatch(text);
      if (isHeader || isPageNumber) {
        continue;
      }
      kept.add((line, bi));
    }
    if (kept.isEmpty) {
      return result.text;
    }

    final columns = _splitColumns(kept, imgW);
    final parts = <String>[];
    for (final col in columns) {
      final text = _rebuildColumn(col);
      if (text.isNotEmpty) {
        parts.add(text);
      }
    }
    return parts.join('\n\n');
  }

  /// 段尾连句：段落以非句末标点结尾（如行尾落在“农夫”处），且下一段
  /// 是缩进正文（非标题）时，把下一段接上来，避免一句话被拆成两段。
  List<String> _mergeBrokenParagraphs(List<String> parts) {
    final merged = <String>[];
    for (final part in parts) {
      if (merged.isNotEmpty && _shouldJoin(merged.last, part)) {
        merged[merged.length - 1] = merged.last + part.substring(2);
      } else {
        merged.add(part);
      }
    }
    return merged;
  }

  bool _shouldJoin(String prev, String next) {
    if (next.length < 2 || !next.startsWith('　　')) {
      return false; // 标题 / 非缩进行不合并
    }
    if (prev.isEmpty) {
      return false;
    }
    const ends = '。！？…；：」』）"\'.!?;:';
    final last = String.fromCharCode(prev.codeUnitAt(prev.length - 1));
    return !ends.contains(last);
  }

  /// 检测分栏（最多两栏）。在页面中部寻找“几乎没有文字行跨越”的纵向分隔缝。
  List<List<(TextLine, int)>> _splitColumns(
      List<(TextLine, int)> lines, double imgW) {
    if (lines.length < 4 || imgW <= 0) {
      return [lines];
    }
    double? bestX;
    var bestCross = lines.length;
    const steps = 40;
    for (var s = 0; s <= steps; s++) {
      final x = imgW * (0.30 + 0.40 * s / steps);
      var cross = 0;
      for (final (line, _) in lines) {
        final b = line.boundingBox;
        if (b.left < x && b.right > x) {
          cross++;
        }
      }
      if (cross < bestCross) {
        bestCross = cross;
        bestX = x;
      }
    }
    if (bestX == null || bestCross > lines.length * 0.15) {
      return [lines];
    }
    final left = <(TextLine, int)>[];
    final right = <(TextLine, int)>[];
    for (final e in lines) {
      final b = e.$1.boundingBox;
      final center = (b.left + b.right) / 2;
      (center < bestX ? left : right).add(e);
    }
    if (left.isEmpty || right.isEmpty) {
      return [lines];
    }
    return [left, right];
  }

  /// 重建单栏：标题独立成行，段落按缩进 / 行距切分，段内连句，
  /// 正文段首加两个全角空格缩进。
  String _rebuildColumn(List<(TextLine, int)> lines) {
    lines.sort(
        (a, b) => a.$1.boundingBox.top.compareTo(b.$1.boundingBox.top));
    final n = lines.length;

    final gaps = <double>[];
    for (var i = 1; i < n; i++) {
      gaps.add(lines[i].$1.boundingBox.top -
          lines[i - 1].$1.boundingBox.top);
    }
    gaps.sort();
    final medianGap = gaps.isEmpty ? 0.0 : gaps[gaps.length ~/ 2];

    // 单字宽度估计
    final charWs = <double>[];
    for (final (line, _) in lines) {
      final len = line.text.trim().length;
      if (len > 0) {
        charWs.add(line.boundingBox.width / len);
      }
    }
    charWs.sort();
    final charW =
        charWs.isEmpty ? 10.0 : charWs[charWs.length ~/ 2];

    final lefts = lines.map((e) => e.$1.boundingBox.left).toList()..sort();
    final rights = lines.map((e) => e.$1.boundingBox.right).toList()..sort();
    final bodyLeft = lefts[(lefts.length * 0.15).floor()];
    final bodyRight = rights[(rights.length * 0.90).floor()];
    final colCenter = (bodyLeft + bodyRight) / 2;
    final bodyWidth = bodyRight - bodyLeft;
    final indentX = bodyLeft + charW * 1.2;

    final paragraphs = <String>[];
    final buf = StringBuffer();
    void flush() {
      if (buf.isNotEmpty) {
        paragraphs.add('　　${buf.toString()}');
        buf.clear();
      }
    }

    for (var i = 0; i < n; i++) {
      final line = lines[i].$1;
      final bi = lines[i].$2;
      final text = line.text.trim();
      if (text.isEmpty) {
        continue;
      }
      final b = line.boundingBox;
      final center = (b.left + b.right) / 2;
      final centered =
          (center - colCenter).abs() < charW * 1.2 && b.width < bodyWidth * 0.6;

      final gapAbove = i == 0
          ? double.infinity
          : b.top - lines[i - 1].$1.boundingBox.top;
      final blockChange = i == 0 ? false : bi != lines[i - 1].$2;
      final bigGap = medianGap > 0 && gapAbove > medianGap * 1.8;
      final indented = b.left >= indentX;
      final startNew = i == 0 ||
          bigGap ||
          indented ||
          (blockChange && gapAbove > medianGap * 1.2);

      if (centered) {
        flush();
        paragraphs.add(text); // 标题不缩进
        continue;
      }
      if (buf.isNotEmpty && startNew) {
        flush();
      }
      if (buf.isNotEmpty && _needSpace(buf.toString(), text)) {
        buf.write(' ');
      }
      buf.write(text);
    }
    flush();
    // 段尾连句只在单栏内进行：段落以非句末标点结尾（如行尾落在
    // “农夫”处），且下一段是缩进正文（非标题）时接上来，避免
    // 一句话被拆成两段。
    return _mergeBrokenParagraphs(paragraphs).join('\n\n');
  }

  /// 中英文混排时，行连接处若两侧都是英文 / 数字则补一个空格。
  bool _needSpace(String a, String b) {
    if (a.isEmpty || b.isEmpty) {
      return false;
    }
    bool alnum(int c) =>
        (c >= 0x30 && c <= 0x39) ||
        (c >= 0x41 && c <= 0x5A) ||
        (c >= 0x61 && c <= 0x7A);
    return alnum(a.codeUnitAt(a.length - 1)) && alnum(b.codeUnitAt(0));
  }

  @override
  void dispose() {
    _recognizer.close();
  }
}

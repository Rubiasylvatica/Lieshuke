import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/book_repository.dart';
import '../services/sherpa_tts.dart';
import '../theme/app_theme.dart';

/// 离线神经语音管理：下载 / 删除模型、试听、设置默认音色。
///
/// 模型仅首次下载一次，之后完全离线使用。
class OfflineTtsPage extends StatefulWidget {
  const OfflineTtsPage({super.key, required this.repository});

  final BookRepository repository;

  @override
  State<OfflineTtsPage> createState() => _OfflineTtsPageState();
}

class _OfflineTtsPageState extends State<OfflineTtsPage> {
  final _player = AudioPlayer();
  final Map<String, bool> _installed = <String, bool>{};
  final Map<String, double> _progress = <String, double>{};
  final Map<String, String> _stage = <String, String>{};
  String _selected = 'melo';
  String? _trialing;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final mgr = TtsModelManager.instance;
    final status = <String, bool>{};
    for (final v in kSherpaVoices) {
      status[v.id] = await mgr.isInstalled(v);
    }
    final saved = await widget.repository.getSetting(kSherpaVoiceSetting);
    if (!mounted) {
      return;
    }
    setState(() {
      _installed
        ..clear()
        ..addAll(status);
      _selected = saved ?? 'melo';
    });
  }

  void _snack(String msg) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _download(SherpaVoice v) async {
    setState(() {
      _progress[v.id] = 0;
      _stage[v.id] = '正在下载…';
    });
    try {
      await TtsModelManager.instance.install(
        v,
        onProgress: (value) => setState(() {
          _progress[v.id] = value;
          _stage[v.id] =
              value >= 0.99 ? '正在解压（大模型请耐心等待）…' : '正在下载…';
        }),
        onStage: (s) => setState(() => _stage[v.id] = s),
      );
      await _refresh();
      // 当前默认音色还没装好时，把新装的设为默认
      final selInstalled = _installed[_selected] ?? false;
      if (!selInstalled) {
        await _setDefault(v);
      }
      _snack('「${v.displayName}」已就绪');
    } catch (e) {
      setState(() {
        _progress.remove(v.id);
        _stage.remove(v.id);
      });
      _snack('下载失败：$e');
    }
  }

  Future<void> _setDefault(SherpaVoice v) async {
    await widget.repository.setSetting(kSherpaVoiceSetting, v.id);
    if (mounted) {
      setState(() => _selected = v.id);
    }
  }

  Future<void> _trial(SherpaVoice v) async {
    if (!(_installed[v.id] ?? false)) {
      _snack('请先下载该音色');
      return;
    }
    setState(() => _trialing = v.id);
    try {
      // 在后台 isolate 合成，避免大模型在界面线程加载导致卡顿。
      final modelBase = (await TtsModelManager.instance.dirFor(v)).path;
      final bytes = await synthesizeSpeechOnIsolate(
          v.id, '你好，这是猎书客的离线朗读，祝你阅读愉快。', modelBase);
      final tmp = await getTemporaryDirectory();
      final f = File(p.join(tmp.path, 'tts_trial_${v.id}.wav'));
      await f.writeAsBytes(bytes);
      await _player.setFilePath(f.path);
      _player.play();
    } catch (e) {
      _snack('试听失败：$e');
    } finally {
      if (mounted) {
        setState(() => _trialing = null);
      }
    }
  }

  Future<void> _delete(SherpaVoice v) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('删除「${v.displayName}」？',
            style: const TextStyle(
                color: AppColors.textPrimary, fontSize: 16)),
        content: Text('将释放约 ${v.downloadMb}MB 存储空间，之后可重新下载。',
            style:
                TextStyle(color: AppColors.textSecondary, fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: AppColors.gold)),
          ),
        ],
      ),
    );
    if (ok != true) {
      return;
    }
    await TtsModelManager.instance.delete(v);
    if (_selected == v.id) {
      await widget.repository.setSetting(kSherpaVoiceSetting, 'melo');
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('离线语音与音色')),
      body: RadioGroup<String>(
        groupValue: _selected,
        onChanged: (id) {
          if (id == null) {
            return;
          }
          if (_installed[id] ?? false) {
            _setDefault(sherpaVoiceById(id));
          } else {
            _snack('请先下载该音色');
          }
        },
        child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surfaceHigh,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.outline),
            ),
            child: const Text(
              '全部为离线神经网络语音，免费、无需账号与 API Key。\n'
              '每个音色仅需在 Wi-Fi 下下载一次（约 60MB，高保真音色约 160MB），之后永久离线使用。',
              style:
                  TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
          ),
          const SizedBox(height: 12),
          for (final v in kSherpaVoices) _voiceCard(v),
        ],
        ),
      ),
    );
  }

  Widget _voiceCard(SherpaVoice v) {
    final installed = _installed[v.id] ?? false;
    final progress = _progress[v.id];
    final downloading = progress != null;
    return Card(
      color: AppColors.surface,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: AppColors.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  v.gender == '女'
                      ? Icons.record_voice_over_outlined
                      : Icons.mic_none_outlined,
                  size: 18,
                  color: AppColors.gold,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(v.displayName,
                      style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600)),
                ),
                Radio<String>(
                  value: v.id,
                  activeColor: AppColors.gold,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 26),
              child: Text(
                '${v.gender}声 · 约 ${v.downloadMb}MB · ${installed ? '已就绪' : '未下载'}',
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 11),
              ),
            ),
            if (downloading) ...[
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: LinearProgressIndicator(
                  value: progress >= 0.99 ? null : progress,
                  minHeight: 4,
                  backgroundColor: AppColors.surfaceHigh,
                  color: AppColors.gold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                  progress >= 0.99
                      ? (_stage[v.id] ?? '正在解压…')
                      : '${_stage[v.id] ?? '下载中'} ${(progress * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 11)),
            ],
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (installed) ...[
                  TextButton(
                    onPressed: _trialing == v.id ? null : () => _trial(v),
                    child: Text(_trialing == v.id ? '试听中…' : '试听',
                        style: const TextStyle(
                            color: AppColors.gold, fontSize: 12)),
                  ),
                  TextButton(
                    onPressed: () => _delete(v),
                    child: const Text('删除',
                        style: TextStyle(
                            color: AppColors.textSecondary, fontSize: 12)),
                  ),
                ] else
                  TextButton.icon(
                    onPressed: downloading ? null : () => _download(v),
                    icon: const Icon(Icons.download, size: 16),
                    label: const Text('下载',
                        style: TextStyle(
                            color: AppColors.gold, fontSize: 12)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

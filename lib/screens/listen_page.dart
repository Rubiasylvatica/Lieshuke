import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart' hide Page;

import '../data/app_database.dart';
import '../data/book_repository.dart';
import '../services/book_audio_handler.dart';
import '../services/sherpa_tts.dart';
import '../theme/app_theme.dart';
import 'offline_tts_page.dart';

/// 听书页：界面绑定到全局 [bookAudioHandler]。
///
/// - 逐页离线合成、无缝连播、倍速、进度、上一段 / 下一段；
/// - 退出页面、锁屏后继续后台播放，并由通知栏 / 锁屏控制；
/// - 自动记忆每本书的收听位置，下次进入继续。
class ListenPage extends StatefulWidget {
  const ListenPage({
    super.key,
    required this.repository,
    required this.book,
  });

  final BookRepository repository;
  final Book book;

  @override
  State<ListenPage> createState() => _ListenPageState();
}

class _ListenPageState extends State<ListenPage> {
  bool _loaded = false;
  bool _empty = false;
  bool _modelMissing = false;
  String _voiceName = '';
  Map<String, bool> _voiceInstalled = <String, bool>{};

  @override
  void initState() {
    super.initState();
    _open();
    _refreshVoices();
  }

  Future<void> _refreshVoices() async {
    final m = <String, bool>{};
    for (final v in kSherpaVoices) {
      m[v.id] = await TtsModelManager.instance.isInstalled(v);
    }
    if (mounted) {
      setState(() => _voiceInstalled = m);
    }
  }

  Future<void> _switchVoice(String voiceId) async {
    final r = await bookAudioHandler.switchVoice(voiceId);
    if (!mounted) {
      return;
    }
    if (r.ok) {
      await widget.repository.setSetting(kSherpaVoiceSetting, voiceId);
      setState(() => _voiceName = r.voiceName);
    }
  }

  Future<void> _open() async {
    final r = await bookAudioHandler.openBook(widget.book);
    if (!mounted) {
      return;
    }
    setState(() {
      _loaded = true;
      _empty = r.empty;
      _modelMissing = r.modelMissing;
      _voiceName = r.voiceName;
    });
  }

  Future<void> _openDownload() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => OfflineTtsPage(repository: widget.repository),
    ));
    if (!mounted) {
      return;
    }
    setState(() => _loaded = false);
    await _open();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('听书 · ${widget.book.title}')),
      body: !_loaded
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.gold))
          : _empty
              ? _message(
                  Icons.headphones_outlined,
                  '还没有可听的文字',
                  '先拍照并识别文字，就能来这里听书了',
                )
              : _modelMissing
                  ? _modelMissingView()
                  : _playerView(),
    );
  }

  Widget _modelMissingView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.download_for_offline_outlined,
                size: 56, color: AppColors.gold),
            const SizedBox(height: 16),
            Text('还没下载离线语音「$_voiceName」',
                style: const TextStyle(
                    color: AppColors.textPrimary, fontSize: 15)),
            const SizedBox(height: 8),
            const Text('在 Wi-Fi 下下载一次（约 60MB），之后完全离线使用',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: AppColors.textSecondary, fontSize: 12)),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _openDownload,
              icon: const Icon(Icons.download, size: 18),
              label: const Text('去下载语音'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accentRed,
                foregroundColor: AppColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _playerView() {
    final h = bookAudioHandler;
    return Column(
      children: [
        // 准备状态条
        StreamBuilder<PrepStatus>(
          stream: h.prepSubject,
          initialData: h.prepSubject.value,
          builder: (context, snap) {
            final s = snap.data;
            final prepping = s?.prepping ?? false;
            return Container(
              width: double.infinity,
              color: AppColors.surfaceHigh,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  if (prepping)
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.gold),
                    )
                  else
                    const Icon(Icons.check_circle_outline,
                        size: 14, color: AppColors.gold),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(s?.message ?? '',
                        style: const TextStyle(
                            color: AppColors.gold, fontSize: 12)),
                  ),
                ],
              ),
            );
          },
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
            child: Column(
              children: [
                const Spacer(),
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceHigh,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.outline),
                  ),
                  child: const Icon(Icons.graphic_eq,
                      size: 44, color: AppColors.gold),
                ),
                const SizedBox(height: 20),
                Text(widget.book.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                StreamBuilder<MediaItem?>(
                  stream: h.mediaItem,
                  builder: (context, snap) => Text(
                      '${snap.data?.title ?? '准备中'} · 共 ${h.segmentCount} 段',
                      style: const TextStyle(
                          color: AppColors.textSecondary, fontSize: 12)),
                ),
                const Spacer(),
                StreamBuilder<Duration>(
                  stream: h.positionStream,
                  builder: (context, posSnap) {
                    return StreamBuilder<Duration?>(
                      stream: h.durationStream,
                      builder: (context, durSnap) {
                        final position = posSnap.data ?? Duration.zero;
                        final duration = durSnap.data ?? Duration.zero;
                        return Column(
                          children: [
                            Slider(
                              value: duration.inMilliseconds == 0
                                  ? 0
                                  : position.inMilliseconds
                                      .clamp(0, duration.inMilliseconds)
                                      .toDouble(),
                              max: duration.inMilliseconds == 0
                                  ? 1
                                  : duration.inMilliseconds.toDouble(),
                              activeColor: AppColors.gold,
                              onChanged: duration.inMilliseconds == 0
                                  ? null
                                  : (v) => h.seek(
                                      Duration(milliseconds: v.toInt())),
                            ),
                            Row(
                              mainAxisAlignment:
                                  MainAxisAlignment.spaceBetween,
                              children: [
                                Text(_fmt(position),
                                    style: const TextStyle(
                                        color: AppColors.textSecondary,
                                        fontSize: 11)),
                                Text(_fmt(duration),
                                    style: const TextStyle(
                                        color: AppColors.textSecondary,
                                        fontSize: 11)),
                              ],
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
                const SizedBox(height: 8),
                StreamBuilder<PlaybackState>(
                  stream: h.playbackState,
                  builder: (context, snap) {
                    final st = snap.data;
                    final playing = st?.playing ?? false;
                    final idx = st?.queueIndex ?? 0;
                    final qlen = h.queue.value.length;
                    final hasPrev = idx > 0;
                    final hasNext = idx < qlen - 1;
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          iconSize: 32,
                          color: AppColors.textSecondary,
                          onPressed: hasPrev ? h.skipToPrevious : null,
                          icon: const Icon(Icons.skip_previous_outlined),
                        ),
                        const SizedBox(width: 20),
                        IconButton(
                          iconSize: 64,
                          color: AppColors.gold,
                          onPressed: () =>
                              playing ? h.pause() : h.play(),
                          icon: Icon(playing
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled),
                        ),
                        const SizedBox(width: 20),
                        IconButton(
                          iconSize: 32,
                          color: AppColors.textSecondary,
                          onPressed: hasNext ? h.skipToNext : null,
                          icon: const Icon(Icons.skip_next_outlined),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.record_voice_over_outlined,
                        size: 16, color: AppColors.textSecondary),
                    const SizedBox(width: 6),
                    PopupMenuButton<String>(
                      onSelected: _switchVoice,
                      itemBuilder: (_) => [
                        for (final v in kSherpaVoices
                            .where((v) => _voiceInstalled[v.id] ?? false))
                          PopupMenuItem(
                            value: v.id,
                            child: Row(
                              children: [
                                Icon(
                                  bookAudioHandler.currentVoice?.id == v.id
                                      ? Icons.check_circle
                                      : Icons.circle_outlined,
                                  size: 16,
                                  color:
                                      bookAudioHandler.currentVoice?.id == v.id
                                          ? AppColors.gold
                                          : AppColors.textSecondary,
                                ),
                                const SizedBox(width: 8),
                                Text(v.displayName,
                                    style: TextStyle(
                                        color:
                                            bookAudioHandler.currentVoice?.id ==
                                                    v.id
                                                ? AppColors.gold
                                                : AppColors.textPrimary,
                                        fontSize: 13)),
                              ],
                            ),
                          ),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Text(
                            bookAudioHandler.currentVoice?.displayName ??
                                _voiceName,
                            style: const TextStyle(
                                color: AppColors.textPrimary, fontSize: 13)),
                      ),
                    ),
                    const SizedBox(width: 20),
                    const Icon(Icons.speed,
                        size: 16, color: AppColors.textSecondary),
                    const SizedBox(width: 6),
                    PopupMenuButton<double>(
                      onSelected: (v) async {
                        await h.changeSpeed(v);
                        setState(() {});
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
                        padding: const EdgeInsets.all(6),
                        child: Text('${h.speed} x',
                            style: const TextStyle(
                                color: AppColors.textPrimary, fontSize: 13)),
                      ),
                    ),
                  ],
                ),
                const Spacer(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _message(IconData icon, String title, String subtitle) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: AppColors.textSecondary),
          const SizedBox(height: 12),
          Text(title,
              style: const TextStyle(
                  color: AppColors.textPrimary, fontSize: 15)),
          const SizedBox(height: 6),
          Text(subtitle,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 12)),
        ],
      ),
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

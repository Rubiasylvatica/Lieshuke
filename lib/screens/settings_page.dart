import 'package:flutter/material.dart';

import '../app_info.dart';
import '../data/book_repository.dart';
import '../theme/app_theme.dart';
import 'backup_restore_page.dart';
import 'correction_rules_page.dart';
import 'offline_tts_page.dart';

/// 设置：朗读引擎、校正词库等（各批次逐步补充）。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, this.repository});

  /// 可注入的数据仓库（测试用）。
  final BookRepository? repository;

  @override
  Widget build(BuildContext context) {
    final repo = repository;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('识别',
                style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
          ),
          ListTile(
            leading: const Icon(Icons.auto_fix_high_outlined,
                color: AppColors.gold),
            title: const Text('识别校正词库',
                style: TextStyle(color: AppColors.textPrimary, fontSize: 14)),
            subtitle: const Text('校对时自动学习「错字 → 正确字」，识别时自动改正',
                style:
                    TextStyle(color: AppColors.textSecondary, fontSize: 11)),
            trailing: const Icon(Icons.chevron_right,
                color: AppColors.textSecondary),
            onTap: repo == null
                ? null
                : () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => CorrectionRulesPage(repository: repo),
                    )),
          ),
          const Divider(height: 1, color: AppColors.outline),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('朗读',
                style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
          ),
          ListTile(
            leading: const Icon(Icons.record_voice_over_outlined,
                color: AppColors.gold),
            title: const Text('离线语音与音色',
                style: TextStyle(color: AppColors.textPrimary, fontSize: 14)),
            subtitle: const Text('离线神经网络语音，免费、无需联网（首次下载约 60MB）',
                style:
                    TextStyle(color: AppColors.textSecondary, fontSize: 11)),
            trailing: const Icon(Icons.chevron_right,
                color: AppColors.textSecondary),
            onTap: repo == null
                ? null
                : () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => OfflineTtsPage(repository: repo),
                    )),
          ),
          const Divider(height: 1, color: AppColors.outline),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('数据',
                style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
          ),
          ListTile(
            leading: const Icon(Icons.backup_outlined, color: AppColors.gold),
            title: const Text('备份与恢复',
                style: TextStyle(color: AppColors.textPrimary, fontSize: 14)),
            subtitle: const Text('导出书库与照片为备份文件；从备份恢复',
                style:
                    TextStyle(color: AppColors.textSecondary, fontSize: 11)),
            trailing: const Icon(Icons.chevron_right,
                color: AppColors.textSecondary),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const BackupRestorePage(),
                )),
          ),
          const Divider(height: 1, color: AppColors.outline),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('关于',
                style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
          ),
          ListTile(
            leading: const Icon(Icons.auto_stories_outlined,
                color: AppColors.textSecondary),
            title: const Text('猎书客',
                style: TextStyle(color: AppColors.textPrimary, fontSize: 14)),
            subtitle: Text('拍照识书 · 校对 · 阅读 · 听书（全部离线免费）\n版本 $kAppVersion',
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 11)),
          ),
        ],
      ),
    );
  }
}

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/backup_service.dart';
import '../theme/app_theme.dart';

/// 备份与恢复页（批次 14）。
class BackupRestorePage extends StatefulWidget {
  const BackupRestorePage({super.key});

  @override
  State<BackupRestorePage> createState() => _BackupRestorePageState();
}

class _BackupRestorePageState extends State<BackupRestorePage> {
  bool _busy = false;

  void _snack(String msg) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final zip = await BackupService.instance.exportBackup();
      await BackupService.instance.shareBackup(zip);
      _snack('备份已打包，请选择保存位置（建议存到文件管理或网盘）');
    } catch (e) {
      _snack('导出失败：$e');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _restore() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    final path = files.isNotEmpty ? files.first.path : null;
    if (path == null) {
      return;
    }
    if (!mounted) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认恢复'),
        content: const Text('恢复会用备份内容覆盖当前的全部书库和照片，且无法撤销。确定继续吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('恢复', style: TextStyle(color: AppColors.gold)),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }

    setState(() => _busy = true);
    try {
      await BackupService.instance.restoreFromZip(File(path));
      if (!mounted) {
        return;
      }
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('恢复完成'),
          content: const Text('数据已恢复。App 将自动关闭，请重新打开。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('好的', style: TextStyle(color: AppColors.gold)),
            ),
          ],
        ),
      );
      SystemNavigator.pop();
    } catch (e) {
      if (!mounted) {
        return;
      }
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('恢复失败'),
          content: Text('恢复失败：$e\n\n原有数据已保留。App 将自动关闭，请重新打开后重试。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('好的', style: TextStyle(color: AppColors.gold)),
            ),
          ],
        ),
      );
      SystemNavigator.pop();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('备份与恢复')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '备份包含：全部书籍、页面照片、封面、批注、阅读进度与设置。\n'
            '语音模型不包含在备份中，恢复后联网重新下载即可。',
            style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                height: 1.6),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _busy ? null : _export,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.gold,
              foregroundColor: AppColors.textPrimary,
            ),
            icon: const Icon(Icons.file_upload_outlined),
            label: const Text('导出备份'),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _busy ? null : _restore,
            icon: const Icon(Icons.file_download_outlined),
            label: const Text('从备份恢复'),
          ),
          if (_busy) ...[
            const SizedBox(height: 24),
            const Center(child: CircularProgressIndicator()),
          ],
        ],
      ),
    );
  }
}

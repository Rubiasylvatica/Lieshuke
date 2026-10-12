import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../data/book_repository.dart';
import '../theme/app_theme.dart';

/// 校正词库页：查看 / 删除自学习积累的「错字 → 正确字」规则。
/// 规则由校对页在用户改字时自动学习，OCR 识别时自动套用。
class CorrectionRulesPage extends StatelessWidget {
  const CorrectionRulesPage({super.key, required this.repository});

  final BookRepository repository;

  Future<void> _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('清空全部校正规则？',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
        content: const Text('清空后，之后识别不会再自动套用这些改字规则。',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空', style: TextStyle(color: AppColors.accentRed)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await repository.clearCorrectionRules();
    }
  }

  /// 手动添加一条规则：错字 → 正确字。
  Future<void> _addRule(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final wrongCtrl = TextEditingController();
    final rightCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('添加校正规则',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: wrongCtrl,
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: const InputDecoration(
                labelText: '识别错的字 / 词',
                labelStyle: TextStyle(color: AppColors.textSecondary),
                hintText: '例如：肉（经常被误识别成这个）',
                hintStyle: TextStyle(color: AppColors.textSecondary),
                filled: true,
                fillColor: AppColors.surfaceHigh,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: rightCtrl,
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: const InputDecoration(
                labelText: '应该正确的字 / 词',
                labelStyle: TextStyle(color: AppColors.textSecondary),
                hintText: '例如：内',
                hintStyle: TextStyle(color: AppColors.textSecondary),
                filled: true,
                fillColor: AppColors.surfaceHigh,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('添加',
                style: TextStyle(color: AppColors.textPrimary)),
          ),
        ],
      ),
    );
    if (ok == true) {
      final wrong = wrongCtrl.text.trim();
      final right = rightCtrl.text.trim();
      if (wrong.isEmpty || right.isEmpty || wrong == right) {
        messenger.showSnackBar(
            const SnackBar(content: Text('请填写不同的“错字”和“正确字”')));
        return;
      }
      await repository.addCorrectionRule(wrong, right);
      messenger.showSnackBar(
          const SnackBar(content: Text('已添加规则，之后的识别会自动套用')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('识别校正词库'),
        actions: [
          IconButton(
            tooltip: '手动添加规则',
            icon: const Icon(Icons.add, color: AppColors.gold),
            onPressed: () => _addRule(context),
          ),
        ],
      ),
      body: StreamBuilder<List<CorrectionRule>>(
        stream: repository.watchCorrectionRules(),
        builder: (context, snapshot) {
          final rules = snapshot.data ?? const <CorrectionRule>[];
          return Column(
            children: [
              Container(
                width: double.infinity,
                color: AppColors.surfaceHigh,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: const Text(
                  '在校对页改过的字会自动记成规则，以后识别时自动改正；'
                  '也可点右上角 + 手动添加（例如总把“内”认错的字）。'
                  '点右侧按钮可删除某条规则。',
                  style:
                      TextStyle(color: AppColors.textSecondary, fontSize: 12),
                ),
              ),
              if (rules.isEmpty)
                const Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.auto_fix_high_outlined,
                            size: 48, color: AppColors.textSecondary),
                        SizedBox(height: 12),
                        Text('还没有校正规则',
                            style: TextStyle(
                                color: AppColors.textPrimary, fontSize: 15)),
                        SizedBox(height: 6),
                        Text('去校对页改几个识别错字，这里就会自动记下',
                            style: TextStyle(
                                color: AppColors.textSecondary, fontSize: 12)),
                      ],
                    ),
                  ),
                )
              else
                Expanded(
                  child: ListView.builder(
                    itemCount: rules.length,
                    itemBuilder: (context, i) {
                      final r = rules[i];
                      return ListTile(
                        dense: true,
                        title: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: r.wrong,
                                style: const TextStyle(
                                    color: AppColors.accentRed,
                                    decoration: TextDecoration.lineThrough),
                              ),
                              const TextSpan(
                                text: '  →  ',
                                style: TextStyle(
                                    color: AppColors.textSecondary),
                              ),
                              TextSpan(
                                text: r.right,
                                style: const TextStyle(
                                    color: AppColors.textPrimary,
                                    fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                        subtitle: Text(
                          '命中 ${r.hitCount} 次',
                          style: const TextStyle(
                              color: AppColors.textSecondary, fontSize: 11),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline,
                              size: 18, color: AppColors.textSecondary),
                          onPressed: () =>
                              repository.deleteCorrectionRule(r.id),
                        ),
                      );
                    },
                  ),
                ),
              if (rules.isNotEmpty)
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: TextButton(
                      onPressed: () => _confirmClear(context),
                      child: const Text('清空全部规则',
                          style: TextStyle(
                              color: AppColors.accentRed, fontSize: 13)),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

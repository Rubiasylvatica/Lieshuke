import 'package:flutter/material.dart';

import '../widgets/section_placeholder.dart';

/// 网络图：书与书之间的关联（批次 13 实现）。
class GraphPage extends StatelessWidget {
  const GraphPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('网络图')),
      body: const SectionPlaceholder(
        icon: Icons.hub_outlined,
        title: '网络图',
        hint: '书与书自由连线，如「A 提到了 B」。\n封面为节点，可缩放拖动。',
      ),
    );
  }
}

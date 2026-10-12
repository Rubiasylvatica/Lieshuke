import 'package:flutter/material.dart';

import '../data/book_repository.dart';
import '../theme/app_theme.dart';
import 'bookshelf_page.dart';
import 'settings_page.dart';
import 'stats_page.dart';

/// 应用主壳：底部三标签导航（书架 / 统计 / 设置）。
/// （书关联网络图已并入书的预览页「关联」入口。）
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, this.bookshelfRepository});

  /// 可注入的书架数据仓库（测试用）。
  final BookRepository? bookshelfRepository;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      BookshelfPage(repository: widget.bookshelfRepository),
      StatsPage(repository: widget.bookshelfRepository),
      SettingsPage(repository: widget.bookshelfRepository),
    ];
    return Scaffold(
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.outline)),
        ),
        child: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.auto_stories_outlined),
              selectedIcon: Icon(Icons.auto_stories),
              label: '书架',
            ),
            NavigationDestination(
              icon: Icon(Icons.bar_chart_outlined),
              selectedIcon: Icon(Icons.bar_chart),
              label: '统计',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: '设置',
            ),
          ],
        ),
      ),
    );
  }
}

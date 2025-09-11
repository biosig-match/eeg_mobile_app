import 'package:flutter/material.dart';
import '../screens/analysis_screen.dart';
import '../screens/experiments_screen.dart';

class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          const DrawerHeader(
            decoration: BoxDecoration(color: Color(0xFF1E1E1E)),
            child: Text('メニュー',
                style: TextStyle(fontSize: 24, color: Colors.white)),
          ),
          ListTile(
            leading: const Icon(Icons.home_outlined),
            title: const Text('ホーム'),
            onTap: () {
              Navigator.of(context).pop(); // Drawerを閉じる
            },
          ),
          ListTile(
            leading: const Icon(Icons.science_outlined),
            title: const Text('実験一覧'),
            onTap: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ExperimentsScreen()));
            },
          ),
          ListTile(
            leading: const Icon(Icons.analytics_outlined),
            title: const Text('リアルタイム解析'),
            onTap: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AnalysisScreen()));
            },
          ),
        ],
      ),
    );
  }
}

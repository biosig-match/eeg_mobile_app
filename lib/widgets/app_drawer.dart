import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../screens/analysis_screen.dart';
import '../screens/bids_export_screen.dart';
import '../screens/experiments_screen.dart';
import '../screens/neuro_marketing_screen.dart';

class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key});

  void _showUserIdDialog(BuildContext context) {
    final authProvider = context.read<AuthProvider>();
    final controller = TextEditingController(text: authProvider.userId ?? '');

    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ユーザーIDを変更'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'ユーザーID',
            hintText: '例: participant-001',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () {
              authProvider.updateUserId(controller.text);
              Navigator.of(dialogContext).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('ユーザーIDを "${authProvider.userId}" に設定しました。'),
                ),
              );
            },
            child: const Text('保存'),
          ),
        ],
      ),
    ).whenComplete(() => controller.dispose());
  }

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
          ListTile(
            leading: const Icon(Icons.insights_outlined),
            title: const Text('ニューロマーケ分析'),
            onTap: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const NeuroMarketingScreen()));
            },
          ),
          // ★★★ BIDSエクスポート画面への導線を追加 ★★★
          const Divider(),
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('ユーザーIDを変更'),
            onTap: () {
              Navigator.of(context).pop();
              _showUserIdDialog(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.archive_outlined),
            title: const Text('BIDSエクスポート状況'),
            onTap: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const BidsExportScreen()));
            },
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/bids_provider.dart';
import '../providers/session_provider.dart';
import 'experiment_editor_screen.dart';

class ExperimentsScreen extends StatelessWidget {
  const ExperimentsScreen({super.key});

  Future<void> _openExperimentEditor(BuildContext context) async {
    final sessionProvider = context.read<SessionProvider>();
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ExperimentEditorScreen()),
    );
    await sessionProvider.fetchExperiments();
  }

  @override
  Widget build(BuildContext context) {
    final sessionProvider = context.watch<SessionProvider>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text("実験一覧"),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            tooltip: "新規実験を作成",
            onPressed: () => _openExperimentEditor(context),
          ),
          // ★★★ リフレッシュボタンを追加 ★★★
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: "リストを更新",
            onPressed: () => sessionProvider.fetchExperiments(),
          ),
        ],
      ),
      body: ListView.builder(
        itemCount: sessionProvider.experiments.length,
        itemBuilder: (ctx, index) {
          final experiment = sessionProvider.experiments[index];
          final isSelected =
              sessionProvider.selectedExperiment.id == experiment.id;

          return Card(
            color: isSelected
                ? theme.colorScheme.primary.withOpacity(0.3)
                : theme.cardColor,
            child: ListTile(
              leading: Icon(
                  isSelected ? Icons.check_circle : Icons.science_outlined),
              title: Text(experiment.name),
              subtitle: Text(experiment.description,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              // ★★★ BIDSエクスポートボタンを追加 ★★★
              trailing: IconButton(
                icon: const Icon(Icons.archive_outlined),
                tooltip: "BIDS形式でエクスポート",
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (dCtx) => AlertDialog(
                      title: const Text("BIDSエクスポート"),
                      content: Text(
                          "'${experiment.name}' のデータをエクスポートしますか？\n(処理には時間がかかる場合があります)"),
                      actions: [
                        TextButton(
                          child: const Text("キャンセル"),
                          onPressed: () => Navigator.of(dCtx).pop(),
                        ),
                        FilledButton(
                          child: const Text("開始"),
                          onPressed: () {
                            context
                                .read<BidsProvider>()
                                .startExport(experiment.id);
                            Navigator.of(dCtx).pop();
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text("BIDSエクスポートを開始しました。")),
                            );
                          },
                        ),
                      ],
                    ),
                  );
                },
              ),
              onTap: () {
                sessionProvider.selectExperiment(experiment.id);
                Navigator.of(context).pop(); // ホーム画面に戻る
              },
            ),
          );
        },
      ),
    );
  }
}

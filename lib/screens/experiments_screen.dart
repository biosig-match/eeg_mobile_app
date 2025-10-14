import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/bids_provider.dart';
import '../providers/session_provider.dart';

class ExperimentsScreen extends StatelessWidget {
  const ExperimentsScreen({super.key});

  void _showCreateExperimentDialog(BuildContext context) {
    final sessionProvider = context.read<SessionProvider>();
    final nameController = TextEditingController();
    final descriptionController = TextEditingController();
    String presentationOrder = 'random';

    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text("新しい実験を作成"),
          content: StatefulBuilder(
            builder: (ctx, setState) => SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: "実験名",
                      hintText: "例: ブランド認知度テスト",
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: descriptionController,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: "説明",
                      hintText: "任意で詳細を入力してください",
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: presentationOrder,
                    items: const [
                      DropdownMenuItem(value: 'random', child: Text('ランダム提示')),
                      DropdownMenuItem(value: 'sequential', child: Text('順番通りに提示')),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => presentationOrder = value);
                      }
                    },
                    decoration: const InputDecoration(
                      labelText: "刺激提示の順番",
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () async {
                final name = nameController.text.trim();
                final description = descriptionController.text.trim();
                if (name.isEmpty) {
                  Navigator.of(dialogContext).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('実験名を入力してください。')),
                  );
                  return;
                }

                Navigator.of(dialogContext).pop();
                await sessionProvider.createExperiment(
                  name: name,
                  description: description,
                  presentationOrder: presentationOrder,
                );
              },
              child: const Text('作成'),
            ),
          ],
        );
      },
    );
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
            onPressed: () => _showCreateExperimentDialog(context),
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

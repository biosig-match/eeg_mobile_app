import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/session_provider.dart';

class ExperimentsScreen extends StatelessWidget {
  const ExperimentsScreen({super.key});

  void _showCreateExperimentDialog(BuildContext context) {
    final nameController = TextEditingController();
    final descriptionController = TextEditingController();
    final sessionProvider = context.read<SessionProvider>();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("新規実験の作成"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: "実験名")),
            TextField(
                controller: descriptionController,
                decoration: const InputDecoration(labelText: "説明")),
          ],
        ),
        actions: [
          TextButton(
            child: const Text("キャンセル"),
            onPressed: () => Navigator.of(ctx).pop(),
          ),
          FilledButton(
            child: const Text("作成"),
            onPressed: () {
              if (nameController.text.isNotEmpty) {
                sessionProvider.createExperiment(
                  name: nameController.text,
                  description: descriptionController.text,
                );
                Navigator.of(ctx).pop();
              }
            },
          ),
        ],
      ),
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
            icon: const Icon(Icons.add),
            onPressed: () => _showCreateExperimentDialog(context),
          ),
        ],
      ),
      body: ListView.builder(
        itemCount: sessionProvider.experiments.length,
        itemBuilder: (ctx, index) {
          final experiment = sessionProvider.experiments[index];
          final isSelected =
              sessionProvider.selectedExperiment?.id == experiment.id;

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

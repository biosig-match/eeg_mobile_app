import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/experiment.dart';
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

  Future<void> _openJoinDialog(BuildContext context) async {
    final sessionProvider = context.read<SessionProvider>();
    final experimentIdController = TextEditingController();
    final passwordController = TextEditingController();

    final joined = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("実験に参加"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: experimentIdController,
              decoration: const InputDecoration(
                labelText: "実験ID",
                hintText: "例: 123e4567-e89b-12d3-a456-426614174000",
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: passwordController,
              decoration: const InputDecoration(
                labelText: "パスワード (任意)",
              ),
              obscureText: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text("キャンセル"),
          ),
          FilledButton(
            onPressed: () async {
              final ok = await sessionProvider.joinExperiment(
                experimentIdController.text,
                password: passwordController.text,
              );
              if (context.mounted) {
                Navigator.of(dialogContext).pop(ok);
              }
            },
            child: const Text("参加する"),
          ),
        ],
      ),
    );

    experimentIdController.dispose();
    passwordController.dispose();

    if (joined == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("実験に参加しました。実験リストを更新しました。")),
      );
    } else if (joined == false && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(sessionProvider.statusMessage)),
      );
    }
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
          IconButton(
            icon: const Icon(Icons.login),
            tooltip: "実験に参加",
            onPressed: () => _openJoinDialog(context),
          ),
          // ★★★ リフレッシュボタンを追加 ★★★
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: "リストを更新",
            onPressed: () => sessionProvider.fetchExperiments(),
          ),
        ],
      ),
      body: ListView(
        children: [
          if (sessionProvider.isExperimentSelected)
            Card(
              color: theme.colorScheme.secondaryContainer,
              child: ListTile(
                leading: const Icon(Icons.radio_button_unchecked),
                title: const Text('フリーセッションに切り替える'),
                subtitle: const Text('現在の実験選択を解除し、実験に所属しないセッションを開始します'),
                trailing: TextButton(
                  onPressed: () {
                    sessionProvider.deselectExperiment();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('実験の選択を解除しました。')),
                    );
                  },
                  child: const Text('解除'),
                ),
                onTap: () {
                  sessionProvider.deselectExperiment();
                  Navigator.of(context).pop();
                },
              ),
            ),
          for (final experiment in sessionProvider.experiments)
            _ExperimentTile(
              experiment: experiment,
              isSelected:
                  sessionProvider.selectedExperiment.id == experiment.id,
              theme: theme,
            ),
          if (sessionProvider.experiments.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: Text('参加中の実験がありません。新規作成または招待コードで参加してください。'),
              ),
            ),
        ],
      ),
    );
  }
}

class _ExperimentTile extends StatelessWidget {
  const _ExperimentTile({
    required this.experiment,
    required this.isSelected,
    required this.theme,
  });

  final Experiment experiment;
  final bool isSelected;
  final ThemeData theme;

  Future<void> _confirmDelete(BuildContext context) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('実験を削除'),
        content: Text(
          "'${experiment.name}' を完全に削除します。\nこの操作は取り消せません。",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.delete_outline),
            label: const Text('削除する'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
          ),
        ],
      ),
    );

    if (shouldDelete == true && context.mounted) {
      final sessionProvider = context.read<SessionProvider>();
      final success = await sessionProvider.deleteExperiment(experiment.id);
      if (!context.mounted) return;
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("'${experiment.name}' を削除しました。")),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(sessionProvider.statusMessage)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: isSelected
          ? theme.colorScheme.primary.withOpacity(0.25)
          : theme.cardColor,
      child: ListTile(
        leading: Icon(isSelected ? Icons.check_circle : Icons.science_outlined),
        title: Text(experiment.name),
        subtitle: Text(
          experiment.description,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.archive_outlined),
              tooltip: 'BIDS形式でエクスポート',
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (dCtx) => AlertDialog(
                    title: const Text('BIDSエクスポート'),
                    content: Text(
                      "'${experiment.name}' のデータをエクスポートしますか？\n(処理には時間がかかる場合があります)",
                    ),
                    actions: [
                      TextButton(
                        child: const Text('キャンセル'),
                        onPressed: () => Navigator.of(dCtx).pop(),
                      ),
                      FilledButton(
                        child: const Text('開始'),
                        onPressed: () {
                          context
                              .read<BidsProvider>()
                              .startExport(experiment.id);
                          Navigator.of(dCtx).pop();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('BIDSエクスポートを開始しました。'),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '実験を削除',
              onPressed: () => _confirmDelete(context),
            ),
          ],
        ),
        onTap: () {
          context.read<SessionProvider>().selectExperiment(experiment.id);
          Navigator.of(context).pop();
        },
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/bids_task.dart';
import '../models/experiment.dart'; // ★★★ Experimentモデルをインポート ★★★
import '../providers/bids_provider.dart';
import '../providers/session_provider.dart';

class BidsExportScreen extends StatefulWidget {
  const BidsExportScreen({super.key});

  @override
  State<BidsExportScreen> createState() => _BidsExportScreenState();
}

class _BidsExportScreenState extends State<BidsExportScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<BidsProvider>().refreshTasks();
    });
  }

  @override
  Widget build(BuildContext context) {
    final bidsProvider = context.watch<BidsProvider>();
    final experiments = context.read<SessionProvider>().experiments;
    final tasks = bidsProvider.tasks;

    final statusMessage = bidsProvider.statusMessage;

    return Scaffold(
      appBar: AppBar(
        title: const Text("BIDSエクスポート状況"),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: "最新の状況を取得",
            onPressed: () =>
                context.read<BidsProvider>().refreshTasks(silent: true),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => context.read<BidsProvider>().refreshTasks(),
        child: tasks.isEmpty
            ? ListView(
                children: [
                  const SizedBox(height: 120),
                  const Center(child: Text("エクスポートタスクはありません。")),
                  if (statusMessage.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Text(
                        statusMessage,
                        textAlign: TextAlign.center,
                      ),
                    ),
                ],
              )
            : ListView.builder(
                itemCount: tasks.length,
                itemBuilder: (ctx, index) {
                  final task = tasks[index];
                  final experimentName = experiments
                      .firstWhere((e) => e.id == task.experimentId,
                          orElse: () => Experiment.empty())
                      .name;

                  return Card(
                    margin:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: ListTile(
                      leading: _buildStatusIcon(task.status),
                      title: Text(experimentName),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "開始日時: ${DateFormat('yyyy/MM/dd HH:mm').format(task.createdAt.toLocal())}",
                          ),
                          if (task.message.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4.0),
                              child: Text(task.message),
                            ),
                          if (task.status == BidsTaskStatus.processing)
                            Padding(
                              padding: const EdgeInsets.only(top: 8.0),
                              child: LinearProgressIndicator(
                                value: task.progress.clamp(0, 100) / 100.0,
                              ),
                            ),
                          if (task.status == BidsTaskStatus.failed &&
                              task.errorMessage != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 4.0),
                              child: Text(
                                "エラー: ${task.errorMessage}",
                                style: const TextStyle(color: Colors.redAccent),
                              ),
                            ),
                        ],
                      ),
                      trailing: task.status == BidsTaskStatus.completed
                          ? IconButton(
                              icon: const Icon(Icons.download),
                              tooltip: "ダウンロード",
                              onPressed: () =>
                                  bidsProvider.downloadBidsFile(task.taskId),
                            )
                          : null,
                    ),
                  );
                },
              ),
      ),
      bottomNavigationBar: statusMessage.isNotEmpty
          ? Padding(
              padding: const EdgeInsets.all(12.0),
              child: Text(
                statusMessage,
                textAlign: TextAlign.center,
              ),
            )
          : null,
    );
  }

  Widget _buildStatusIcon(BidsTaskStatus status) {
    switch (status) {
      case BidsTaskStatus.pending:
        return const Icon(Icons.pending_outlined, color: Colors.grey);
      case BidsTaskStatus.processing:
        return const SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 3),
        );
      case BidsTaskStatus.completed:
        return const Icon(Icons.check_circle, color: Colors.green);
      case BidsTaskStatus.failed:
        return const Icon(Icons.error, color: Colors.red);
    }
  }
}

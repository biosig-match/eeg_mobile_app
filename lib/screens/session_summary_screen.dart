import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/session_provider.dart';

class SessionSummaryScreen extends StatefulWidget {
  const SessionSummaryScreen({super.key});

  @override
  State<SessionSummaryScreen> createState() => _SessionSummaryScreenState();
}

class _SessionSummaryScreenState extends State<SessionSummaryScreen> {
  PlatformFile? _pickedFile;

  Future<void> _pickCsvFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    if (result != null) {
      setState(() {
        _pickedFile = result.files.single;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessionProvider = context.watch<SessionProvider>();
    final session = sessionProvider.currentSession;
    final theme = Theme.of(context);

    if (session == null) {
      // セッションが存在しない場合はホームに戻る
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Navigator.of(context).pop();
      });
      return const Scaffold(body: Center(child: Text("セッション情報がありません。")));
    }

    return Scaffold(
      appBar: AppBar(
          title: const Text("セッションの完了"), automaticallyImplyLeading: false),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text("セッション概要", style: theme.textTheme.headlineSmall),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("開始時刻: ${session.startTime.toLocal()}"),
                    Text("終了時刻: ${DateTime.now().toLocal()}"), // 暫定表示
                    Text("実験名: ${sessionProvider.selectedExperiment?.name}"),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text("イベントリスト (任意)", style: theme.textTheme.headlineSmall),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(_pickedFile?.name ?? "CSVファイルが選択されていません"),
                    ),
                    ElevatedButton(
                      onPressed: _pickCsvFile,
                      child: const Text("ファイルを選択"),
                    ),
                  ],
                ),
              ),
            ),
            const Spacer(),
            FilledButton.icon(
              icon: const Icon(Icons.check),
              label: const Text("完了してアップロード"),
              style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16)),
              onPressed: () async {
                await sessionProvider.endSessionAndUpload(
                    eventCsvFile: _pickedFile);
                if (mounted) {
                  Navigator.of(context).pop();
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

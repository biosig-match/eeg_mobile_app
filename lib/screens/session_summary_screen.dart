import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/session_provider.dart';

class SessionSummaryScreen extends StatefulWidget {
  // ★★★ アプリ内セッションからCSV文字列を受け取るためのコンストラクタ ★★★
  final String? generatedCsvData;
  const SessionSummaryScreen({super.key, this.generatedCsvData});

  @override
  State<SessionSummaryScreen> createState() => _SessionSummaryScreenState();
}

class _SessionSummaryScreenState extends State<SessionSummaryScreen> {
  PlatformFile? _pickedFile;
  // ★★★ UI表示用のCSVデータソースを保持 ★★★
  String? _csvDataSource;

  @override
  void initState() {
    super.initState();
    if (widget.generatedCsvData != null) {
      _csvDataSource =
          "アプリ内で記録済み (${widget.generatedCsvData!.split('\n').length - 1}件)";
    }
  }

  Future<void> _pickCsvFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'tsv', 'txt'],
    );
    if (result != null) {
      setState(() {
        _pickedFile = result.files.single;
        _csvDataSource = _pickedFile!.name;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessionProvider = context.watch<SessionProvider>();
    final session = sessionProvider.currentSession;
    final theme = Theme.of(context);

    if (session == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
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
                    Text("終了時刻: ${DateTime.now().toLocal()}"),
                    Text("実験名: ${sessionProvider.selectedExperiment.name}"),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text("イベントリスト", style: theme.textTheme.headlineSmall),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(_csvDataSource ?? "CSVファイルが選択されていません"),
                    ),
                    // ★★★ アプリ内実行の場合はファイル選択ボタンを無効化 ★★★
                    ElevatedButton(
                      onPressed:
                          widget.generatedCsvData != null ? null : _pickCsvFile,
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
                  eventCsvString: widget.generatedCsvData,
                  eventCsvFile: _pickedFile,
                );
                if (mounted) {
                  // ★★★ ホーム画面まで戻る ★★★
                  Navigator.of(context).popUntil((route) => route.isFirst);
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

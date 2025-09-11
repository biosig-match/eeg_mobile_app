import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/analysis_provider.dart';
import '../widgets/analysis_image_viewer.dart';

class AnalysisScreen extends StatefulWidget {
  const AnalysisScreen({super.key});

  @override
  State<AnalysisScreen> createState() => _AnalysisScreenState();
}

class _AnalysisScreenState extends State<AnalysisScreen> {
  @override
  void initState() {
    super.initState();
    // この画面が表示されたらポーリングを開始
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AnalysisProvider>().setPolling(true);
    });
  }

  @override
  void dispose() {
    // 画面が非表示になったらポーリングを停止
    // ウィジェットツリーにまだ存在する場合があるため、try-catchで囲む
    try {
      context.read<AnalysisProvider>().setPolling(false);
    } catch (e) {
      debugPrint("AnalysisProvider not found during dispose: $e");
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final analysisProvider = context.watch<AnalysisProvider>();

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text("リアルタイム解析"),
          bottom: const TabBar(
            tabs: [
              Tab(text: "パワースペクトル (PSD)"),
              Tab(text: "コヒーレンス"),
            ],
          ),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text(analysisProvider.analysisStatus),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  AnalysisImageViewer(
                      imageData: analysisProvider.latestAnalysis?.psdImage),
                  AnalysisImageViewer(
                      imageData:
                          analysisProvider.latestAnalysis?.coherenceImage),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

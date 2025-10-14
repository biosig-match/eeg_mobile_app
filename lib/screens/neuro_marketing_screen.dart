import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/erp_analysis_result.dart';
import '../providers/erp_analysis_provider.dart';
import '../providers/session_provider.dart';

class NeuroMarketingScreen extends StatefulWidget {
  const NeuroMarketingScreen({super.key});

  @override
  State<NeuroMarketingScreen> createState() => _NeuroMarketingScreenState();
}

class _NeuroMarketingScreenState extends State<NeuroMarketingScreen> {
  String? _selectedExperimentId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final experiments = context.read<SessionProvider>().experiments;
    if (_selectedExperimentId == null && experiments.isNotEmpty) {
      _selectedExperimentId = experiments.first.id;
    }
  }

  Future<void> _fetchResult(BuildContext context, String experimentId) async {
    await context
        .read<ErpAnalysisProvider>()
        .fetchLatestResults(experimentId);
  }

  Future<void> _requestAnalysis(
      BuildContext context, String experimentId) async {
    await context.read<ErpAnalysisProvider>().requestAnalysis(experimentId);
  }

  @override
  Widget build(BuildContext context) {
    final sessionProvider = context.watch<SessionProvider>();
    final erpProvider = context.watch<ErpAnalysisProvider>();
    final experiments = sessionProvider.experiments;

    if (_selectedExperimentId != null &&
        experiments.every((exp) => exp.id != _selectedExperimentId)) {
      _selectedExperimentId = experiments.isNotEmpty ? experiments.first.id : null;
    }

    final selectedId = _selectedExperimentId;
    final latestResult =
        selectedId != null ? erpProvider.getLatest(selectedId) : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('ニューロマーケティング分析'),
        actions: [
          IconButton(
            tooltip: '実験リストを更新',
            icon: const Icon(Icons.refresh),
            onPressed: () => sessionProvider.fetchExperiments(),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              value: selectedId,
              decoration: const InputDecoration(
                labelText: '分析対象の実験',
              ),
              items: experiments
                  .map(
                    (exp) => DropdownMenuItem(
                      value: exp.id,
                      child: Text(exp.name),
                    ),
                  )
                  .toList(),
              onChanged: (value) => setState(() => _selectedExperimentId = value),
            ),
            if (experiments.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8.0),
                child: Text(
                  '参加中の実験がありません。フリーセッションや実験作成を行ってください。',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: selectedId == null
                        ? null
                        : () => _fetchResult(context, selectedId),
                    icon: const Icon(Icons.cloud_download_outlined),
                    label: const Text('最新結果を取得'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: selectedId == null
                        ? null
                        : () => _requestAnalysis(context, selectedId),
                    icon: const Icon(Icons.play_arrow_outlined),
                    label: const Text('解析を実行'),
                  ),
                ),
              ],
            ),
            if (erpProvider.isLoading) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(),
            ],
            const SizedBox(height: 8),
            Text(
              erpProvider.statusMessage,
              style: const TextStyle(color: Colors.cyanAccent),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: latestResult == null
                  ? const Center(
                      child: Text('分析結果がまだありません。',
                          style: TextStyle(color: Colors.white70)),
                    )
                  : _AnalysisResultView(result: latestResult),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnalysisResultView extends StatelessWidget {
  final ErpAnalysisResult result;
  const _AnalysisResultView({required this.result});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('解析日時: ${result.formattedGeneratedAt}'),
            const SizedBox(height: 8),
            const Text('推奨サマリー',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(result.summary),
            const SizedBox(height: 16),
            const Text('推奨された刺激',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Expanded(
              child: result.recommendations.isEmpty
                  ? const Center(child: Text('推奨項目はありません。'))
                  : ListView.builder(
                      itemCount: result.recommendations.length,
                      itemBuilder: (context, index) {
                        final rec = result.recommendations[index];
                        return ListTile(
                          leading: const Icon(Icons.lightbulb_outline),
                          title: Text(rec.itemName ?? rec.fileName),
                          subtitle: Text(
                            [rec.brandName, rec.category, rec.gender]
                                .where((element) =>
                                    element != null && element!.isNotEmpty)
                                .join(' / '),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

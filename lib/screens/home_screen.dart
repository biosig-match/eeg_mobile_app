import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../providers/ble_provider.dart';
import '../../providers/analysis_provider.dart';
import '../../providers/experiment_provider.dart';
import '../../widgets/eeg_chart.dart';
import '../../widgets/analysis_widgets.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _participantIdController = TextEditingController(text: "sub-01");

  @override
  void initState() {
    super.initState();
    // 権限をリクエスト
    [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.location].request();
  }
  
  @override
  void dispose() {
    _participantIdController.dispose();
    super.dispose();
  }

  void _showParticipantIdDialog(BuildContext context) {
    final bleProvider = context.read<BleProvider>();
    final experimentProvider = context.read<ExperimentProvider>();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("実験を開始"),
          content: TextField(
            controller: _participantIdController,
            decoration: const InputDecoration(labelText: "参加者ID"),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("キャンセル"),
            ),
            FilledButton(
              onPressed: () {
                if (_participantIdController.text.isNotEmpty && bleProvider.connectedDeviceId != null) {
                  experimentProvider.startExperiment(
                    participantId: _participantIdController.text,
                    deviceId: bleProvider.connectedDeviceId!,
                  );
                  Navigator.of(context).pop();
                }
              },
              child: const Text("開始"),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final bleProvider = context.watch<BleProvider>();
    final analysisProvider = context.watch<AnalysisProvider>();
    final experimentProvider = context.watch<ExperimentProvider>();

    return Scaffold(
      appBar: AppBar(title: const Text('EEG BIDS Collector')),
      body: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          children: [
            // ステータス表示
            Card(
              child: ListTile(
                leading: Icon(bleProvider.isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled),
                title: Text(bleProvider.statusMessage),
                subtitle: Text(experimentProvider.statusMessage),
                trailing: Text(bleProvider.connectedDeviceId ?? "Device ID: ---"),
              ),
            ),
            // 脳波チャート
            Expanded(
              flex: 2,
              child: EegMultiChannelChart(
                data: bleProvider.displayData,
                channelCount: 8,
              ),
            ),
            // 解析結果タブ
            Expanded(
              flex: 1,
              child: DefaultTabController(
                length: 2,
                child: Column(
                  children: [
                    const TabBar(tabs: [Tab(text: "PSD"), Tab(text: "Coherence")]),
                    Expanded(
                      child: TabBarView(
                        children: [
                          AnalysisImageViewer(imageProvider: () => analysisProvider.latestAnalysis?.psdImage),
                          AnalysisImageViewer(imageProvider: () => analysisProvider.latestAnalysis?.coherenceImage),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      // フローティングアクションボタン
      floatingActionButton: _buildActionButton(context, bleProvider, experimentProvider, analysisProvider),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }

  Widget _buildActionButton(BuildContext context, BleProvider ble, ExperimentProvider exp, AnalysisProvider ana) {
    if (!ble.isConnected) {
      return FloatingActionButton.extended(
        onPressed: ble.startScan,
        label: const Text("デバイスをスキャン"),
        icon: const Icon(Icons.search),
      );
    }
    
    if (exp.isRunning) {
      return FloatingActionButton.extended(
        onPressed: exp.stopAndUploadEvents,
        label: const Text("実験を終了 & CSVをアップロード"),
        icon: const Icon(Icons.stop),
        backgroundColor: Colors.red,
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        FloatingActionButton.extended(
          onPressed: () => _showParticipantIdDialog(context),
          label: const Text("実験を開始"),
          icon: const Icon(Icons.play_arrow),
          backgroundColor: Colors.green,
        ),
        const SizedBox(width: 16),
        FloatingActionButton.extended(
          onPressed: () {
            ble.disconnect();
            ana.stopPolling();
          },
          label: const Text("切断"),
          icon: const Icon(Icons.link_off),
          backgroundColor: Colors.grey,
        )
      ],
    );
  }
}
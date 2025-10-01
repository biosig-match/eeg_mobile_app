import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/session.dart';
import '../providers/ble_provider.dart';
import '../providers/session_provider.dart';
import '../widgets/app_drawer.dart';
import '../widgets/eeg_chart.dart';
import '../widgets/valence_chart.dart';
import 'experiments_screen.dart';
import 'session_summary_screen.dart';
import 'stimulus_presentation_screen.dart'; // ★★★ 新しい画面をインポート ★★★

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
      Permission.camera,
      Permission.microphone,
    ].request();
  }

  // ★★★ セッション開始時の選択肢を増やす ★★★
  void _showSessionTypeDialog() {
    final sessionProvider = context.read<SessionProvider>();
    final bleProvider = context.read<BleProvider>();
    final connectedDeviceId = bleProvider.connectedDeviceId;
    final clockOffsetInfo = bleProvider.lastClockOffsetInfo;

    if (connectedDeviceId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("デバイスIDが不明です。再接続してください。")),
      );
      return;
    }
    if (clockOffsetInfo == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("時刻同期が完了していません。")),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("セッションの実行方法を選択"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ElevatedButton(
              child: const Text("アプリ内で刺激を提示"),
              onPressed: () {
                Navigator.of(ctx).pop(); // ダイアログを閉じる
                _startInAppPresentationSession(
                    sessionProvider, connectedDeviceId, clockOffsetInfo);
              },
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              child: const Text("外部アプリで刺激を提示 (PsychoPyなど)"),
              onPressed: () {
                Navigator.of(ctx).pop(); // ダイアログを閉じる
                _startExternalSession(
                    sessionProvider, connectedDeviceId, clockOffsetInfo);
              },
            ),
          ],
        ),
      ),
    );
  }

  // ★★★ アプリ内提示セッションを開始するロジック ★★★
  void _startInAppPresentationSession(SessionProvider sessionProvider,
      String deviceId, Map<String, dynamic> clockOffsetInfo) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("セッション種別を選択"),
        actions: [
          TextButton(
            child: const Text("キャリブレーション"),
            onPressed: () async {
              Navigator.of(ctx).pop();
              await sessionProvider.startSession(
                type: SessionType.calibration,
                deviceId: deviceId,
                clockOffsetInfo: clockOffsetInfo,
              );
              if (mounted && sessionProvider.isSessionRunning) {
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const StimulusPresentationScreen()));
              }
            },
          ),
          FilledButton(
            child: const Text("本計測"),
            onPressed: () async {
              Navigator.of(ctx).pop();
              await sessionProvider.startSession(
                type: SessionType.main_task,
                deviceId: deviceId,
                clockOffsetInfo: clockOffsetInfo,
              );
              if (mounted && sessionProvider.isSessionRunning) {
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const StimulusPresentationScreen()));
              }
            },
          ),
        ],
      ),
    );
  }

  // ★★★ 外部提示セッションを開始するロジック ★★★
  void _startExternalSession(SessionProvider sessionProvider, String deviceId,
      Map<String, dynamic> clockOffsetInfo) async {
    await sessionProvider.startSession(
      type: SessionType.main_external,
      deviceId: deviceId,
      clockOffsetInfo: clockOffsetInfo,
    );
    // 外部セッションの場合は刺激提示画面には遷移しない
  }

  @override
  Widget build(BuildContext context) {
    final bleProvider = context.watch<BleProvider>();
    final sessionProvider = context.watch<SessionProvider>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('EEG BIDS Collector'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: Icon(
              bleProvider.isConnected
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth_disabled,
              color: bleProvider.isConnected ? Colors.cyanAccent : Colors.grey,
            ),
          )
        ],
      ),
      drawer: const AppDrawer(),
      body: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.science_outlined),
                title: Text(sessionProvider.selectedExperiment.name),
                subtitle: Text(sessionProvider.statusMessage,
                    style: TextStyle(color: theme.colorScheme.primary)),
                trailing: TextButton(
                  child: const Text("変更"),
                  onPressed: () {
                    Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const ExperimentsScreen()));
                  },
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              flex: 3,
              child: EegMultiChannelChart(
                data: bleProvider.displayData,
                sampleRate: BleProvider.sampleRate,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              flex: 2,
              child: ValenceChart(data: bleProvider.valenceHistory),
            ),
            const SizedBox(height: 16),
            _buildActionButton(context, bleProvider, sessionProvider),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButton(
      BuildContext context, BleProvider ble, SessionProvider session) {
    if (!ble.isConnected) {
      return FloatingActionButton.extended(
        onPressed: ble.startScan,
        label: const Text("デバイスをスキャン"),
        icon: const Icon(Icons.search),
      );
    }

    if (session.isSessionRunning) {
      return FloatingActionButton.extended(
        onPressed: () {
          // ★★★ 刺激提示画面からは直接終了させないので、このボタンは外部セッション用になる ★★★
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const SessionSummaryScreen()),
          );
        },
        label: const Text("外部セッションを終了"),
        icon: const Icon(Icons.stop),
        backgroundColor: Colors.red,
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        FloatingActionButton.extended(
          onPressed:
              session.isExperimentSelected ? _showSessionTypeDialog : null,
          label: const Text("セッション開始"),
          icon: const Icon(Icons.play_arrow),
          backgroundColor:
              session.isExperimentSelected ? Colors.green : Colors.grey,
        ),
        const SizedBox(width: 16),
        FloatingActionButton(
          onPressed: ble.disconnect,
          backgroundColor: Colors.grey[800],
          child: const Icon(Icons.link_off),
          heroTag: 'disconnect_button',
        ),
      ],
    );
  }
}

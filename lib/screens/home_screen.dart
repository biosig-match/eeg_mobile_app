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

  void _showSessionTypeDialog() {
    // ★★★ Providerの取得をダイアログ表示前に行う ★★★
    final sessionProvider = context.read<SessionProvider>();
    final bleProvider = context.read<BleProvider>();
    final connectedDeviceId = bleProvider.connectedDeviceId;

    // デバイスIDが取得できていない場合はセッションを開始しない
    if (connectedDeviceId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("デバイスIDが不明です。再接続してください。")),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("セッション種別を選択"),
        content: const Text("このセッションはキャリブレーションですか、本計測ですか？"),
        actions: [
          TextButton(
            child: const Text("キャリブレーション"),
            onPressed: () {
              // ★★★ deviceIdを渡す ★★★
              sessionProvider.startSession(
                type: SessionType.calibration,
                deviceId: connectedDeviceId,
              );
              Navigator.of(ctx).pop();
            },
          ),
          FilledButton(
            child: const Text("本計測"),
            onPressed: () {
              // ★★★ deviceIdを渡す ★★★
              sessionProvider.startSession(
                type: SessionType.main,
                deviceId: connectedDeviceId,
              );
              Navigator.of(ctx).pop();
            },
          ),
        ],
      ),
    );
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
                title: Text(
                    sessionProvider.selectedExperiment?.name ?? "実験が選択されていません"),
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
              child: EegMultiChannelChart(data: bleProvider.displayData),
            ),
            const SizedBox(height: 8),
            Expanded(
              flex: 2,
              child: ValenceChart(data: bleProvider.valenceHistory),
            ),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton:
          _buildActionButton(context, bleProvider, sessionProvider),
    );
  }

  Widget _buildActionButton(
      BuildContext context, BleProvider ble, SessionProvider session) {
    // ... (このウィジェットビルドメソッドに変更はなし)
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
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const SessionSummaryScreen()),
          );
        },
        label: const Text("セッション終了"),
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

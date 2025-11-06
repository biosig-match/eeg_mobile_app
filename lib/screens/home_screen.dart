import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/session.dart';
import '../providers/analysis_provider.dart';
import '../providers/ble_provider.dart';
import '../providers/media_provider.dart';
import '../providers/session_provider.dart';
import '../widgets/app_drawer.dart';
import '../widgets/eeg_chart.dart';
import '../widgets/valence_chart.dart';
import 'experiments_screen.dart';
import 'session_summary_screen.dart';
import 'stimulus_presentation_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Timer? _analysisTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializePermissionsAndMedia();
      _startAnalysisPolling();
    });
  }

  Future<void> _initializePermissionsAndMedia() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
      Permission.camera,
      Permission.microphone,
    ].request();
    if (!mounted) return;
    await context.read<MediaProvider>().initialize();
  }

  void _startAnalysisPolling() {
    _analysisTimer?.cancel();
    final analysisProvider = context.read<AnalysisProvider>();
    analysisProvider.fetchLatestResults();
    _analysisTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!mounted) return;
      final ble = context.read<BleProvider>();
      if (!ble.isConnected) return;
      analysisProvider.fetchLatestResults();
    });
  }

  @override
  void dispose() {
    _analysisTimer?.cancel();
    super.dispose();
  }

  void _showSessionTypeDialog() {
    final sessionProvider = context.read<SessionProvider>();
    final bleProvider = context.read<BleProvider>();
    final connectedDeviceId = bleProvider.deviceId;
    if (connectedDeviceId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("デバイスIDが不明です。再接続してください。")),
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
                Navigator.of(ctx).pop();
                _startInAppPresentationSession(
                    sessionProvider, connectedDeviceId, {});
              },
            ),
            if (!sessionProvider.isExperimentSelected ||
                sessionProvider.selectedExperiment.id.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  "※本計測を実行する場合は実験を選択してください（キャリブレーションは不要）",
                  style: TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ),
            const SizedBox(height: 8),
            ElevatedButton(
              child: const Text("外部アプリで刺激を提示 (PsychoPyなど)"),
              onPressed: () {
                Navigator.of(ctx).pop();
                _startExternalSession(sessionProvider, connectedDeviceId, {});
              },
            ),
          ],
        ),
      ),
    );
  }

  void _startInAppPresentationSession(SessionProvider sessionProvider,
      String deviceId, Map<String, dynamic> clockOffsetInfo) {
    final canRunMainTask = sessionProvider.isExperimentSelected &&
        sessionProvider.selectedExperiment.id.isNotEmpty;
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
            onPressed: canRunMainTask
                ? () async {
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
                  }
                : null,
          ),
          if (!canRunMainTask)
            const Padding(
              padding:
                  EdgeInsets.only(top: 8.0, right: 8.0, left: 8.0, bottom: 4.0),
              child: Text(
                "※本計測を実行するには実験を選択してください。",
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    );
  }

  void _startExternalSession(SessionProvider sessionProvider, String deviceId,
      Map<String, dynamic> clockOffsetInfo) async {
    await sessionProvider.startSession(
      type: SessionType.main_external,
      deviceId: deviceId,
      clockOffsetInfo: clockOffsetInfo,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bleProvider = context.watch<BleProvider>();
    final sessionProvider = context.watch<SessionProvider>();
    final analysisProvider = context.watch<AnalysisProvider>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('EEG BIDS Collector'),
        actions: [
          PopupMenuButton<DeviceType>(
            tooltip: "スキャンするデバイスを選択",
            icon: const Icon(Icons.devices_other),
            onSelected: (deviceType) {
              if (bleProvider.isConnected) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("まず現在のデバイスとの接続を解除してください。")),
                );
                return;
              }
              bleProvider.startScan(targetDeviceType: deviceType);
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: DeviceType.customEeg,
                child: Text('自作脳波計 (ESP32)'),
              ),
              const PopupMenuItem(
                value: DeviceType.muse2,
                child: Text('Muse 2'),
              ),
            ],
          ),
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
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              children: [
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.science_outlined),
                    title: Text(sessionProvider.selectedExperiment.name),
                    subtitle: Text(sessionProvider.statusMessage,
                        style: TextStyle(color: theme.colorScheme.primary)),
                    trailing: Wrap(
                      spacing: 8,
                      children: [
                        if (sessionProvider.isExperimentSelected)
                          TextButton(
                            onPressed: () {
                              sessionProvider.deselectExperiment();
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('実験選択を解除しました。')),
                              );
                            },
                            child: const Text('解除'),
                          ),
                        TextButton(
                          child: const Text("変更"),
                          onPressed: () {
                            Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => const ExperimentsScreen()));
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Consumer<MediaProvider>(
                  builder: (context, mediaProvider, _) => Card(
                    child: Column(
                      children: [
                        SwitchListTile(
                          title: const Text("10秒ごとの音声録音とアップロード"),
                          subtitle: const Text("セッション中に10秒間の音声を継続的に送信します"),
                          value: mediaProvider.enableAudioCapture,
                          onChanged: (value) {
                            mediaProvider.setEnableAudioCapture(value);
                          },
                        ),
                        SwitchListTile(
                          title: const Text("5秒時点の写真撮影とアップロード"),
                          subtitle: mediaProvider.cameraReady
                              ? const Text("セッションごとに撮影される画像の送信を切り替えます")
                              : const Text(
                                  "カメラが利用できないため画像は送信されません",
                                  style: TextStyle(color: Colors.orangeAccent),
                                ),
                          value: mediaProvider.enableImageCapture &&
                              mediaProvider.cameraReady,
                          onChanged: mediaProvider.cameraReady
                              ? (value) {
                                  mediaProvider.setEnableImageCapture(value);
                                }
                              : null,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  flex: 3,
                  child: EegMultiChannelChart(
                    data: bleProvider.displayData,
                    channelCount: bleProvider.channelCount,
                    sampleRate: BleProvider.sampleRate,
                    electrodes: bleProvider.deviceProfile?.electrodeConfigs,
                    channelQuality: analysisProvider.latestChannelQuality,
                  ),
                ),
                const SizedBox(height: 16),
                _buildActionButton(context, bleProvider, sessionProvider),
                const SizedBox(height: 8),
              ],
            ),
          ),
          // 画面下にオーバーレイする快不快パネル（通常は非表示，^で表示）
          Positioned.fill(
            child: IgnorePointer(
              ignoring: false,
              child: ValencePanel(data: bleProvider.valenceHistory),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton(
      BuildContext context, BleProvider ble, SessionProvider session) {
    if (!ble.isConnected) {
      return FloatingActionButton.extended(
        onPressed: () => ble.startScan(),
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
        label: const Text("外部セッションを終了"),
        icon: const Icon(Icons.stop),
        backgroundColor: Colors.red,
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        FloatingActionButton.extended(
          onPressed: _showSessionTypeDialog,
          label: const Text("セッション開始"),
          icon: const Icon(Icons.play_arrow),
          backgroundColor:
              session.isExperimentSelected ? Colors.green : Colors.blueGrey,
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

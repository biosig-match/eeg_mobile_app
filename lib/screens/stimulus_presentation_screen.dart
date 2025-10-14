import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:math';

import '../models/experiment.dart';
import '../models/session.dart';
import '../models/stimulus.dart';
import '../providers/session_provider.dart';
import '../providers/stimulus_provider.dart';
import 'session_summary_screen.dart';

// ★★★ エラー修正: enumをクラスの外 (トップレベル) に移動 ★★★
enum ScreenState { loading, ready, running, finished }

class StimulusPresentationScreen extends StatefulWidget {
  const StimulusPresentationScreen({super.key});

  @override
  State<StimulusPresentationScreen> createState() =>
      _StimulusPresentationScreenState();
}

class _StimulusPresentationScreenState
    extends State<StimulusPresentationScreen> {
  ScreenState _screenState = ScreenState.loading;
  String _loadingMessage = "刺激情報を準備中...";
  List<BaseStimulus> _presentationList = [];
  int _currentIndex = 0;
  Timer? _stimulusTimer;
  final Stopwatch _sessionStopwatch = Stopwatch();

  final List<Map<String, dynamic>> _eventLog = [];

  @override
  void initState() {
    super.initState();
    // initState内での非同期処理はWidgetsBinding.instance.addPostFrameCallbackを使用するとより安全
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _prepareStimuli();
      }
    });
  }

  Future<void> _prepareStimuli() async {
    // context.readはbuildメソッド外で安全に呼び出す
    final sessionProvider = context.read<SessionProvider>();
    final stimulusProvider = context.read<StimulusProvider>();
    final session = sessionProvider.currentSession;

    if (session == null) {
      _finishWithError("セッション情報が見つかりません。");
      return;
    }

    setState(() => _loadingMessage = "刺激リストを取得中...");
    Experiment? activeExperiment;

    if (session.type == SessionType.calibration) {
      _presentationList = await stimulusProvider.fetchCalibrationItems();
    } else {
      final experimentId = session.experimentId;
      if (experimentId == null || experimentId.isEmpty) {
        _finishWithError("実験が選択されていないため、アプリ内刺激を提示できません。");
        return;
      }

      activeExperiment = sessionProvider.experiments.firstWhere(
        (e) => e.id == experimentId,
        orElse: () => Experiment.empty(),
      );

      if (activeExperiment.id.isEmpty) {
        _finishWithError("指定された実験が見つかりません。");
        return;
      }

      _presentationList =
          await stimulusProvider.fetchExperimentStimuli(activeExperiment.id);
    }

    if (activeExperiment != null &&
        activeExperiment.presentationOrder == 'random') {
      _presentationList.shuffle(Random());
    }

    if (!mounted) return; // 非同期処理後にウィジェットが破棄されていないか確認

    if (_presentationList.isEmpty) {
      _finishWithError("提示する刺激がありません。");
      return;
    }

    final experimentIdForImages = session.experimentId;

    for (int i = 0; i < _presentationList.length; i++) {
      if (!mounted) return;
      setState(() => _loadingMessage =
          "画像をダウンロード中... (${i + 1}/${_presentationList.length})");
      final image =
          await stimulusProvider.getImage(
        _presentationList[i].fileName,
        experimentId: experimentIdForImages,
        isCalibration: session.type == SessionType.calibration,
      );
      if (image == null) {
        _finishWithError("${_presentationList[i].fileName}のダウンロードに失敗しました。");
        return;
      }
    }

    if (!mounted) return;
    setState(() {
      _screenState = ScreenState.ready;
    });
  }

  void _startPresentation() {
    setState(() {
      _screenState = ScreenState.running;
      _sessionStopwatch.start();
      _showNextStimulus();
    });
  }

  void _showNextStimulus() {
    if (_currentIndex >= _presentationList.length) {
      _finishPresentation();
      return;
    }

    final currentStimulus = _presentationList[_currentIndex];
    _eventLog.add({
      'onset': _sessionStopwatch.elapsedMilliseconds / 1000.0,
      'duration': 1.0,
      'trial_type': currentStimulus.trialType,
      'file_name': currentStimulus.fileName,
    });

    // 刺激表示タイマー (1秒表示 -> 1.5秒待機)
    _stimulusTimer = Timer(const Duration(seconds: 1), () {
      if (!mounted) return;
      // 待機時間（十字表示）のためにUIを更新
      setState(() {});
      _stimulusTimer = Timer(const Duration(milliseconds: 1500), () {
        if (!mounted) return;
        setState(() {
          _currentIndex++;
          _showNextStimulus();
        });
      });
    });
  }

  void _finishPresentation() {
    _sessionStopwatch.stop();
    _stimulusTimer?.cancel();

    final buffer = StringBuffer();
    buffer.writeln('onset,duration,trial_type,file_name');
    for (var row in _eventLog) {
      buffer.writeln(
          '${row['onset']},${row['duration']},"${row['trial_type']}","${row['file_name']}"');
    }
    final csvData = buffer.toString();

    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
            builder: (_) => SessionSummaryScreen(generatedCsvData: csvData)),
      );
    }
  }

  void _finishWithError(String message) {
    if (mounted) {
      context.read<SessionProvider>().endSessionAndUpload();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _stimulusTimer?.cancel();
    _sessionStopwatch.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: WillPopScope(
        // ★★★ 戻るボタンで意図せず画面を閉じるのを防ぐ ★★★
        onWillPop: () async => false,
        child: Center(
          child: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    switch (_screenState) {
      case ScreenState.loading:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            Text(_loadingMessage, style: const TextStyle(color: Colors.white)),
          ],
        );
      case ScreenState.ready:
        return ElevatedButton(
          style: ElevatedButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 32, vertical: 16)),
          onPressed: _startPresentation,
          child: const Text("刺激提示を開始", style: TextStyle(fontSize: 18)),
        );
      case ScreenState.running:
        if (_stimulusTimer?.isActive == true &&
            _currentIndex < _presentationList.length) {
          final stimulus = _presentationList[_currentIndex];
          // StimulusProviderは画像をキャッシュしているのでFutureBuilderは不要
          return Consumer<StimulusProvider>(
            builder: (context, stimulusProvider, child) {
              final imageBytes = stimulusProvider.getImage(stimulus.fileName);
              return FutureBuilder<Uint8List?>(
                future: imageBytes,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.done &&
                      snapshot.data != null) {
                    return Image.memory(snapshot.data!);
                  }
                  // 画像取得中も十字を表示
                  return const Icon(Icons.add, color: Colors.white, size: 64);
                },
              );
            },
          );
        } else {
          return const Icon(Icons.add, color: Colors.white, size: 64);
        }
      case ScreenState.finished:
        return const Text("セッション完了",
            style: TextStyle(color: Colors.white, fontSize: 24));
    }
  }
}

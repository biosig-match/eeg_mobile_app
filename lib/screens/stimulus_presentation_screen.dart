import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:math';

import '../models/experiment.dart';
import '../models/session.dart';
import '../models/stimulus.dart';
import '../providers/ble_provider.dart';
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
  final List<Uint8List> _stimulusImages = [];
  int _currentIndex = 0;
  bool _isStimulusVisible = false;
  bool _isCalibrationSession = false;
  String? _activeExperimentId;
  Timer? _stimulusTimer;
  final Stopwatch _sessionStopwatch = Stopwatch();

  final List<Map<String, dynamic>> _eventLog = [];

  static const Duration _stimulusDisplayDuration = Duration(seconds: 1);
  static const Duration _interStimulusInterval = Duration(milliseconds: 1500);
  static const double _triggerSquareSize = 80;

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
    _eventLog.clear();
    _stimulusImages.clear();
    _currentIndex = 0;
    _isStimulusVisible = false;
    _isCalibrationSession = session.type == SessionType.calibration;
    _activeExperimentId = session.experimentId;

    if (_isCalibrationSession) {
      _presentationList = await stimulusProvider.fetchCalibrationItems();
      debugPrint(
          '[StimulusPresentation] Calibration items fetched: ${_presentationList.length}');
    } else {
      final experimentId = _activeExperimentId;
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
      debugPrint(
          '[StimulusPresentation] Experiment stimuli fetched: experimentId=${activeExperiment.id}, count=${_presentationList.length}');
    }

    if (activeExperiment != null &&
        activeExperiment.presentationOrder == 'random') {
      _presentationList.shuffle(Random());
    }

    if (!mounted) return; // 非同期処理後にウィジェットが破棄されていないか確認

    if (_presentationList.isEmpty) {
      final providerError = stimulusProvider.errorMessage;
      debugPrint(
          '[StimulusPresentation] Received empty stimulus list. providerError=$providerError');
      _finishWithError(providerError.isNotEmpty
          ? "刺激が取得できません: $providerError"
          : "提示する刺激がありません。");
      return;
    }

    for (int i = 0; i < _presentationList.length; i++) {
      if (!mounted) return;
      setState(() => _loadingMessage =
          "画像をダウンロード中... (${i + 1}/${_presentationList.length})");
      final image =
          await stimulusProvider.getImage(
        _presentationList[i].fileName,
        experimentId: _isCalibrationSession ? null : _activeExperimentId,
        isCalibration: _isCalibrationSession,
      );
      if (image == null) {
        _finishWithError("${_presentationList[i].fileName}のダウンロードに失敗しました。");
        return;
      }
      _stimulusImages.add(image);
    }

    if (!mounted) return;
    setState(() {
      _screenState = ScreenState.ready;
    });
  }

  void _startPresentation() {
    if (_presentationList.isEmpty) return;
    _stimulusTimer?.cancel();
    _sessionStopwatch
      ..reset()
      ..start();
    setState(() {
      _screenState = ScreenState.running;
      _isStimulusVisible = false;
      _currentIndex = 0;
    });
    _presentStimulus();
  }

  int _triggerCodeForStimulus(BaseStimulus stimulus) {
    final normalized = stimulus.trialType.toLowerCase();
    if (normalized.contains('non') && normalized.contains('target')) {
      return 2;
    }
    if (normalized.contains('target')) {
      return 1;
    }
    if (normalized.contains('neutral')) {
      return 3;
    }
    return 1;
  }

  void _presentStimulus() {
    if (_currentIndex >= _presentationList.length) {
      _finishPresentation();
      return;
    }

    final currentStimulus = _presentationList[_currentIndex];
    final onsetSeconds = _sessionStopwatch.elapsedMilliseconds / 1000.0;
    final triggerValue = _triggerCodeForStimulus(currentStimulus);
    final event = <String, dynamic>{
      'onset': onsetSeconds,
      'duration': _stimulusDisplayDuration.inMilliseconds / 1000.0,
      'trial_type': currentStimulus.trialType,
      'file_name': currentStimulus.fileName,
      'value': triggerValue,
    };
    if (currentStimulus is Stimulus) {
      event['stimulus_id'] = currentStimulus.stimulusId;
    } else if (currentStimulus is CalibrationItem) {
      event['calibration_item_id'] = currentStimulus.itemId;
    }
    _eventLog.add(event);

    final bleProvider = context.read<BleProvider>();
    unawaited(bleProvider.sendStimulusTrigger(triggerValue));

    _stimulusTimer?.cancel();
    setState(() {
      _isStimulusVisible = true;
    });

    _stimulusTimer = Timer(_stimulusDisplayDuration, () {
      if (!mounted) return;
      setState(() {
        _isStimulusVisible = false;
      });
      _stimulusTimer = Timer(_interStimulusInterval, () {
        if (!mounted) return;
        setState(() {
          _currentIndex++;
        });
        _presentStimulus();
      });
    });
  }

  void _finishPresentation() {
    _sessionStopwatch.stop();
    _stimulusTimer?.cancel();

    final buffer = StringBuffer();
    buffer.writeln(
        'onset,duration,trial_type,file_name,stimulus_id,calibration_item_id,value');
    for (var row in _eventLog) {
      final trialType = row['trial_type']?.toString() ?? '';
      final fileName = row['file_name']?.toString() ?? '';
      final triggerValue = row['value']?.toString() ?? '';
      buffer.writeln(
          '${row['onset']},${row['duration']},"${_escapeCsv(trialType)}","${_escapeCsv(fileName)}",${row['stimulus_id'] ?? ''},${row['calibration_item_id'] ?? ''},"${_escapeCsv(triggerValue)}"');
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

  Widget _buildFixationCross() {
    return SizedBox(
      width: 120,
      height: 120,
      child: CustomPaint(
        painter: _FixationCrossPainter(),
      ),
    );
  }

  Widget _buildTriggerIndicator() {
    final fillColor = _isStimulusVisible ? Colors.white : Colors.black;
    return Container(
      width: _triggerSquareSize,
      height: _triggerSquareSize,
      decoration: BoxDecoration(
        color: fillColor,
        border: Border.all(color: Colors.white70, width: 2),
      ),
    );
  }

  String _escapeCsv(String value) => value.replaceAll('"', '""');

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
        final hasImage = _currentIndex < _stimulusImages.length;
        final centerWidget = (_isStimulusVisible && hasImage)
            ? Image.memory(
                _stimulusImages[_currentIndex],
                fit: BoxFit.contain,
              )
            : _buildFixationCross();
        return Stack(
          children: [
            Center(child: centerWidget),
            Positioned(
              left: 24,
              top: 48,
              child: _buildTriggerIndicator(),
            ),
          ],
        );
      case ScreenState.finished:
        return const Text("セッション完了",
            style: TextStyle(color: Colors.white, fontSize: 24));
    }
  }
}

class _FixationCrossPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = size.shortestSide * 0.08
      ..strokeCap = StrokeCap.round;
    final center = Offset(size.width / 2, size.height / 2);
    final halfLength = size.shortestSide / 2;
    canvas.drawLine(
      Offset(center.dx - halfLength, center.dy),
      Offset(center.dx + halfLength, center.dy),
      paint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - halfLength),
      Offset(center.dx, center.dy + halfLength),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

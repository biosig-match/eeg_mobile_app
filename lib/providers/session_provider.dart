import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../models/experiment.dart';
import '../models/session.dart';
import '../utils/config.dart';
import 'auth_provider.dart';

class SessionProvider with ChangeNotifier {
  final ServerConfig _config;
  final AuthProvider _authProvider;

  List<Experiment> _experiments = [];
  String? _selectedExperimentId;
  Session? _currentSession;

  String _statusMessage = "準備完了";

  List<Experiment> get experiments => _experiments;
  Experiment get selectedExperiment =>
      _experiments.firstWhere((e) => e.id == _selectedExperimentId,
          orElse: () => Experiment.empty());
  bool get isExperimentSelected =>
      _selectedExperimentId != null && _selectedExperimentId!.isNotEmpty;
  Session? get currentSession => _currentSession;
  bool get isSessionRunning => _currentSession?.state == SessionState.running;
  String get statusMessage => _statusMessage;

  SessionProvider(this._config, this._authProvider) {
    fetchExperiments();
  }

  Future<void> fetchExperiments() async {
    if (!_authProvider.isAuthenticated) return;
    _statusMessage = "実験リストを読込中...";
    notifyListeners();
    try {
      final url = Uri.parse('${_config.httpBaseUrl}/api/v1/experiments');
      final response =
          await http.get(url, headers: {'X-User-Id': _authProvider.userId!});
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(utf8.decode(response.bodyBytes));
        _experiments = data.map((json) => Experiment.fromJson(json)).toList();
        if (_experiments.isEmpty) {
          _statusMessage = "参加中の実験がありません。フリーセッションを開始するか、新しい実験を作成してください";
        } else if (_selectedExperimentId == null) {
          _statusMessage = "実験を選択するか、フリーセッションを開始できます";
        } else {
          _statusMessage = "'${selectedExperiment.name}' が選択されています";
        }
      } else {
        throw Exception('実験リストの取得に失敗: ${response.statusCode}');
      }
    } catch (e) {
      _statusMessage = "エラー: $e";
    }
    notifyListeners();
  }

  // ★★★ 要件①: 実験作成機能の修正 ★★★
  Future<void> createExperiment({
    required String name,
    required String description,
    required String presentationOrder,
    File? stimuliCsvFile,
    List<File>? stimuliImageFiles,
  }) async {
    if (!_authProvider.isAuthenticated) return;
    _statusMessage = "新規実験を作成中...";
    notifyListeners();

    try {
      // 1. 実験オブジェクトの作成
      final urlExp = Uri.parse('${_config.httpBaseUrl}/api/v1/experiments');
      final expResponse = await http.post(
        urlExp,
        headers: {
          'Content-Type': 'application/json',
          'X-User-Id': _authProvider.userId!,
        },
        body: jsonEncode({
          "name": name,
          "description": description,
          "presentation_order": presentationOrder,
        }),
      );

      if (expResponse.statusCode != 201) {
        throw Exception('実験の作成に失敗: ${expResponse.body}');
      }
      final newExp = jsonDecode(expResponse.body);
      final newExperimentId = newExp['experiment_id'];

      // 2. 刺激ファイルのアップロード (ファイルが指定されている場合)
      if (stimuliCsvFile != null &&
          stimuliImageFiles != null &&
          stimuliImageFiles.isNotEmpty) {
        _statusMessage = "刺激ファイルをアップロード中...";
        notifyListeners();
        final urlStimuli = Uri.parse(
            '${_config.httpBaseUrl}/api/v1/experiments/$newExperimentId/stimuli');
        var request = http.MultipartRequest('POST', urlStimuli);
        request.headers['X-User-Id'] = _authProvider.userId!;

        request.files.add(await http.MultipartFile.fromPath(
          'stimuli_definition_csv',
          stimuliCsvFile.path,
          filename: p.basename(stimuliCsvFile.path),
        ));

        for (var file in stimuliImageFiles) {
          request.files.add(await http.MultipartFile.fromPath(
            'stimulus_files',
            file.path,
            filename: p.basename(file.path),
          ));
        }
        final response = await request.send();
        if (response.statusCode != 202) {
          final respStr = await response.stream.bytesToString();
          throw Exception('刺激ファイルのアップロードに失敗: $respStr');
        }
      }

      await fetchExperiments(); // リストを再取得してUIを更新
      _selectedExperimentId = newExperimentId;
      _statusMessage = "'${selectedExperiment.name}' を作成して選択しました";
    } catch (e) {
      _statusMessage = "エラー: $e";
    } finally {
      notifyListeners();
    }
  }

  void selectExperiment(String experimentId) {
    _selectedExperimentId = experimentId;
    _statusMessage = "'${selectedExperiment.name}' が選択されました";
    notifyListeners();
  }

  void deselectExperiment() {
    _selectedExperimentId = null;
    _statusMessage = "フリーセッションモードです";
    notifyListeners();
  }

  // --- セッション管理 ---
  Future<void> startSession({
    required SessionType type,
    required String deviceId,
    required Map<String, dynamic>? clockOffsetInfo,
  }) async {
    if (isSessionRunning || !_authProvider.isAuthenticated) return;

    final creationTime = DateTime.now().toUtc();
    final sessionId =
        '${type.toString().split(".").last}-${creationTime.millisecondsSinceEpoch}';

    final experimentId = _selectedExperimentId;

    _currentSession = Session(
      id: sessionId,
      userId: _authProvider.userId!,
      experimentId: experimentId,
      deviceId: deviceId,
      startTime: creationTime,
      type: type,
      clockOffsetInfo: clockOffsetInfo,
    );
    _statusMessage = experimentId == null || experimentId.isEmpty
        ? "フリーセッションを開始しています..."
        : "セッション開始をサーバーに通知中...";
    notifyListeners();

    try {
      final url = Uri.parse('${_config.httpBaseUrl}/api/v1/sessions/start');
      // [修正点] payload の型を Map<String, dynamic> として明示的に宣言
      final Map<String, dynamic> payload = {
        'session_id': _currentSession!.id,
        'user_id': _currentSession!.userId,
        'start_time': _currentSession!.startTime.toIso8601String(),
        'session_type': _currentSession!.type.toString().split('.').last,
      };

      if (experimentId != null && experimentId.isNotEmpty) {
        payload['experiment_id'] = experimentId;
      }
      if (clockOffsetInfo != null && clockOffsetInfo.isNotEmpty) {
        // この行でエラーが発生しなくなります
        payload['clock_offset_info'] = clockOffsetInfo;
      }

      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'X-User-Id': _authProvider.userId!,
        },
        body: jsonEncode(payload),
      );

      if (response.statusCode != 201) {
        _currentSession = null;
        throw Exception("セッション開始に失敗: ${response.body}");
      }
      _statusMessage = "セッション実行中...";
    } catch (e) {
      _currentSession = null;
      _statusMessage = "エラー: $e";
    }
    notifyListeners();
  }

  // ★★★ 要件④, ⑤: セッション終了とアップロード機能の改修 ★★★
  Future<void> endSessionAndUpload(
      {String? eventCsvString, PlatformFile? eventCsvFile}) async {
    if (!isSessionRunning || _currentSession == null) return;

    _currentSession!.endSession();
    _statusMessage = "セッション情報をアップロード中...";
    notifyListeners();

    final url = Uri.parse('${_config.httpBaseUrl}/api/v1/sessions/end');
    try {
      var request = http.MultipartRequest('POST', url);
      request.headers['X-User-Id'] = _authProvider.userId!;

      // metadataパート: JSONを文字列として送信
      request.fields['metadata'] = jsonEncode(_currentSession!.toJson());

      // events_log_csvパート: 文字列またはファイルから作成
      if (eventCsvString != null) {
        request.files.add(http.MultipartFile.fromString(
          'events_log_csv',
          eventCsvString,
          filename: 'events.csv',
        ));
      } else if (eventCsvFile != null && eventCsvFile.path != null) {
        request.files.add(await http.MultipartFile.fromPath(
          'events_log_csv',
          eventCsvFile.path!,
          filename: p.basename(eventCsvFile.path!),
        ));
      }

      final response = await request.send();
      if (response.statusCode == 200) {
        _statusMessage = "セッションが正常に終了しました。";
      } else {
        final respStr = await response.stream.bytesToString();
        throw Exception('アップロード失敗: $respStr');
      }
    } catch (e) {
      _statusMessage = "エラー: $e";
      // 失敗してもセッションは終了させる
    } finally {
      _currentSession = null;
      notifyListeners();
    }
  }
}

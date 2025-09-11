import 'dart:convert';
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
  Experiment? get selectedExperiment =>
      _experiments.firstWhere((e) => e.id == _selectedExperimentId,
          orElse: () => Experiment.empty());
  bool get isExperimentSelected => _selectedExperimentId != null;
  Session? get currentSession => _currentSession;
  bool get isSessionRunning => _currentSession?.state == SessionState.running;
  String get statusMessage => _statusMessage;

  SessionProvider(this._config, this._authProvider) {
    fetchExperiments();
  }

  // --- 実験管理 (変更なし) ---
  Future<void> fetchExperiments() async {
    // ... (no changes in this method)
    _statusMessage = "実験リストを読込中...";
    notifyListeners();
    try {
      final url = Uri.parse('${_config.httpBaseUrl}/api/v1/experiments');
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        _experiments = data.map((json) => Experiment.fromJson(json)).toList();
        _statusMessage = "実験を選択してください";
      } else {
        throw Exception('実験リストの取得に失敗: ${response.statusCode}');
      }
    } catch (e) {
      _statusMessage = "エラー: $e";
    }
    notifyListeners();
  }

  Future<void> createExperiment(
      {required String name, required String description}) async {
    // ... (no changes in this method)
    final url = Uri.parse('${_config.httpBaseUrl}/api/v1/experiments');
    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "name": name,
          "description": description,
          "settings": {"visibility": "public"}
        }),
      );
      if (response.statusCode == 201) {
        // Created
        await fetchExperiments(); // リストを再取得
      } else {
        throw Exception('実験の作成に失敗: ${response.body}');
      }
    } catch (e) {
      _statusMessage = "エラー: $e";
      notifyListeners();
    }
  }

  void selectExperiment(String experimentId) {
    _selectedExperimentId = experimentId;
    _statusMessage = "'${selectedExperiment?.name}' が選択されました";
    notifyListeners();
  }

  void deselectExperiment() {
    _selectedExperimentId = null;
    notifyListeners();
  }

  // --- セッション管理 (変更あり) ---
  void startSession({
    required SessionType type,
    required String deviceId, // ★★★ 引数にdeviceIdを追加 ★★★
  }) {
    if (isSessionRunning ||
        !isExperimentSelected ||
        _authProvider.userId == null) return;

    final creationTime = DateTime.now().toUtc();
    final sessionId =
        '${_authProvider.userId}-${creationTime.millisecondsSinceEpoch}';

    _currentSession = Session(
      id: sessionId,
      userId: _authProvider.userId!,
      experimentId: _selectedExperimentId!,
      deviceId: deviceId, // ★★★ 受け取ったdeviceIdをセット ★★★
      startTime: creationTime,
      type: type,
    );
    _statusMessage = "セッション実行中...";
    notifyListeners();
  }

  Future<void> endSessionAndUpload({PlatformFile? eventCsvFile}) async {
    // ★★★ このメソッドは endSessionAndUpload を呼び出すだけなので変更不要 ★★★
    if (!isSessionRunning || _currentSession == null) return;

    _currentSession!.endSession();
    _statusMessage = "セッション情報をアップロード中...";
    notifyListeners();

    final url = Uri.parse('${_config.httpBaseUrl}/api/v1/sessions/end');
    try {
      var request = http.MultipartRequest('POST', url);

      request.files.add(http.MultipartFile.fromString(
        'metadata',
        jsonEncode(_currentSession!.toJson()),
        filename: 'metadata.json',
      ));

      if (eventCsvFile != null && eventCsvFile.path != null) {
        request.files.add(await http.MultipartFile.fromPath(
          'events_file',
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
    } finally {
      _currentSession = null;
      notifyListeners();
    }
  }
}

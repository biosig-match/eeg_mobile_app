import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import '../../utils/config.dart';

enum ExperimentState { idle, running, error }

class ExperimentProvider with ChangeNotifier {
  final ServerConfig _config;
  ExperimentProvider(this._config);

  String? _experimentId;
  ExperimentState _state = ExperimentState.idle;
  String _statusMessage = "実験は開始されていません";

  String? get experimentId => _experimentId;
  ExperimentState get state => _state;
  String get statusMessage => _statusMessage;
  bool get isRunning => _state == ExperimentState.running;

  Future<void> startExperiment({
    required String participantId, 
    required String deviceId,
  }) async {
    if (isRunning) return;
    _updateState(ExperimentState.running, "実験を開始しています...");

    final url = Uri.parse('${_config.httpBaseUrl}/api/v1/experiments');
    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "participant_id": participantId,
          "device_id": deviceId,
          "metadata": {
            "task_name": "erpTask",
            "sampling_rate": 256,
            "channel_names": ["Fp1", "Fp2", "F7", "F8", "T7", "T8", "P7", "P8"]
          }
        }),
      );

      if (response.statusCode == 201) {
        final body = jsonDecode(response.body);
        _experimentId = body['experiment_id'];
        _updateState(ExperimentState.running, "実験進行中... (ID: ${_experimentId!.substring(0, 8)})");
      } else {
        throw Exception('実験の開始に失敗: ${response.body}');
      }
    } catch (e) {
      _updateState(ExperimentState.error, "エラー: $e");
    }
  }

  Future<void> stopAndUploadEvents() async {
    if (!isRunning || _experimentId == null) return;
    
    // 1. ユーザーにイベントCSVファイルを選択させる
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );

    if (result != null && result.files.single.path != null) {
      _updateState(ExperimentState.running, "イベントファイルをアップロード中...");
      final url = Uri.parse('${_config.httpBaseUrl}/api/v1/experiments/$_experimentId/events');
      try {
        var request = http.MultipartRequest('POST', url)
          ..files.add(await http.MultipartFile.fromPath(
            'file',
            result.files.single.path!,
          ));
        
        final response = await request.send();
        if (response.statusCode == 200) {
           _updateState(ExperimentState.idle, "実験は正常に終了し、データはアップロードされました。");
        } else {
          final respStr = await response.stream.bytesToString();
          throw Exception('アップロード失敗: $respStr');
        }
      } catch (e) {
        _updateState(ExperimentState.error, "エラー: $e");
        return; // エラー時は状態をリセットしない
      }
    } else {
      // ファイル選択がキャンセルされた場合
      _updateState(ExperimentState.running, "ファイルの選択がキャンセルされました。実験は継続中です。");
      return;
    }
    _reset();
  }
  
  void _updateState(ExperimentState state, String message) {
    _state = state;
    _statusMessage = message;
    notifyListeners();
  }
  
  void _reset() {
    _experimentId = null;
    _state = ExperimentState.idle;
  }
}
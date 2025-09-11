import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../utils/config.dart';
import 'auth_provider.dart';

class AnalysisResult {
  final Uint8List? psdImage;
  final Uint8List? coherenceImage;
  AnalysisResult({this.psdImage, this.coherenceImage});
}

class AnalysisProvider with ChangeNotifier {
  final ServerConfig _config;
  final AuthProvider _authProvider;

  Timer? _pollingTimer;
  AnalysisResult? _latestAnalysis;
  String _analysisStatus = "解析画面で結果を表示します";
  bool _isFetching = false;
  bool _isPollingActive = false; // ポーリング制御フラグ

  AnalysisResult? get latestAnalysis => _latestAnalysis;
  String get analysisStatus => _analysisStatus;

  AnalysisProvider(this._config, this._authProvider);

  // UI側からポーリングを開始/停止するためのメソッド
  void setPolling(bool active) {
    if (active && !_isPollingActive) {
      _isPollingActive = true;
      _analysisStatus = "サーバーからの解析結果を待っています...";
      notifyListeners();
      _startPolling();
    } else if (!active && _isPollingActive) {
      _isPollingActive = false;
      _stopPolling();
      _analysisStatus = "解析画面で結果を表示します";
      _latestAnalysis = null; // 画面を離れたら結果をクリア
      notifyListeners();
    }
  }

  void _startPolling() {
    _stopPolling();
    fetchLatestResults(); // すぐに一度取得
    _pollingTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      fetchLatestResults();
    });
  }

  void _stopPolling() {
    _pollingTimer?.cancel();
  }

  Future<void> fetchLatestResults() async {
    if (_isFetching || !_authProvider.isAuthenticated) return;
    _isFetching = true;

    try {
      final url = Uri.parse(
          '${_config.httpBaseUrl}/api/v1/users/${_authProvider.userId}/analysis');
      final response = await http.get(url).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final results = jsonDecode(response.body);
        _latestAnalysis = AnalysisResult(
          psdImage: results['psd_image'] != null
              ? base64Decode(results['psd_image'])
              : null,
          coherenceImage: results['coherence_image'] != null
              ? base64Decode(results['coherence_image'])
              : null,
        );
        _analysisStatus =
            "解析結果を更新しました (${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')})";
      } else {
        _analysisStatus = "サーバーエラー: ${response.statusCode}";
        _latestAnalysis = null;
      }
    } catch (e) {
      _analysisStatus = "解析サーバーへの接続に失敗";
      _latestAnalysis = null;
    } finally {
      _isFetching = false;
      if (_isPollingActive) {
        // ポーリングが有効な場合のみ通知
        notifyListeners();
      }
    }
  }
}

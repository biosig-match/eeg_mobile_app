import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../utils/config.dart'; // ★★★

class AnalysisResult {
  final Uint8List? psdImage;
  final Uint8List? coherenceImage;
  AnalysisResult({this.psdImage, this.coherenceImage});
}

class AnalysisProvider with ChangeNotifier {
  // ★★★ ServerConfigを受け取るように修正 ★★★
  final ServerConfig _config;
  AnalysisProvider(this._config);

  Timer? _pollingTimer;
  AnalysisResult? _latestAnalysis;
  String _analysisStatus = "サーバーからの解析結果を待っています...";
  bool _isFetching = false;

  AnalysisResult? get latestAnalysis => _latestAnalysis;
  String get analysisStatus => _analysisStatus;

  void startPolling() {
    stopPolling();
    fetchLatestResults();
    _pollingTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      fetchLatestResults();
    });
  }

  void stopPolling() {
    _pollingTimer?.cancel();
  }

  Future<void> fetchLatestResults() async {
    if (_isFetching) return;
    _isFetching = true;

    try {
      // ★★★ _config.httpBaseUrl を使用 ★★★
      final url = Uri.parse('${_config.httpBaseUrl}/api/v1/analysis/results');
      final response = await http.get(url).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final results = jsonDecode(response.body);
        _latestAnalysis = AnalysisResult(
          psdImage: results['psd_image'] != null ? base64Decode(results['psd_image']) : null,
          coherenceImage: results['coherence_image'] != null ? base64Decode(results['coherence_image']) : null,
        );
        _analysisStatus = "解析結果を更新しました (${DateTime.now().toIso8601String()})";
      } else {
        _analysisStatus = "サーバーエラー: ${response.statusCode}";
      }
    } catch (e) {
      _analysisStatus = "解析サーバーへの接続に失敗";
    } finally {
      _isFetching = false;
      notifyListeners();
    }
  }
}
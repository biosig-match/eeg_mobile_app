import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../models/erp_analysis_result.dart';
import '../utils/config.dart';
import 'auth_provider.dart';

class ErpAnalysisProvider with ChangeNotifier {
  final ServerConfig _config;
  final AuthProvider _authProvider;

  final Map<String, ErpAnalysisResult> _results = {};
  bool _isLoading = false;
  String _statusMessage = '';

  ErpAnalysisProvider(this._config, this._authProvider);

  bool get isLoading => _isLoading;
  String get statusMessage => _statusMessage;

  ErpAnalysisResult? getLatest(String experimentId) => _results[experimentId];

  Future<void> fetchLatestResults(String experimentId) async {
    if (!_authProvider.isAuthenticated) return;
    _isLoading = true;
    _statusMessage = '最新の結果を取得しています...';
    notifyListeners();

    try {
      final url = Uri.parse(
          '${_config.httpBaseUrl}/api/v1/neuro-marketing/experiments/$experimentId/analysis-results');
      final response = await http.get(url, headers: _authProvider.headers);

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        final result = ErpAnalysisResult.fromJson(data);
        _results[experimentId] = result;
        _statusMessage = '最新の結果を取得しました。';
      } else if (response.statusCode == 404) {
        _results.remove(experimentId);
        _statusMessage = 'この実験の分析結果はまだありません。';
      } else {
        throw Exception('結果の取得に失敗: ${response.statusCode}');
      }
    } catch (e) {
      _statusMessage = 'エラー: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> requestAnalysis(String experimentId) async {
    if (!_authProvider.isAuthenticated) return;
    _isLoading = true;
    _statusMessage = '解析をリクエストしています...';
    notifyListeners();

    try {
      final url = Uri.parse(
          '${_config.httpBaseUrl}/api/v1/neuro-marketing/experiments/$experimentId/analyze');
      final response = await http.post(url, headers: _authProvider.headers);

      if (response.statusCode == 200) {
        _statusMessage = '解析を開始しました。最新の結果を取得しています...';
        await fetchLatestResults(experimentId);
        return;
      } else {
        final body = response.body.isNotEmpty ? response.body : '';
        throw Exception('解析のリクエストに失敗: ${response.statusCode} $body');
      }
    } catch (e) {
      _statusMessage = 'エラー: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void clear() {
    _results.clear();
    _statusMessage = '';
    notifyListeners();
  }
}

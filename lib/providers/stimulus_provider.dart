import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../models/stimulus.dart';
import '../utils/config.dart';
import 'auth_provider.dart';

class StimulusProvider with ChangeNotifier {
  final ServerConfig _config;
  final AuthProvider _authProvider;

  // ダウンロードした画像をメモリにキャッシュ
  final Map<String, Uint8List> _imageCache = {};
  bool _isLoading = false;
  String _errorMessage = '';

  bool get isLoading => _isLoading;
  String get errorMessage => _errorMessage;

  StimulusProvider(this._config, this._authProvider);

  // キャッシュから画像を取得、なければダウンロード
  Future<Uint8List?> getImage(String filename) async {
    if (_imageCache.containsKey(filename)) {
      return _imageCache[filename];
    }
    return await _downloadStimulusImage(filename);
  }

  // 実験用の刺激メタデータリストを取得
  Future<List<Stimulus>> fetchExperimentStimuli(String experimentId) async {
    if (!_authProvider.isAuthenticated) return [];
    _setLoading(true);
    try {
      final url = Uri.parse(
          '${_config.httpBaseUrl}/api/v1/experiments/$experimentId/stimuli');
      final response =
          await http.get(url, headers: {'X-User-Id': _authProvider.userId!});

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(utf8.decode(response.bodyBytes));
        return data.map((json) => Stimulus.fromJson(json)).toList();
      } else {
        throw Exception('刺激リストの取得に失敗: ${response.statusCode}');
      }
    } catch (e) {
      _setError(e.toString());
      return [];
    } finally {
      _setLoading(false);
    }
  }

  // キャリブレーション用の刺激メタデータリストを取得
  Future<List<CalibrationItem>> fetchCalibrationItems() async {
    if (!_authProvider.isAuthenticated) return [];
    _setLoading(true);
    try {
      final url = Uri.parse('${_config.httpBaseUrl}/api/v1/calibrations');
      final response =
          await http.get(url, headers: {'X-User-Id': _authProvider.userId!});

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(utf8.decode(response.bodyBytes));
        return data.map((json) => CalibrationItem.fromJson(json)).toList();
      } else {
        throw Exception('キャリブレーション項目の取得に失敗: ${response.statusCode}');
      }
    } catch (e) {
      _setError(e.toString());
      return [];
    } finally {
      _setLoading(false);
    }
  }

  // サーバーから画像をダウンロードしてキャッシュに保存
  Future<Uint8List?> _downloadStimulusImage(String filename) async {
    if (!_authProvider.isAuthenticated) return null;
    _setLoading(true);
    try {
      final url =
          Uri.parse('${_config.httpBaseUrl}/api/v1/stimuli/download/$filename');
      final response = await http.get(url, headers: {
        'X-User-Id': _authProvider.userId!
      }).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final imageBytes = response.bodyBytes;
        _imageCache[filename] = imageBytes; // キャッシュに保存
        return imageBytes;
      } else {
        throw Exception('画像ダウンロード失敗: ${response.statusCode}');
      }
    } catch (e) {
      _setError('画像($filename)のダウンロードエラー: $e');
      return null;
    } finally {
      _setLoading(false);
    }
  }

  void _setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }

  void _setError(String message) {
    _errorMessage = message;
    notifyListeners();
  }
}

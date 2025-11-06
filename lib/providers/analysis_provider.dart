import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../utils/config.dart';
import 'auth_provider.dart';

class ChannelQualityStatus {
  final String status;
  final List<String> reasons;
  final double badImpedanceRatio;
  final double unknownImpedanceRatio;
  final double zeroRatio;
  final bool flatline;
  final bool hasWarning;
  final String type;

  const ChannelQualityStatus({
    required this.status,
    required this.reasons,
    required this.badImpedanceRatio,
    required this.unknownImpedanceRatio,
    required this.zeroRatio,
    required this.flatline,
    required this.hasWarning,
    required this.type,
  });

  factory ChannelQualityStatus.fromJson(Map<String, dynamic> json) {
    return ChannelQualityStatus(
      status: (json['status'] as String? ?? '').toLowerCase(),
      reasons: (json['reasons'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(growable: false),
      badImpedanceRatio:
          (json['bad_impedance_ratio'] as num?)?.toDouble() ?? 0.0,
      unknownImpedanceRatio:
          (json['unknown_impedance_ratio'] as num?)?.toDouble() ?? 0.0,
      zeroRatio: (json['zero_ratio'] as num?)?.toDouble() ?? 0.0,
      flatline: json['flatline'] == true,
      hasWarning: json['has_warning'] == true,
      type: (json['type'] as String? ?? '').toLowerCase(),
    );
  }
}

class AnalysisResult {
  final Uint8List? psdImage;
  final Uint8List? coherenceImage;
  final Map<String, ChannelQualityStatus> channelQuality;
  final List<String> badChannels;
  final List<String> analysisChannels;
  final DateTime? timestamp;

  AnalysisResult({
    this.psdImage,
    this.coherenceImage,
    Map<String, ChannelQualityStatus>? channelQuality,
    List<String>? badChannels,
    List<String>? analysisChannels,
    this.timestamp,
  })  : channelQuality = channelQuality == null
            ? const {}
            : Map.unmodifiable(channelQuality),
        badChannels = List.unmodifiable(badChannels ?? const []),
        analysisChannels = List.unmodifiable(analysisChannels ?? const []);
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
  Map<String, ChannelQualityStatus> get latestChannelQuality =>
      _latestAnalysis?.channelQuality ?? const {};
  List<String> get badChannels => _latestAnalysis?.badChannels ?? const [];
  List<String> get analysisChannels =>
      _latestAnalysis?.analysisChannels ?? const [];

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
    final previousStatus = _analysisStatus;
    final previousAnalysis = _latestAnalysis;
    bool shouldNotify = false;

    try {
      final url = Uri.parse(
          '${_config.httpBaseUrl}/api/v1/users/${_authProvider.userId}/analysis');
      final response = await http.get(url).timeout(const Duration(seconds: 5));

      if (response.statusCode == 202) {
        if (_analysisStatus != "解析結果を待機中...") {
          _analysisStatus = "解析結果を待機中...";
          shouldNotify = true;
        }
        if (_latestAnalysis != null) {
          _latestAnalysis = null;
          shouldNotify = true;
        }
        return;
      }

      if (response.statusCode == 200) {
        final payload = jsonDecode(response.body);
        final apps = payload['applications'];

        Map<String, dynamic>? selectedApp;
        if (apps is Map<String, dynamic>) {
          final psdApp = apps['psd_coherence'];
          if (psdApp is Map<String, dynamic>) {
            selectedApp = psdApp;
          } else if (apps.isNotEmpty) {
            final firstEntry = apps.entries
                .firstWhere(
                  (entry) => entry.value is Map<String, dynamic>,
                  orElse: () => MapEntry('', const {}),
                )
                .value;
            if (firstEntry is Map<String, dynamic>) {
              selectedApp = firstEntry;
            }
          }
        }

        if (selectedApp != null) {
          Uint8List? decodeImage(String? value) {
            if (value == null || value.trim().isEmpty) return null;
            try {
              return base64Decode(value);
            } catch (_) {
              return null;
            }
          }

          final analysisChannels =
              (selectedApp['analysis_channels'] as List<dynamic>? ?? const [])
                  .whereType<String>()
                  .map((value) => value.toUpperCase())
                  .toList(growable: false);

          final badChannels =
              (selectedApp['bad_channels'] as List<dynamic>? ?? const [])
                  .whereType<String>()
                  .map((value) => value.toUpperCase())
                  .toList(growable: false);

          final Map<String, ChannelQualityStatus> channelQuality = {};
          final rawChannelQuality = selectedApp['channel_quality'];
          if (rawChannelQuality is Map<String, dynamic>) {
            rawChannelQuality.forEach((key, value) {
              if (value is Map<String, dynamic>) {
                final normalizedKey = key.toString().toUpperCase();
                channelQuality[normalizedKey] =
                    ChannelQualityStatus.fromJson(value);
              }
            });
          }

          DateTime? timestamp;
          final ts = selectedApp['timestamp'];
          if (ts is String) {
            timestamp = DateTime.tryParse(ts);
          }

          _latestAnalysis = AnalysisResult(
            psdImage: decodeImage(selectedApp['psd_image'] as String?),
            coherenceImage:
                decodeImage(selectedApp['coherence_image'] as String?),
            channelQuality: channelQuality,
            badChannels: badChannels,
            analysisChannels: analysisChannels,
            timestamp: timestamp,
          );
          _analysisStatus =
              "解析結果を更新しました (${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')})";
          shouldNotify = true;
        } else {
          if (_analysisStatus != "解析結果がまだ生成されていません") {
            _analysisStatus = "解析結果がまだ生成されていません";
            shouldNotify = true;
          }
          if (_latestAnalysis != null) {
            _latestAnalysis = null;
            shouldNotify = true;
          }
        }
      } else {
        final nextStatus = "サーバーエラー: ${response.statusCode}";
        if (_analysisStatus != nextStatus) {
          _analysisStatus = nextStatus;
          shouldNotify = true;
        }
        if (_latestAnalysis != null) {
          _latestAnalysis = null;
          shouldNotify = true;
        }
      }
    } catch (e) {
      if (_analysisStatus != "解析サーバーへの接続に失敗") {
        _analysisStatus = "解析サーバーへの接続に失敗";
        shouldNotify = true;
      }
      if (_latestAnalysis != null) {
        _latestAnalysis = null;
        shouldNotify = true;
      }
    } finally {
      _isFetching = false;
      if (_isPollingActive ||
          shouldNotify ||
          previousStatus != _analysisStatus ||
          previousAnalysis != _latestAnalysis) {
        notifyListeners();
      }
    }
  }
}

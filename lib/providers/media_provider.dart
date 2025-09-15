import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:zstandard/zstandard.dart';

import '../utils/config.dart';
import 'auth_provider.dart';
import 'session_provider.dart';

class MediaProvider with ChangeNotifier {
  final ServerConfig _config;
  final AuthProvider _authProvider;
  final SessionProvider _sessionProvider;

  CameraController? _cameraController;
  final AudioRecorder _audioRecorder = AudioRecorder();
  Timer? _mediaTimer;
  bool _isInitialized = false;

  MediaProvider(this._config, this._authProvider, this._sessionProvider) {
    _sessionProvider.addListener(_onSessionStateChanged);
  }

  Future<void> initialize() async {
    if (_isInitialized) return;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        debugPrint("利用可能なカメラがありません。");
        return;
      }
      final firstCamera = cameras.first;
      _cameraController = CameraController(
        firstCamera,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await _cameraController!.initialize();
      _isInitialized = true;
    } catch (e) {
      debugPrint("メディアプロバイダーの初期化に失敗: $e");
    }
  }

  void _onSessionStateChanged() {
    if (_sessionProvider.isSessionRunning) {
      _startMediaCapture();
    } else {
      _stopMediaCapture();
    }
  }

  void _startMediaCapture() {
    if (!_isInitialized) return;
    _mediaTimer?.cancel();
    // 10秒ごとにキャプチャとアップロードを実行
    _mediaTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      _captureAndUpload();
    });
  }

  Future<void> _stopMediaCapture() async {
    _mediaTimer?.cancel();
    if (await _audioRecorder.isRecording()) {
      await _audioRecorder.stop();
    }
  }

  Future<void> _captureAndUpload() async {
    if (!_isInitialized || !_sessionProvider.isSessionRunning) return;

    // ★★★ 1. 音声録音開始時刻を記録 ★★★
    final audioStartTime = DateTime.now().toUtc();
    final audioTempPath = p.join((await Directory.systemTemp.createTemp()).path,
        'audio_${audioStartTime.millisecondsSinceEpoch}.m4a');

    await _audioRecorder.start(const RecordConfig(encoder: AudioEncoder.aacLc),
        path: audioTempPath);

    // 5秒待機して画像を撮影
    await Future.delayed(const Duration(seconds: 5));

    // ★★★ 2. 画像撮影時刻を記録 ★★★
    final imageTimestamp = DateTime.now().toUtc();
    final imageFile = await _cameraController?.takePicture();

    // さらに5秒待機して録音を終了
    await Future.delayed(const Duration(seconds: 5));

    // ★★★ 3. 音声録音終了時刻を記録 ★★★
    final audioEndTime = DateTime.now().toUtc();
    final audioPath = await _audioRecorder.stop();

    // 画像のアップロード
    if (imageFile != null) {
      final imageBytes = await imageFile.readAsBytes();
      await _uploadMedia(
        imageBytes,
        'image/jpeg',
        'photo.jpg',
        compress: true,
        timestamp: imageTimestamp, // ★★★ 撮影時刻を渡す
      );
    }

    // 音声のアップロード
    if (audioPath != null) {
      final audioFile = File(audioPath);
      if (await audioFile.exists()) {
        final audioBytes = await audioFile.readAsBytes();
        await _uploadMedia(
          audioBytes,
          'audio/m4a',
          'audio.m4a',
          compress: true,
          startTime: audioStartTime, // ★★★ 録音開始時刻を渡す
          endTime: audioEndTime, // ★★★ 録音終了時刻を渡す
        );
        await audioFile.delete(); // 一時ファイルを削除
      }
    }
  }

  // ★★★ 4. メソッドのシグネチャを修正し、タイムスタンプとメタデータを受け取る ★★★
  Future<void> _uploadMedia(
    Uint8List data,
    String contentType,
    String filename, {
    bool compress = false,
    DateTime? timestamp, // for images
    DateTime? startTime, // for audio
    DateTime? endTime, // for audio
  }) async {
    final session = _sessionProvider.currentSession;
    if (session == null || !_authProvider.isAuthenticated) return;

    final url = Uri.parse('${_config.httpBaseUrl}/api/v1/media');
    var request = http.MultipartRequest('POST', url);

    // ★★★ 5. 全てのメタデータをフォームフィールドとして追加 ★★★
    request.fields['user_id'] = _authProvider.userId!;
    request.fields['session_id'] = session.id;
    request.fields['original_filename'] = filename;
    request.fields['mimetype'] = contentType;

    // 画像用のタイムスタンプ
    if (timestamp != null) {
      request.fields['timestamp_utc'] = timestamp.toIso8601String();
    }
    // 音声用のタイムスタンプ
    if (startTime != null) {
      request.fields['start_time_utc'] = startTime.toIso8601String();
    }
    if (endTime != null) {
      request.fields['end_time_utc'] = endTime.toIso8601String();
    }

    final processedData = await _compressData(data, compress);

    request.files.add(http.MultipartFile.fromBytes(
      'file',
      processedData,
      filename: filename,
    ));

    try {
      final response =
          await request.send().timeout(const Duration(seconds: 15));
      if (response.statusCode == 202) {
        debugPrint("メディア($filename)のアップロード成功");
      } else {
        debugPrint("メディアのアップロード失敗: Status ${response.statusCode}");
      }
    } catch (e) {
      debugPrint("メディアのアップロード中にエラー: $e");
    }
  }

  Future<Uint8List> _compressData(Uint8List data, bool compress) async {
    if (compress) {
      final compressed = await data.compress();
      if (compressed != null) {
        return compressed;
      }
    }
    return data;
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _audioRecorder.dispose();
    _mediaTimer?.cancel();
    _sessionProvider.removeListener(_onSessionStateChanged);
    super.dispose();
  }
}

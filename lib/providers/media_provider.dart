import 'dart:async';
import 'dart:io'; // ★★★ ファイル操作のために追加 ★★★
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
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
      _cameraController = CameraController(firstCamera, ResolutionPreset.medium,
          enableAudio: false);
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
    _mediaTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      _captureAndUpload();
    });
  }

  // ★★★ Futureを返すようにし、async/awaitを追加 ★★★
  Future<void> _stopMediaCapture() async {
    _mediaTimer?.cancel();
    // ★★★ isRecording()はFuture<bool>を返すため、awaitする ★★★
    if (await _audioRecorder.isRecording()) {
      await _audioRecorder.stop();
    }
  }

  Future<void> _captureAndUpload() async {
    if (!_isInitialized || !_sessionProvider.isSessionRunning) return;

    // ★★★ RecordConfig()でエンコーダを指定 ★★★
    await _audioRecorder.start(const RecordConfig(encoder: AudioEncoder.aacLc),
        path: 'audio.m4a');

    await Future.delayed(const Duration(seconds: 5));
    final imageFile = await _cameraController?.takePicture();

    await Future.delayed(const Duration(seconds: 5));
    // ★★★ stop()は Future<String?> を返す ★★★
    final audioPath = await _audioRecorder.stop();

    if (imageFile != null) {
      final imageBytes = await imageFile.readAsBytes();
      await _uploadMedia(imageBytes, 'image/jpeg', 'photo.jpg', compress: true);
    }

    // ★★★ audioPathがnullでないことを確認し、ファイルを読み込む ★★★
    if (audioPath != null) {
      final audioBytes = await File(audioPath).readAsBytes();
      await _uploadMedia(audioBytes, 'audio/m4a', 'audio.m4a', compress: true);
    }
  }

  Future<void> _uploadMedia(Uint8List data, String contentType, String filename,
      {bool compress = false}) async {
    final session = _sessionProvider.currentSession;
    if (session == null || !_authProvider.isAuthenticated) return;

    final url = Uri.parse('${_config.httpBaseUrl}/api/v1/media');
    var request = http.MultipartRequest('POST', url);
    request.fields['user_id'] = _authProvider.userId!;
    request.fields['session_id'] = session.id;

    final processedData = await _compressData(data, compress);

    request.files.add(http.MultipartFile.fromBytes(
      'file',
      processedData,
      filename: filename,
    ));

    try {
      await request.send();
    } catch (e) {
      debugPrint("メディアのアップロードに失敗: $e");
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

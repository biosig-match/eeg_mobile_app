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
  AuthProvider _authProvider;
  SessionProvider _sessionProvider;

  CameraController? _cameraController;
  final AudioRecorder _audioRecorder = AudioRecorder();
  bool _isInitialized = false;
  bool _cameraReady = false;
  bool _captureLoopActive = false;
  bool _isCaptureLoopRunning = false;
  bool _enableAudioCapture = true;
  bool _enableImageCapture = true;

  MediaProvider(this._config, this._authProvider, this._sessionProvider) {
    _sessionProvider.addListener(_onSessionStateChanged);
  }

  void updateDependencies(AuthProvider authProvider, SessionProvider sessionProvider) {
    _authProvider = authProvider;
    if (!identical(_sessionProvider, sessionProvider)) {
      _sessionProvider.removeListener(_onSessionStateChanged);
      _sessionProvider = sessionProvider;
      _sessionProvider.addListener(_onSessionStateChanged);
      _onSessionStateChanged();
    }
  }

  bool get isInitialized => _isInitialized;
  bool get cameraReady => _cameraReady;
  bool get enableAudioCapture => _enableAudioCapture;
  bool get enableImageCapture => _enableImageCapture;

  Future<void> setEnableAudioCapture(bool value) async {
    if (_enableAudioCapture == value) return;
    _enableAudioCapture = value;
    if (!_enableAudioCapture && await _audioRecorder.isRecording()) {
      await _audioRecorder.stop();
    }
    if (_sessionProvider.isSessionRunning) {
      if (_enableAudioCapture || _enableImageCapture) {
        unawaited(_startMediaCapture());
      } else {
        unawaited(_stopMediaCapture());
      }
    }
    notifyListeners();
  }

  Future<void> setEnableImageCapture(bool value) async {
    if (_enableImageCapture == value) return;
    if (value && !_cameraReady) {
      await initialize();
    }
    _enableImageCapture = value && _cameraReady;
    if (_sessionProvider.isSessionRunning) {
      if (_enableAudioCapture || _enableImageCapture) {
        unawaited(_startMediaCapture());
      } else {
        unawaited(_stopMediaCapture());
      }
    }
    notifyListeners();
  }

  Future<void> initialize() async {
    if (_isInitialized && (_cameraController != null || !_enableImageCapture)) {
      return;
    }
    try {
      final cameras = await availableCameras();
      if (cameras.isNotEmpty) {
        _cameraController?.dispose();
        final firstCamera = cameras.first;
        _cameraController = CameraController(
          firstCamera,
          ResolutionPreset.medium,
          enableAudio: false,
        );
        await _cameraController!.initialize();
        _cameraReady = true;
      } else {
        _cameraReady = false;
        debugPrint("利用可能なカメラがありません。");
      }
    } catch (e) {
      _cameraController?.dispose();
      _cameraController = null;
      _cameraReady = false;
      debugPrint("メディアプロバイダーの初期化に失敗: $e");
    } finally {
      _isInitialized = true;
      notifyListeners();
    }
  }

  void _onSessionStateChanged() {
    if (_sessionProvider.isSessionRunning) {
      unawaited(_startMediaCapture());
    } else {
      unawaited(_stopMediaCapture());
    }
  }

  Future<void> _startMediaCapture() async {
    if (!_enableAudioCapture && !_enableImageCapture) return;
    if (!_isInitialized) {
      await initialize();
    }
    if (_captureLoopActive) return;
    _captureLoopActive = true;
    unawaited(_runCaptureLoop());
  }

  Future<void> _stopMediaCapture() async {
    _captureLoopActive = false;
    if (await _audioRecorder.isRecording()) {
      try {
        await _audioRecorder.stop();
      } catch (e) {
        debugPrint("録音停止中にエラー: $e");
      }
    }
  }

  Future<void> _runCaptureLoop() async {
    if (_isCaptureLoopRunning) return;
    _isCaptureLoopRunning = true;
    while (_captureLoopActive && _sessionProvider.isSessionRunning) {
      await _executeCaptureCycle();
    }
    _isCaptureLoopRunning = false;
  }

  Future<void> _executeCaptureCycle() async {
    if (!_sessionProvider.isSessionRunning) return;

    final bool captureAudio = _enableAudioCapture;
    final bool captureImage =
        _enableImageCapture && _cameraController != null && _cameraController!.value.isInitialized;

    Directory? audioTempDir;
    String? audioTempPath;
    DateTime? audioStartUtc;
    DateTime? audioEndUtc;
    DateTime? audioStartLocal;

    if (captureAudio) {
      if (await _audioRecorder.isRecording()) {
        await _audioRecorder.stop();
      }
      audioTempDir = await Directory.systemTemp
          .createTemp('audio_chunk_${DateTime.now().millisecondsSinceEpoch}');
      audioStartLocal = DateTime.now();
      audioStartUtc = audioStartLocal.toUtc();
      audioTempPath =
          p.join(audioTempDir.path, 'audio_${audioStartUtc.millisecondsSinceEpoch}.m4a');

      await _audioRecorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: audioTempPath,
      );
    }

    await Future.delayed(const Duration(seconds: 5));

    if (!_captureLoopActive || !_sessionProvider.isSessionRunning) {
      if (captureAudio && await _audioRecorder.isRecording()) {
        await _audioRecorder.stop();
      }
      return;
    }

    XFile? imageFile;
    DateTime? imageTimestampUtc;
    if (captureImage) {
      try {
        imageTimestampUtc = DateTime.now().toUtc();
        imageFile = await _cameraController!.takePicture();
      } catch (e) {
        debugPrint("画像撮影に失敗: $e");
      }
    }

    if (captureAudio) {
      final plannedEndLocal = audioStartLocal!.add(const Duration(seconds: 10));
      final now = DateTime.now();
      final remaining = plannedEndLocal.difference(now);
      if (remaining.inMilliseconds > 0) {
        await Future.delayed(remaining);
      }
    } else {
      await Future.delayed(const Duration(seconds: 5));
    }

    if (!_captureLoopActive || !_sessionProvider.isSessionRunning) {
      if (captureAudio && await _audioRecorder.isRecording()) {
        await _audioRecorder.stop();
      }
      return;
    }

    String? audioPath;
    if (captureAudio) {
      audioEndUtc = DateTime.now().toUtc();
      audioPath = await _audioRecorder.stop();
    }

    final List<Future<void>> uploads = [];

    if (captureImage && imageFile != null) {
      final imageBytes = await imageFile.readAsBytes();
      final imageFilename =
          'photo_${imageTimestampUtc?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch}.jpg';
      uploads.add(_uploadMedia(
        imageBytes,
        'image/jpeg',
        imageFilename,
        compress: true,
        timestamp: imageTimestampUtc,
      ));
      try {
        final imagePath = imageFile.path;
        if (imagePath != null && imagePath.isNotEmpty) {
          final tempImageFile = File(imagePath);
          if (await tempImageFile.exists()) {
            await tempImageFile.delete();
          }
        }
      } catch (_) {}
    }

    if (captureAudio && audioPath != null) {
      final audioFile = File(audioPath);
      if (await audioFile.exists()) {
        final audioBytes = await audioFile.readAsBytes();
        final audioFilename =
            'audio_${audioStartUtc?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch}.m4a';
        uploads.add(_uploadMedia(
          audioBytes,
          'audio/m4a',
          audioFilename,
          compress: true,
          startTime: audioStartUtc,
          endTime: audioEndUtc,
        ));
        await audioFile.delete();
      }
      if (audioTempDir != null && await audioTempDir.exists()) {
        await audioTempDir.delete(recursive: true);
      }
    }

    if (uploads.isNotEmpty) {
      unawaited(Future.wait(uploads).catchError(
        (error, stackTrace) => debugPrint("メディアアップロード待機中にエラー: $error"),
      ));
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
    _captureLoopActive = false;
    _cameraController?.dispose();
    _audioRecorder.dispose();
    _sessionProvider.removeListener(_onSessionStateChanged);
    super.dispose();
  }
}

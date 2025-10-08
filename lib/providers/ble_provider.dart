import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:bitstream/bitstream.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:zstandard/zstandard.dart';

import '../models/sensor_data.dart';
import '../utils/config.dart';
import 'auth_provider.dart';
import 'ble_provider_interface.dart';

enum DeviceType { customEeg, muse2, unknown }

class ElectrodeConfig {
  final String name;
  final int type;
  ElectrodeConfig({required this.name, required this.type});
}

class BleProvider with ChangeNotifier implements BleProviderInterface {
  final ServerConfig _config;
  final AuthProvider _authProvider;

  // --- BLE関連 ---
  BluetoothDevice? _targetDevice;
  DeviceType _deviceType = DeviceType.unknown;
  List<StreamSubscription> _valueSubscriptions = [];
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  BluetoothCharacteristic? _rxCharacteristic;
  bool _isConnected = false;
  String _statusMessage = "未接続";
  
  // --- デバイス設定 ---
  List<ElectrodeConfig> _electrodeConfigs = [];
  int _eegChannelCount = 0;

  // --- Muse 2 関連 ---
  static const museControlCharUuid = "273E0001-4C4D-454D-96BE-F03BAC821358";
  static const eegCharUuids = [
    "273E0003-4C4D-454D-96BE-F03BAC821358", "273E0004-4C4D-454D-96BE-F03BAC821358",
    "273E0005-4C4D-454D-96BE-F03BAC821358", "273E0006-4C4D-454D-96BE-F03BAC821358",
    "273E0007-4C4D-454D-96BE-F03BAC821358",
  ];
  final Map<String, int> _museUuidToIndex = {};
  final List<List<int>> _museEegBuffer = List.generate(5, (_) => []);
  int _museLastPacketIndex = -1;
  int _museSampleIndexCounter = 0;

  // --- データバッファリング ---
  static const int sampleRate = 256;
  static const double timeWindowSec = 5.0;
  static final int displayBufferSize = (sampleRate * timeWindowSec).toInt();
  final List<SensorDataPoint> _displayDataBuffer = [];
  final List<SensorDataPoint> _serverUploadBuffer = [];
  static const int samplesPerPayload = 128;
  final List<(DateTime, double)> _valenceHistory = [];

  // --- UI更新 ---
  bool _needsUiUpdate = false;
  Timer? _uiUpdateTimer;
  
  // ★★★ 変更点: スキャン状態管理用のタイマーを追加 ★★★
  Timer? _scanTimeoutTimer;

  // --- ゲッター ---
  @override
  bool get isConnected => _isConnected;
  @override
  String get statusMessage => _statusMessage;
  @override
  List<SensorDataPoint> get displayData => _displayDataBuffer;
  @override
  List<(DateTime, double)> get valenceHistory => _valenceHistory;
  @override
  String? get deviceId => _targetDevice?.remoteId.str;
  @override
  int get channelCount => _eegChannelCount;
  DeviceType get deviceType => _deviceType;

  BleProvider(this._config, this._authProvider) {
    _uiUpdateTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (_needsUiUpdate) {
        notifyListeners();
        _needsUiUpdate = false;
      }
    });
    for (int i = 0; i < eegCharUuids.length; i++) {
      _museUuidToIndex[eegCharUuids[i].toUpperCase()] = i;
    }
  }

  @override
  void dispose() {
    _uiUpdateTimer?.cancel();
    _scanTimeoutTimer?.cancel();
    _scanSubscription?.cancel();
    disconnect();
    super.dispose();
  }

  @override
  Future<void> startScan({DeviceType targetDeviceType = DeviceType.unknown}) async {
    if (_isConnected || FlutterBluePlus.isScanningNow) {
      debugPrint("[SCAN] Ignoring request: Already connected or a scan is in progress.");
      return;
    }

    _updateStatus("デバイスをスキャン中...");
    _deviceType = targetDeviceType;

    // 以前のスキャンリソースをクリーンアップ
    _scanTimeoutTimer?.cancel();
    await _scanSubscription?.cancel();

    // スキャン結果のリスナーをセット
    _scanSubscription = FlutterBluePlus.scanResults.listen(
      (results) {
        ScanResult? foundResult;
        for (ScanResult r in results) {
          final deviceName = r.device.platformName;
          if (deviceName.isEmpty) continue;

          bool isCustomDevice = deviceName.startsWith("EEG-Device");
          bool isMuse = deviceName.toLowerCase().contains("muse");

          if ((targetDeviceType == DeviceType.customEeg && isCustomDevice) ||
              (targetDeviceType == DeviceType.muse2 && isMuse) ||
              (targetDeviceType == DeviceType.unknown && (isCustomDevice || isMuse))) {
            foundResult = r;
            break;
          }
        }

        if (foundResult != null) {
          // デバイスが見つかったら、スキャン関連のリソースをすべて停止・破棄して接続処理へ
          _scanTimeoutTimer?.cancel();
          _scanSubscription?.cancel();
          FlutterBluePlus.stopScan();
          _connectToDevice(foundResult.device);
        }
      },
      onError: (e) {
        debugPrint("[SCAN] Error listening to scan results: $e");
        _updateStatus("スキャンエラー: $e");
      }
    );

    // タイムアウト用のタイマーを設定
    _scanTimeoutTimer = Timer(const Duration(seconds: 10), () {
      debugPrint("[SCAN] Scan timed out.");
      _scanSubscription?.cancel();
      FlutterBluePlus.stopScan();
      if (!_isConnected) {
         _updateStatus("デバイスが見つかりませんでした");
      }
    });
    await FlutterBluePlus.startScan(timeout: null);
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    _updateStatus("接続中: ${device.platformName}");
    _targetDevice = device;
    
    if (device.platformName.startsWith("EEG-Device")) {
      _deviceType = DeviceType.customEeg;
    } else if (device.platformName.toLowerCase().contains("muse")) {
      _deviceType = DeviceType.muse2;
    }

    // 接続状態の監視を開始
    _connectionStateSubscription = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _isConnected = false;
        _updateStatus("切断されました");
        _cleanUp();
        notifyListeners();
      }
    });

    try {
      await device.connect(timeout: const Duration(seconds: 15));
      _isConnected = true;
      notifyListeners();
      try { await device.requestMtu(512); } catch (e) { debugPrint("[BLE] MTU request failed: $e"); }
      await _setupServices(device);
    } catch (e) {
      _updateStatus("接続に失敗しました: $e");
      _cleanUp();
    }
  }
  
  Future<void> _setupServices(BluetoothDevice device) async {
    _updateStatus("サービスを検索中...");
    if (_deviceType == DeviceType.customEeg) {
      await _setupCustomEegServices(device);
    } else if (_deviceType == DeviceType.muse2) {
      await _setupMuse2Services(device);
    } else {
      _updateStatus("エラー: 未対応のデバイスです");
      await disconnect();
    }
  }

  Future<void> _setupCustomEegServices(BluetoothDevice device) async {
    try {
      final services = await device.discoverServices();
      BluetoothCharacteristic? txChar;
      for (var service in services) {
        if (service.uuid.toString().toUpperCase() == "6E400001-B5A3-F393-E0A9-E50E24DCCA9E") {
          for (var char in service.characteristics) {
            if (char.uuid.toString().toUpperCase() == "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") txChar = char;
            else if (char.uuid.toString().toUpperCase() == "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") _rxCharacteristic = char;
          }
        }
      }
      if (txChar != null && _rxCharacteristic != null) {
        await txChar.setNotifyValue(true);
        _valueSubscriptions.add(txChar.lastValueStream.listen(_onDataDispatcher));
        await _rxCharacteristic!.write([0xAA], withoutResponse: false);
        _updateStatus("接続完了: ${device.platformName}");
      } else {
        _updateStatus("エラー: 必要なキャラクタリスティックが見つかりません");
        await disconnect();
      }
    } catch (e) {
      _updateStatus("サービス検索エラー: $e");
      await disconnect();
    }
  }
  
  Future<void> _setupMuse2Services(BluetoothDevice device) async {
      try {
        final services = await device.discoverServices();
        BluetoothCharacteristic? controlChar;
        final Map<String, BluetoothCharacteristic> foundEegChars = {};
        for (var service in services) {
          for (var char in service.characteristics) {
            final charUuid = char.uuid.toString().toUpperCase();
            if (charUuid == museControlCharUuid.toUpperCase()) controlChar = char;
            else if (eegCharUuids.contains(charUuid)) foundEegChars[charUuid] = char;
          }
        }
        if (controlChar != null && foundEegChars.length >= 4) {
          _rxCharacteristic = controlChar;
          for (final char in foundEegChars.values) {
              await char.setNotifyValue(true);
              _valueSubscriptions.add(char.onValueReceived.listen((value) => _onDataDispatcher(value, charUuid: char.uuid.toString())));
          }
          _eegChannelCount = 4;
          _electrodeConfigs = [
            ElectrodeConfig(name: "TP9", type: 0), ElectrodeConfig(name: "AF7", type: 0),
            ElectrodeConfig(name: "AF8", type: 0), ElectrodeConfig(name: "TP10", type: 0),
          ];
          await _sendMuseCommand('p21');
          await _sendMuseCommand('s');
          await _sendMuseCommand('d');
          _updateStatus("接続完了: ${device.platformName}");
        } else {
          _updateStatus("エラー: Muse 2の必要なキャラクタリスティックが見つかりません");
          await disconnect();
        }
      } catch(e) {
        _updateStatus("Muse 2のサービス検索エラー: $e");
        await disconnect();
      }
  }

  void _onDataDispatcher(List<int> data, {String? charUuid}) {
    if (data.isEmpty) return;
    if (_deviceType == DeviceType.customEeg) {
      final packetType = data[0];
      if (packetType == 0xDD) {
        _handleDeviceConfigPacket(data);
      } else if (packetType == 0x66) {
        _handleCustomEegChunkStream(data);
      }
    } else if (_deviceType == DeviceType.muse2) {
      _handleMuse2Stream(data, charUuid!);
    }
  }

  void _handleDeviceConfigPacket(List<int> data) {
    debugPrint("[BLE] 📥 Received Device Configuration Packet.");
    final byteData = ByteData.view(Uint8List.fromList(data).buffer);
    final numChannels = byteData.getUint8(1);
    final newConfigs = <ElectrodeConfig>[];
    const headerSize = 8;
    const configSize = 10;
    for (int i = 0; i < numChannels; i++) {
      final offset = headerSize + (i * configSize);
      final nameBytes = data.sublist(offset, offset + 8);
      final nullIndex = nameBytes.indexOf(0);
      final name = utf8.decode(nameBytes.sublist(0, nullIndex != -1 ? nullIndex : 8));
      final type = byteData.getUint8(offset + 8);
      newConfigs.add(ElectrodeConfig(name: name, type: type));
    }
    _eegChannelCount = numChannels;
    _electrodeConfigs = newConfigs;
    debugPrint("[CONFIG] ✅ Parsed $numChannels channels. First channel: '${_electrodeConfigs.first.name}'");
    notifyListeners();
  }

  final List<int> _customEegReceiveBuffer = [];
  void _handleCustomEegChunkStream(List<int> data) {
    if (_eegChannelCount == 0) return;

    final int sampleSignalSize = _eegChannelCount * 2;
    const int sampleMotionSize = 12;
    const int sampleTriggerSize = 1;
    final int totalSampleSize = sampleSignalSize + sampleMotionSize + sampleTriggerSize;

    const int chunkSize = 12;
    const int headerSize = 4;
    final int totalPacketSize = headerSize + (chunkSize * totalSampleSize);

    _customEegReceiveBuffer.addAll(data);

    while (_customEegReceiveBuffer.length >= totalPacketSize) {
      final packetData = Uint8List.fromList(_customEegReceiveBuffer.sublist(0, totalPacketSize));
      _customEegReceiveBuffer.removeRange(0, totalPacketSize);
      
      final byteData = ByteData.view(packetData.buffer);
      if (byteData.getUint8(0) != 0x66) continue;

      final startIndex = byteData.getUint16(1, Endian.little);
      final numSamples = byteData.getUint8(3);
      
      final List<SensorDataPoint> newPoints = [];

      for(int i = 0; i < numSamples; i++) {
        final offset = headerSize + (i * totalSampleSize);
        newPoints.add(SensorDataPoint(
          sampleIndex: startIndex + i,
          eegValues: [for (int ch = 0; ch < _eegChannelCount; ch++) byteData.getUint16(offset + ch * 2, Endian.little)],
          accel: [for (int a = 0; a < 3; a++) byteData.getInt16(offset + sampleSignalSize + a * 2, Endian.little)],
          gyro: [for (int g = 0; g < 3; g++) byteData.getInt16(offset + sampleSignalSize + 6 + g * 2, Endian.little)],
          triggerState: byteData.getUint8(offset + sampleSignalSize + 12),
          timestamp: DateTime.now(),
        ));
      }
      _updateDataBuffer(newPoints);
    }
  }
  
  void _handleMuse2Stream(List<int> data, String charUuid) {
    if (data.length != 20) return;
    final view = ByteData.view(Uint8List.fromList(data).buffer);
    final packetIndex = view.getUint16(0, Endian.big);
    final samples = <int>[];
    final reader = BitStream(stream: Uint8List.fromList(data.sublist(2)));
    for (int i = 0; i < 12; i++) {
        samples.add(reader.read(bits: 12));
    }
    final channelIndex = _museUuidToIndex[charUuid.toUpperCase()];
    if (channelIndex == null) return;
    _museEegBuffer[channelIndex] = samples;

    if (channelIndex == 1) {
        if (_museLastPacketIndex != -1 && packetIndex != (_museLastPacketIndex + 1) & 0xFFFF) {
            debugPrint("[Muse] Packet loss! prev: $_museLastPacketIndex, current: $packetIndex");
        }
        _museLastPacketIndex = packetIndex;
        const double microVoltPerLsb12bit = 0.48828125; // 12bit LSB換算(µV/LSB)
        const double center12bit = 2048.0;
        final newPoints = <SensorDataPoint>[];
        for (int i = 0; i < 12; i++) {
            // 4ch分のサンプルを抽出
            final ch0 = _museEegBuffer[0].isNotEmpty ? _museEegBuffer[0][i] : 0;
            final ch1 = _museEegBuffer[1].isNotEmpty ? _museEegBuffer[1][i] : 0;
            final ch2 = _museEegBuffer[2].isNotEmpty ? _museEegBuffer[2][i] : 0;
            final ch3 = _museEegBuffer[3].isNotEmpty ? _museEegBuffer[3][i] : 0;
            final eegRaw = [ch0, ch1, ch2, ch3];
            final eegUv = eegRaw
                .map((v) => (v.toDouble() - center12bit) * microVoltPerLsb12bit)
                .toList(growable: false);

            newPoints.add(SensorDataPoint(
                sampleIndex: _museSampleIndexCounter++,
                eegValues: eegRaw,
                eegMicroVolts: eegUv,
                accel: [0, 0, 0],
                gyro: [0, 0, 0],
                triggerState: 0,
                timestamp: DateTime.now(),
            ));
        }
        _updateDataBuffer(newPoints);
    }
  }

  void _updateDataBuffer(List<SensorDataPoint> newPoints) {
    if (newPoints.isEmpty) return;
    _displayDataBuffer.addAll(newPoints);
    if (_displayDataBuffer.length > displayBufferSize) {
      _displayDataBuffer.removeRange(0, _displayDataBuffer.length - displayBufferSize);
    }
    _calculateValence();
    _needsUiUpdate = true;
    _serverUploadBuffer.addAll(newPoints);
    if (_serverUploadBuffer.length >= samplesPerPayload) {
      _prepareAndSendPayload();
    }
  }
  
  Future<void> _prepareAndSendPayload() async {
    if (_eegChannelCount == 0) return;

    final samplesToSend = _serverUploadBuffer.sublist(0, samplesPerPayload);
    _serverUploadBuffer.removeRange(0, samplesPerPayload);
    final builder = BytesBuilder();
    
    final int totalChannelsToServer = _eegChannelCount + (_deviceType == DeviceType.customEeg ? 1 : 0);
    
    builder.add([0x02, totalChannelsToServer, 0, 0, 0, 0, 0, 0]);

    for (final config in _electrodeConfigs) {
      final nameBytes = utf8.encode(config.name);
      final paddedName = Uint8List(8)..setRange(0, nameBytes.length, nameBytes);
      builder.add(paddedName);
      builder.add([config.type, 0]);
    }
    if (_deviceType == DeviceType.customEeg) {
      final trigNameBytes = utf8.encode("TRIG");
      final trigPaddedName = Uint8List(8)..setRange(0, trigNameBytes.length, trigNameBytes);
      builder.add(trigPaddedName);
      builder.add([3, 0]);
    }

    for (final sample in samplesToSend) {
      final signalsBytes = ByteData(_eegChannelCount * 2);
      for (int i = 0; i < _eegChannelCount; i++) {
        signalsBytes.setUint16(i * 2, sample.eegValues[i], Endian.little);
      }
      builder.add(signalsBytes.buffer.asUint8List());

      if (_deviceType == DeviceType.customEeg) {
        final triggerBytes = ByteData(2);
        triggerBytes.setUint16(0, sample.triggerState, Endian.little);
        builder.add(triggerBytes.buffer.asUint8List());
      }

      final accelBytes = ByteData(6);
      for (int i = 0; i < 3; i++) accelBytes.setInt16(i * 2, sample.accel[i], Endian.little);
      builder.add(accelBytes.buffer.asUint8List());

      final gyroBytes = ByteData(6);
      for (int i = 0; i < 3; i++) gyroBytes.setInt16(i * 2, sample.gyro[i], Endian.little);
      builder.add(gyroBytes.buffer.asUint8List());

      final impedanceBytes = Uint8List(totalChannelsToServer)..fillRange(0, totalChannelsToServer, 255);
      builder.add(impedanceBytes);
    }

    final uncompressedPayload = builder.toBytes();
    
    debugPrint('[Payload] Generated Uncompressed Payload. Size: ${uncompressedPayload.length} bytes.');
    
    final compressedPayload = await uncompressedPayload.compress();
    if (compressedPayload == null) {
      debugPrint('[Payload] Compression failed.');
      return;
    }
    _sendPayloadToServer(compressedPayload, samplesToSend.first.timestamp, samplesToSend.last.timestamp);
  }

  Future<void> _sendPayloadToServer(Uint8List compressedPacket, DateTime startTime, DateTime endTime) async {
    if (!_authProvider.isAuthenticated || _targetDevice == null) return;
    
    final body = jsonEncode({
      'user_id': _authProvider.userId, 'session_id': null, 'device_id': _targetDevice!.remoteId.str,
      'timestamp_start_ms': startTime.millisecondsSinceEpoch, 'timestamp_end_ms': endTime.millisecondsSinceEpoch,
      'payload_base64': base64Encode(compressedPacket)
    });

    try {
      final url = Uri.parse('${_config.httpBaseUrl}/api/v1/data');
      await http.post(url, headers: {'Content-Type': 'application/json', 'X-User-Id': _authProvider.userId!}, body: body)
          .timeout(const Duration(seconds: 10));
      debugPrint('[HTTP] ✅ Payload sent to server.');
    } catch (e) {
      debugPrint('[HTTP] ❌ Error sending payload: $e');
    }
  }
  
  void _calculateValence() {
    if (_displayDataBuffer.length < sampleRate || _electrodeConfigs.length < 2) return;
    final recentData = _displayDataBuffer.sublist(_displayDataBuffer.length - sampleRate);
    double powerLeft = 0, powerRight = 0;

    final leftIndices = <int>[];
    final rightIndices = <int>[];
    for (int i = 0; i < _electrodeConfigs.length; i++) {
        final name = _electrodeConfigs[i].name.toLowerCase();
        final numberMatch = RegExp(r'(\d+)$').firstMatch(name);
        if (numberMatch != null) {
            final num = int.tryParse(numberMatch.group(1) ?? "");
            if (num != null) {
                if (num % 2 != 0) leftIndices.add(i);
                else rightIndices.add(i);
            }
        } else {
            if (name.contains('tp9') || name.contains('af7')) leftIndices.add(i);
            if (name.contains('tp10') || name.contains('af8')) rightIndices.add(i);
        }
    }
    if (leftIndices.isEmpty || rightIndices.isEmpty) return;

    for (var point in recentData) {
      for (var i in leftIndices) powerLeft += pow(point.eegValues[i] - 32768, 2);
      for (var i in rightIndices) powerRight += pow(point.eegValues[i] - 32768, 2);
    }
    if (powerLeft > 0 && powerRight > 0) {
      final score = log(powerRight) - log(powerLeft);
      _valenceHistory.add((DateTime.now(), score));
      if (_valenceHistory.length > 200) _valenceHistory.removeAt(0);
    }
  }

  Future<void> _sendMuseCommand(String command) async {
    if (_rxCharacteristic == null) return;
    await Future.delayed(const Duration(milliseconds: 50));
    final cmdBytes = utf8.encode(command);
    final packet = Uint8List(cmdBytes.length + 2)
      ..[0] = cmdBytes.length + 1
      ..setRange(1, cmdBytes.length + 1, cmdBytes)
      ..[cmdBytes.length + 1] = 0x0a;
    await _rxCharacteristic!.write(packet, withoutResponse: true);
  }

  @override
  Future<void> disconnect() async {
    if (_isConnected && _rxCharacteristic != null) {
      try {
        if (_deviceType == DeviceType.customEeg) await _rxCharacteristic!.write([0x5B], withoutResponse: true);
        else if (_deviceType == DeviceType.muse2) await _sendMuseCommand('h');
      } catch (e) {
        debugPrint("[BLE] Error sending stop command: $e");
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    if (_targetDevice?.isConnected == true) await _targetDevice!.disconnect();
    _cleanUp();
  }

  void _cleanUp() {
    _scanTimeoutTimer?.cancel();
    
    for (final sub in _valueSubscriptions) { sub.cancel(); }
    _valueSubscriptions.clear();
    _connectionStateSubscription?.cancel();
    _scanSubscription?.cancel();
    _targetDevice = null;
    _isConnected = false;
    _deviceType = DeviceType.unknown;
    _displayDataBuffer.clear();
    _serverUploadBuffer.clear();
    _valenceHistory.clear();
    _customEegReceiveBuffer.clear();
    _museEegBuffer.forEach((b) => b.clear());
    _museLastPacketIndex = -1;
    _electrodeConfigs.clear();
    _eegChannelCount = 0;
    _updateStatus("未接続");
    notifyListeners();
  }
  
  void _updateStatus(String message) {
    if (!isConnected && message == _statusMessage) return;
    _statusMessage = message;
    notifyListeners();
  }
}


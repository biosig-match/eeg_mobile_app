import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:zstandard/zstandard.dart';

import '../models/sensor_data.dart';
import '../utils/config.dart';
import 'auth_provider.dart';

// Isolateで実行するトップレベル関数 (変更なし)
Future<DecodedPacket?> _decompressAndParseIsolate(
    Uint8List compressedData) async {
  final decompressed = await compressedData.decompress();

  if (decompressed == null || decompressed.isEmpty) return null;

  final byteData = ByteData.view(decompressed.buffer);
  const int headerSize = 18; // deviceId[17] + 1 (null terminator)
  const int pointSize =
      53; // eeg[8*2] + accel[3*4] + gyro[3*4] + trigger[1] + impedance[8*1] + timestamp_us[4]

  if (decompressed.length < headerSize) return null;

  final deviceIdBytes = decompressed.sublist(0, 17);
  final deviceId = String.fromCharCodes(deviceIdBytes.where((c) => c != 0));

  final points = <SensorDataPoint>[];
  final numPoints = (decompressed.length - headerSize) ~/ pointSize;

  for (int i = 0; i < numPoints; i++) {
    int offset = headerSize + (i * pointSize);
    final eegs = [
      for (int ch = 0; ch < 8; ch++)
        byteData.getUint16(offset + (ch * 2), Endian.little)
    ];
    points.add(SensorDataPoint(eegValues: eegs, timestamp: DateTime.now()));
  }

  return DecodedPacket(deviceId, points);
}

class BleProvider with ChangeNotifier {
  final ServerConfig _config;
  final AuthProvider _authProvider;

  BluetoothDevice? _targetDevice;
  StreamSubscription<List<int>>? _valueSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;
  BluetoothCharacteristic? _rxCharacteristic;
  bool _isConnected = false;
  String _statusMessage = "未接続";
  String? connectedDeviceId;

  static const int sampleRate = 256;
  static const double timeWindowSec = 5.0;
  static final int bufferSize = (sampleRate * timeWindowSec).toInt();
  final List<SensorDataPoint> _dataBuffer = [];
  final List<(DateTime, double)> _valenceHistory = [];

  // ★★★★★ 変更点(1): UI更新を間引くためのフラグとタイマーを追加 ★★★★★
  bool _needsUiUpdate = false;
  Timer? _uiUpdateTimer;

  bool get isConnected => _isConnected;
  String get statusMessage => _statusMessage;
  List<SensorDataPoint> get displayData => _dataBuffer;
  List<(DateTime, double)> get valenceHistory => _valenceHistory;

  BleProvider(this._config, this._authProvider) {
    // 16ミリ秒ごと（約60fps）にUI更新をチェックするタイマーを設定
    _uiUpdateTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (_needsUiUpdate) {
        notifyListeners();
        _needsUiUpdate = false;
      }
    });
  }

  @override
  void dispose() {
    _uiUpdateTimer?.cancel(); // Providerが破棄されるときにタイマーもキャンセル
    super.dispose();
  }

  void startScan() {
    _updateStatus("デバイスをスキャン中...");
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
    FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult r in results) {
        if (r.device.platformName.startsWith("EEG-Device")) {
          FlutterBluePlus.stopScan();
          _connectToDevice(r.device);
          break;
        }
      }
    });
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    _updateStatus("接続中: ${device.platformName}");
    _targetDevice = device;

    _connectionStateSubscription = device.connectionState.listen((state) {
      debugPrint("[BLE] Connection state changed: $state");
      if (state == BluetoothConnectionState.disconnected) {
        _isConnected = false;
        _updateStatus("切断されました");
        _cleanUp();
        notifyListeners();
      }
    });

    try {
      await device.connect(timeout: const Duration(seconds: 15));
      debugPrint("[BLE] ✅ Connect method successful.");

      _isConnected = true;
      notifyListeners();

      _updateStatus("デバイスを準備中 (MTU)...");
      try {
        int mtu = await device.requestMtu(512);
        debugPrint("[BLE] ✅ MTU successfully negotiated: $mtu bytes");
      } catch (e) {
        debugPrint("[BLE] ⚠️ MTU request failed, but continuing: $e");
      }

      _updateStatus("デバイスを準備中 (Services)...");
      await _setupServices(device);
    } catch (e) {
      debugPrint("[BLE] ❌ Connection failed: $e");
      await _connectionStateSubscription?.cancel();
      _updateStatus("接続に失敗しました");
      _cleanUp();
    }
  }

  Future<void> _setupServices(BluetoothDevice device) async {
    try {
      debugPrint("[BLE] Starting service discovery...");
      final services = await device.discoverServices();
      bool txFound = false;
      bool rxFound = false;

      for (var service in services) {
        if (service.uuid.toString().toUpperCase() ==
            "6E400001-B5A3-F393-E0A9-E50E24DCCA9E") {
          debugPrint("[BLE] ✅ Target Service found.");
          for (var char in service.characteristics) {
            if (char.uuid.toString().toUpperCase() ==
                "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") {
              await char.setNotifyValue(true);
              _valueSubscription = char.lastValueStream.listen(_onDataReceived);
              txFound = true;
              debugPrint("[BLE]   ✅ TX Characteristic subscribed.");
            } else if (char.uuid.toString().toUpperCase() ==
                "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") {
              _rxCharacteristic = char;
              rxFound = true;
              debugPrint("[BLE]   ✅ RX Characteristic found and assigned.");
            }
          }
        }
      }

      if (txFound && rxFound) {
        await Future.delayed(const Duration(milliseconds: 500));
        debugPrint("[BLE] 👉 Sending Start Signal (0xAA) to RX...");
        try {
          await _rxCharacteristic!.write([0xAA], withoutResponse: false);
          debugPrint("[BLE] ✅ Start Signal (0xAA) Sent successfully!");
          _updateStatus("接続完了");
        } catch (e) {
          debugPrint("[BLE] ❌ Start Signal Write Failed: $e");
          _updateStatus("エラー: デバイスの準備に失敗");
          await disconnect();
        }
      } else {
        _updateStatus("エラー: 必要なキャラクタリスティックが見つかりません");
        debugPrint("[BLE] ❌ TX Found: $txFound, RX Found: $rxFound");
        await disconnect();
      }
    } catch (e) {
      _updateStatus("サービス検索エラー: $e");
      debugPrint("[BLE] ❌ Service discovery error: $e");
      await disconnect();
    }
  }

  final List<int> _receiveBuffer = [];
  int _expectedPacketSize = -1;

  void _onDataReceived(List<int> data) {
    if (data.isEmpty) return;
    _receiveBuffer.addAll(data);
    while (true) {
      if (_expectedPacketSize == -1 && _receiveBuffer.length >= 4) {
        final header = Uint8List.fromList(_receiveBuffer.sublist(0, 4));
        _expectedPacketSize =
            ByteData.view(header.buffer).getUint32(0, Endian.little);
        _receiveBuffer.removeRange(0, 4);
        debugPrint(
            "[DATA] Header parsed. Expecting packet of size: $_expectedPacketSize bytes.");
      }
      if (_expectedPacketSize != -1 &&
          _receiveBuffer.length >= _expectedPacketSize) {
        final compressedPacket =
            Uint8List.fromList(_receiveBuffer.sublist(0, _expectedPacketSize));
        _receiveBuffer.removeRange(0, _expectedPacketSize);
        debugPrint(
            "[DATA] Complete packet received. Size: ${compressedPacket.length}. Remaining buffer: ${_receiveBuffer.length}");
        _processPacket(compressedPacket);
        _expectedPacketSize = -1;
      } else {
        break;
      }
    }
  }

  Future<void> _processPacket(Uint8List compressedPacket) async {
    debugPrint("[PROC] Processing packet... Size: ${compressedPacket.length}");

    _sendDataToCollector(compressedPacket);
    compute(_decompressAndParseIsolate, compressedPacket).then((decoded) {
      if (decoded != null) {
        if (connectedDeviceId == null) {
          connectedDeviceId = decoded.deviceId;
        }
        _updateDataBuffer(decoded.points);
      } else {
        debugPrint("[PROC] ❌ Decompression or parsing failed.");
      }
    });

    if (_rxCharacteristic != null) {
      await Future.delayed(const Duration(milliseconds: 50));
      debugPrint("[ACK] 👉 Sending ACK (0x01) to MCU...");
      try {
        await _rxCharacteristic!.write([0x01], withoutResponse: false);
        debugPrint("[ACK] ✅ ACK (0x01) sent successfully.");
      } catch (e) {
        debugPrint("[ACK] ❌ ACK write operation failed: $e");
      }
    } else {
      debugPrint("[ACK] ❌ Cannot send ACK: RX characteristic is null!");
    }
  }

  Future<void> _sendDataToCollector(Uint8List compressedPacket) async {
    if (!_authProvider.isAuthenticated) return;
    final String payloadBase64 = base64Encode(compressedPacket);
    final body = jsonEncode(
        {'user_id': _authProvider.userId, 'payload_base64': payloadBase64});
    try {
      final url = Uri.parse('${_config.httpBaseUrl}/api/v1/data');
      debugPrint("[HTTP] Sending data to collector...");
      // ★★★★★ 変更点(2): タイムアウトを5秒に延長 ★★★★★
      await http
          .post(url, headers: {'Content-Type': 'application/json'}, body: body)
          .timeout(const Duration(seconds: 5));
      debugPrint("[HTTP] Successfully sent data.");
    } catch (e) {
      debugPrint('[HTTP] ❌ Error sending data to collector: $e');
    }
  }

  void _updateDataBuffer(List<SensorDataPoint> newPoints) {
    _dataBuffer.addAll(newPoints);
    if (_dataBuffer.length > bufferSize) {
      _dataBuffer.removeRange(0, _dataBuffer.length - bufferSize);
    }
    _calculateValence();

    // ★★★★★ 変更点(1)の続き: すぐにUIを更新せず、フラグを立てるだけにする ★★★★★
    _needsUiUpdate = true;
  }

  void _calculateValence() {
    if (_dataBuffer.length < sampleRate) return;
    final recentData = _dataBuffer.sublist(_dataBuffer.length - sampleRate);
    double powerLeft = 0, powerRight = 0;
    for (var point in recentData) {
      powerLeft += pow(point.eegValues[0] - 2048, 2);
      powerRight += pow(point.eegValues[1] - 2048, 2);
    }
    if (powerLeft > 0 && powerRight > 0) {
      final score = log(powerRight) - log(powerLeft);
      _valenceHistory.add((DateTime.now(), score));
      if (_valenceHistory.length > 200) {
        _valenceHistory.removeAt(0);
      }
    }
  }

  Future<void> disconnect() async {
    debugPrint("[BLE] Disconnecting from device...");
    await _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    await _valueSubscription?.cancel();
    _valueSubscription = null;
    await _targetDevice?.disconnect();
    _targetDevice = null;
    _cleanUp();
  }

  void _cleanUp() {
    _valueSubscription?.cancel();
    _valueSubscription = null;
    _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    _targetDevice = null;
    _isConnected = false;
    _dataBuffer.clear();
    _valenceHistory.clear();
    connectedDeviceId = null;
    _receiveBuffer.clear();
    _expectedPacketSize = -1;
    _updateStatus("未接続");
    notifyListeners();
    debugPrint("[BLE] Cleanup complete.");
  }

  void _updateStatus(String message) {
    _statusMessage = message;
    notifyListeners();
  }
}

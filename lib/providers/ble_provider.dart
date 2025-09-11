import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:zstandard/zstandard.dart';

import '../models/sensor_data.dart';
import '../utils/config.dart';
import 'auth_provider.dart';

// Isolateで実行するデコード処理
Future<DecodedPacket?> _decompressAndParseIsolate(
    Uint8List compressedData) async {
  // ★★★ zstandard公式ドキュメント推奨の拡張関数を使用して解凍 ★★★
  final decompressed = await compressedData.decompress();

  if (decompressed == null || decompressed.isEmpty) return null;

  final byteData = ByteData.view(decompressed.buffer);
  final headerSize = 18;
  final pointSize = 53;
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

  bool get isConnected => _isConnected;
  String get statusMessage => _statusMessage;
  List<SensorDataPoint> get displayData => _dataBuffer;
  List<(DateTime, double)> get valenceHistory => _valenceHistory;

  BleProvider(this._config, this._authProvider);

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

    _connectionStateSubscription?.cancel();
    _connectionStateSubscription = device.connectionState.listen((state) async {
      if (state == BluetoothConnectionState.connected) {
        _isConnected = true;
        _updateStatus("サービスを検索中...");
        try {
          await device.requestMtu(512);
        } catch (e) {
          debugPrint("MTUリクエスト失敗: $e");
        }
        await Future.delayed(const Duration(milliseconds: 500));
        await _discoverServices(device);
      } else if (state == BluetoothConnectionState.disconnected) {
        _isConnected = false;
        _updateStatus("切断されました");
        _cleanUp();
      }
      notifyListeners();
    });

    try {
      await device.connect(timeout: const Duration(seconds: 15));
    } catch (e) {
      debugPrint("接続エラー: $e");
      await _connectionStateSubscription?.cancel();
      _updateStatus("接続に失敗しました");
    }
  }

  Future<void> _discoverServices(BluetoothDevice device) async {
    try {
      final services = await device.discoverServices();
      for (var service in services) {
        if (service.uuid.toString().toUpperCase() ==
            "6E400001-B5A3-F393-E0A9-E50E24DCCA9E") {
          for (var char in service.characteristics) {
            if (char.uuid.toString().toUpperCase() ==
                "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") {
              await char.setNotifyValue(true);
              _valueSubscription = char.lastValueStream.listen(_onDataReceived);
            } else if (char.uuid.toString().toUpperCase() ==
                "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") {
              _rxCharacteristic = char;
            }
          }
          _updateStatus("接続完了");
          return;
        }
      }
      _updateStatus("必要なサービスが見つかりません");
    } catch (e) {
      _updateStatus("サービス検索エラー: $e");
    }
  }

  final List<int> _receiveBuffer = [];
  int _expectedPacketSize = -1;

  void _onDataReceived(List<int> data) {
    _receiveBuffer.addAll(data);
    while (true) {
      if (_expectedPacketSize == -1 && _receiveBuffer.length >= 4) {
        final header = Uint8List.fromList(_receiveBuffer.sublist(0, 4));
        _expectedPacketSize =
            ByteData.view(header.buffer).getUint32(0, Endian.little);
        _receiveBuffer.removeRange(0, 4);
      }
      if (_expectedPacketSize != -1 &&
          _receiveBuffer.length >= _expectedPacketSize) {
        final compressedPacket =
            Uint8List.fromList(_receiveBuffer.sublist(0, _expectedPacketSize));
        _receiveBuffer.removeRange(0, _expectedPacketSize);
        _expectedPacketSize = -1;
        _processPacket(compressedPacket);
      } else {
        break;
      }
    }
  }

  void _processPacket(Uint8List compressedPacket) {
    _sendDataToCollector(compressedPacket);
    compute(_decompressAndParseIsolate, compressedPacket).then((decoded) {
      if (decoded != null) {
        if (connectedDeviceId == null) {
          connectedDeviceId = decoded.deviceId;
          notifyListeners();
        }
        _updateDataBuffer(decoded.points);
      }
    });
    _rxCharacteristic?.write([0x01], withoutResponse: true);
  }

  Future<void> _sendDataToCollector(Uint8List compressedPacket) async {
    if (!_authProvider.isAuthenticated) return;
    final String payloadBase64 = base64Encode(compressedPacket);
    final body = jsonEncode(
        {'user_id': _authProvider.userId, 'payload_base64': payloadBase64});
    try {
      final url = Uri.parse('${_config.httpBaseUrl}/api/v1/data');
      await http
          .post(url, headers: {'Content-Type': 'application/json'}, body: body)
          .timeout(const Duration(seconds: 2));
    } catch (e) {
      debugPrint('Collectorへのデータ送信中にエラー: $e');
    }
  }

  void _updateDataBuffer(List<SensorDataPoint> newPoints) {
    _dataBuffer.addAll(newPoints);
    if (_dataBuffer.length > bufferSize) {
      _dataBuffer.removeRange(0, _dataBuffer.length - bufferSize);
    }
    _calculateValence();
    notifyListeners();
  }

  void _calculateValence() {
    if (_dataBuffer.length < sampleRate) return;
    final recentData = _dataBuffer.sublist(_dataBuffer.length - sampleRate);
    double powerLeft = 0, powerRight = 0;
    for (var point in recentData) {
      powerLeft += pow(point.eegValues[0] - 2048, 2); // Fp1
      powerRight += pow(point.eegValues[1] - 2048, 2); // Fp2
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
    await _connectionStateSubscription?.cancel();
    await _targetDevice?.disconnect();
    _cleanUp();
  }

  void _cleanUp() {
    _valueSubscription?.cancel();
    _valueSubscription = null;
    _connectionStateSubscription = null;
    _targetDevice = null;
    _isConnected = false;
    _dataBuffer.clear();
    _valenceHistory.clear();
    connectedDeviceId = null;
    _updateStatus("未接続");
    notifyListeners();
  }

  void _updateStatus(String message) {
    _statusMessage = message;
    notifyListeners();
  }
}

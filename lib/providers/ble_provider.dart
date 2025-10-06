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
import 'ble_provider_interface.dart';

// Isolateで実行するトップレベル関数 (変更なし)
Future<DecodedPacket?> _decompressAndParseIsolate(
    Uint8List compressedData) async {
  final decompressed = await compressedData.decompress();

  if (decompressed == null || decompressed.isEmpty) return null;

  final byteData = ByteData.view(decompressed.buffer);
  const int headerSize = 18;
  const int pointSize = 53;

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

class BleProvider with ChangeNotifier implements BleProviderInterface {
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

  bool _needsUiUpdate = false;
  Timer? _uiUpdateTimer;

  Timer? _timeSyncTimer;
  String _timeSyncStatus = "時刻未同期";
  // ★★★ 最後に成功した時刻同期情報を保持するプロパティ ★★★
  Map<String, dynamic>? _lastClockOffsetInfo;

  bool get isConnected => _isConnected;
  String get statusMessage => _statusMessage;
  List<SensorDataPoint> get displayData => _dataBuffer;
  List<(DateTime, double)> get valenceHistory => _valenceHistory;
  String get timeSyncStatus => _timeSyncStatus;
  String? get deviceId => connectedDeviceId;
  int get channelCount => _dataBuffer.isNotEmpty ? _dataBuffer.first.eegValues.length : 8;
  // ★★★ 外部から時刻同期情報を取得するためのゲッター ★★★
  Map<String, dynamic>? get lastClockOffsetInfo => _lastClockOffsetInfo;

  BleProvider(this._config, this._authProvider) {
    _uiUpdateTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (_needsUiUpdate) {
        notifyListeners();
        _needsUiUpdate = false;
      }
    });
  }

  @override
  void dispose() {
    _uiUpdateTimer?.cancel();
    _timeSyncTimer?.cancel();
    super.dispose();
  }

  Future<void> startScan() async {
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
      final services = await device.discoverServices();
      bool txFound = false;
      bool rxFound = false;

      for (var service in services) {
        if (service.uuid.toString().toUpperCase() ==
            "6E400001-B5A3-F393-E0A9-E50E24DCCA9E") {
          for (var char in service.characteristics) {
            if (char.uuid.toString().toUpperCase() ==
                "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") {
              await char.setNotifyValue(true);
              _valueSubscription =
                  char.lastValueStream.listen(_onDataDispatcher);
              txFound = true;
            } else if (char.uuid.toString().toUpperCase() ==
                "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") {
              _rxCharacteristic = char;
              rxFound = true;
            }
          }
        }
      }

      if (txFound && rxFound) {
        await Future.delayed(const Duration(milliseconds: 500));
        await _rxCharacteristic!.write([0xAA], withoutResponse: false);
        _updateStatus("接続完了");
        startTimeSync();
      } else {
        _updateStatus("エラー: 必要なキャラクタリスティックが見つかりません");
        await disconnect();
      }
    } catch (e) {
      _updateStatus("サービス検索エラー: $e");
      await disconnect();
    }
  }

  void _onDataDispatcher(List<int> data) {
    if (data.isEmpty) return;

    if (data.length == 17 && data[0] == 0xCC) {
      _handlePong(data);
    } else {
      _handleSensorStream(data);
    }
  }

  final List<int> _receiveBuffer = [];
  int _expectedPacketSize = -1;

  void _handleSensorStream(List<int> data) {
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
        _processPacket(compressedPacket);
        _expectedPacketSize = -1;
      } else {
        break;
      }
    }
  }

  void startTimeSync() {
    _timeSyncTimer?.cancel();
    _timeSyncStatus = "時刻同期中...";
    notifyListeners();
    _sendPing();
    _timeSyncTimer =
        Timer.periodic(const Duration(minutes: 1), (timer) => _sendPing());
  }

  Future<void> _sendPing() async {
    if (!_isConnected || _rxCharacteristic == null) return;
    try {
      final t1 = DateTime.now().millisecondsSinceEpoch;
      final buffer = ByteData(9);
      buffer.setUint8(0, 0xBB);
      buffer.setUint64(1, t1, Endian.little);
      debugPrint("[SYNC] 👉 Sending Ping with T1: $t1");
      await _rxCharacteristic!
          .write(buffer.buffer.asUint8List(), withoutResponse: false);
    } catch (e) {
      debugPrint("[SYNC] ❌ Error sending Ping: $e");
    }
  }

  void _handlePong(List<int> pongData) {
    final t3 = DateTime.now().millisecondsSinceEpoch;
    final view = ByteData.view(Uint8List.fromList(pongData).buffer);
    final t1 = view.getUint64(1, Endian.little);
    final t2Microseconds = view.getUint64(9, Endian.little);
    final rtt = t3 - t1;
    final oneWayDelay = rtt / 2;
    final estimatedServerTimeAtT2 = t1 + oneWayDelay;
    final offset = estimatedServerTimeAtT2 - (t2Microseconds / 1000.0);

    debugPrint(
        "[SYNC] ✅ Pong received. T1: $t1, T2: $t2Microseconds us, T3: $t3");
    debugPrint("[SYNC] RTT: $rtt ms, Offset: ${offset.toStringAsFixed(2)} ms");

    _timeSyncStatus = "オフセット: ${offset.toStringAsFixed(2)} ms (RTT: ${rtt} ms)";
    // ★★★ 計算したオフセット情報を保持 ★★★
    _lastClockOffsetInfo = {
      "offset_ms_avg": offset,
      "rtt_ms_avg": rtt.toDouble(),
    };
    notifyListeners();
    // サーバーへの送信は不要なのでコメントアウト or 削除
    // _sendOffsetToServer(offset, DateTime.fromMillisecondsSinceEpoch(t3));
  }

  Future<void> _processPacket(Uint8List compressedPacket) async {
    _sendDataToCollector(compressedPacket);
    compute(_decompressAndParseIsolate, compressedPacket).then((decoded) {
      if (decoded != null) {
        if (connectedDeviceId == null) {
          connectedDeviceId = decoded.deviceId;
        }
        _updateDataBuffer(decoded.points);
      }
    });

    if (_rxCharacteristic != null) {
      await Future.delayed(const Duration(milliseconds: 50));
      try {
        await _rxCharacteristic!.write([0x01], withoutResponse: false);
      } catch (e) {
        debugPrint("[ACK] ❌ ACK write operation failed: $e");
      }
    }
  }

  Future<void> _sendDataToCollector(Uint8List compressedPacket) async {
    // 認証されていない場合は送信をスキップ
    if (!_authProvider.isAuthenticated) return;
    
    try {
      final String payloadBase64 = base64Encode(compressedPacket);
      final body = jsonEncode(
          {'user_id': _authProvider.userId, 'payload_base64': payloadBase64});
      
      final url = Uri.parse('${_config.httpBaseUrl}/api/v1/data');
      await http
          .post(url,
              headers: {
                'Content-Type': 'application/json',
                'X-User-Id': _authProvider.userId!
              },
              body: body)
          .timeout(const Duration(seconds: 2)); // タイムアウトを短縮
    } catch (e) {
      // サーバー送信エラーは無視（リアルタイム表示に影響しない）
      debugPrint('[HTTP] Server send failed (ignored): $e');
    }
  }

  void _updateDataBuffer(List<SensorDataPoint> newPoints) {
    _dataBuffer.addAll(newPoints);
    if (_dataBuffer.length > bufferSize) {
      _dataBuffer.removeRange(0, _dataBuffer.length - bufferSize);
    }
    _calculateValence();
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
    await _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    await _valueSubscription?.cancel();
    _valueSubscription = null;
    if (_targetDevice != null) {
      try {
        await _targetDevice!.disconnect();
      } catch (e) {
        debugPrint("[BLE] Error during disconnect: $e");
      }
    }
    _targetDevice = null;
    _cleanUp();
  }

  void _cleanUp() {
    _valueSubscription?.cancel();
    _valueSubscription = null;
    _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    _timeSyncTimer?.cancel();
    _timeSyncTimer = null;
    _targetDevice = null;
    _isConnected = false;
    _dataBuffer.clear();
    _valenceHistory.clear();
    connectedDeviceId = null;
    _receiveBuffer.clear();
    _expectedPacketSize = -1;
    _updateStatus("未接続");
    _timeSyncStatus = "時刻未同期";
    _lastClockOffsetInfo = null; // ★★★ 時刻同期情報をリセット ★★★
    notifyListeners();
  }

  void _updateStatus(String message) {
    _statusMessage = message;
    notifyListeners();
  }
}

import 'dart:async';
import 'dart:typed_data';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:zstandard/zstandard.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'experiment_provider.dart';
import '../utils/config.dart';

// (SensorDataPointクラスの定義は変更なし)
class SensorDataPoint {
  final List<int> eegValues;
  final DateTime timestamp;
  SensorDataPoint({required this.eegValues, required this.timestamp});
}

class DecodedPacket {
  final String deviceId;
  final List<SensorDataPoint> points;
  DecodedPacket(this.deviceId, this.points);
}

// Isolateで実行するトップレベル関数
Future<DecodedPacket?> _decompressAndParseIsolate(Uint8List compressedData) async {
    // ★★★ 公式ドキュメント通り、拡張関数を使って解凍 ★★★
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
        final eegs = [for (int ch = 0; ch < 8; ch++) byteData.getUint16(offset + (ch * 2), Endian.little)];
        points.add(SensorDataPoint(eegValues: eegs, timestamp: DateTime.now()));
    }
    return DecodedPacket(deviceId, points);
}


class BleProvider with ChangeNotifier {
  // (プロパティ定義は変更なし)
  final ServerConfig _config;
  BleProvider(this._config);
  late ExperimentProvider experimentProvider;
  BluetoothDevice? _targetDevice;
  StreamSubscription<List<int>>? _valueSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;
  BluetoothCharacteristic? _rxCharacteristic;
  bool _isConnected = false;
  String _statusMessage = "未接続";
  String? connectedDeviceId;
  WebSocketChannel? _webSocketChannel;
  static const int sampleRate = 256;
  static const double timeWindowSec = 5.0;
  static final int bufferSize = (sampleRate * timeWindowSec).toInt();
  final List<SensorDataPoint> _dataBuffer = [];
  double _displayYMin = 1800.0;
  double _displayYMax = 2200.0;
  final List<(DateTime, double)> _valenceHistory = [];
  bool get isConnected => _isConnected;
  String get statusMessage => _statusMessage;
  List<SensorDataPoint> get displayData => _dataBuffer;
  double get displayYMin => _displayYMin;
  double get displayYMax => _displayYMax;
  List<(DateTime, double)> get valenceHistory => _valenceHistory;
  int get channelCount => _dataBuffer.isNotEmpty ? _dataBuffer.first.eegValues.length : 0;

  void startScan() {
    // (この関数は変更なし)
    _updateStatus("デバイスをスキャン中...");
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
    FlutterBluePlus.scanResults.listen((results) {
        for (ScanResult r in results) {
            if (r.device.platformName == "EEG-Device") {
                FlutterBluePlus.stopScan();
                _connectToDevice(r.device);
                break;
            }
        }
    });
  }

  // ★★★ この関数を修正しました ★★★
  Future<void> _connectToDevice(BluetoothDevice device) async {
    _updateStatus("接続中...");
    _targetDevice = device;

    _connectionStateSubscription?.cancel();
    _connectionStateSubscription = device.connectionState.listen((state) async { // asyncを追加
      if (state == BluetoothConnectionState.connected) {
        _isConnected = true;
        _updateStatus("サービスを検索中...");
        
        // ★★★ MTUサイズを要求する処理を追加 ★★★
        // これにより、より安定した通信が可能になります
        try {
          await device.requestMtu(512);
        } catch (e) {
          print("MTUリクエスト失敗: $e");
        }
        
        // ★★★ サービス検索の前に少し待機（安定性向上）★★★
        await Future.delayed(const Duration(milliseconds: 500));
        await _discoverServices(device);

      } else if (state == BluetoothConnectionState.disconnected) {
        _isConnected = false;
        _updateStatus("切断されました");
        _webSocketChannel?.sink.close();
      }
      notifyListeners();
    });

    try {
      await device.connect(timeout: const Duration(seconds: 15));
    } catch(e) {
      print("接続エラー: $e");
      // 接続に失敗した場合でも、listenは開始されている可能性があるのでクリーンアップ
      await _connectionStateSubscription?.cancel();
      _updateStatus("接続に失敗しました");
    }
  }
  
  // (以降のコードは変更なし)
  Future<void> _discoverServices(BluetoothDevice device) async {
    try {
      final services = await device.discoverServices();
      for (var service in services) {
          if (service.uuid.toString().toUpperCase() == "6E400001-B5A3-F393-E0A9-E50E24DCCA9E") {
              for (var char in service.characteristics) {
                  if (char.uuid.toString().toUpperCase() == "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") {
                      await char.setNotifyValue(true);
                      _valueSubscription = char.lastValueStream.listen(_onDataReceived);
                  } else if (char.uuid.toString().toUpperCase() == "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") {
                      _rxCharacteristic = char;
                  }
              }
              _updateStatus("接続完了");
              _connectWebSocket();
              return;
          }
      }
    } catch (e) {
      _updateStatus("サービス検索エラー: $e");
    }
  }

  void _connectWebSocket() {
    final url = Uri.parse('${_config.wsBaseUrl}/api/v1/eeg');
    _webSocketChannel = WebSocketChannel.connect(url);
    _webSocketChannel!.stream.listen(
      (message) {},
      onError: (error) => _updateStatus("WebSocketエラー: $error"),
      onDone: () => _updateStatus("WebSocket切断"),
    );
  }

  final List<int> _receiveBuffer = [];
  int _expectedPacketSize = -1;

  void _onDataReceived(List<int> data) {
    _receiveBuffer.addAll(data);
    while (true) {
      if (_expectedPacketSize == -1 && _receiveBuffer.length >= 4) {
        final header = Uint8List.fromList(_receiveBuffer.sublist(0, 4));
        _expectedPacketSize = ByteData.view(header.buffer).getUint32(0, Endian.little);
        _receiveBuffer.removeRange(0, 4);
      }
      if (_expectedPacketSize != -1 && _receiveBuffer.length >= _expectedPacketSize) {
        final compressedPacket = Uint8List.fromList(_receiveBuffer.sublist(0, _expectedPacketSize));
        _receiveBuffer.removeRange(0, _expectedPacketSize);
        _expectedPacketSize = -1;
        _processPacket(compressedPacket);
      } else {
        break;
      }
    }
  }
  
  void _processPacket(Uint8List compressedPacket) {
    _webSocketChannel?.sink.add(compressedPacket);
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
  
  void _updateDataBuffer(List<SensorDataPoint> newPoints) {
    _dataBuffer.addAll(newPoints);
    if (_dataBuffer.length > bufferSize) {
      _dataBuffer.removeRange(0, _dataBuffer.length - bufferSize);
    }
    _updateYAxisRange();
    _calculateValence();
    notifyListeners();
  }

  void _updateYAxisRange() {
      if (_dataBuffer.isEmpty) return;
      int minVal = 4095, maxVal = 0;
      for (var point in _dataBuffer) {
          for (var val in point.eegValues) {
              if (val < minVal) minVal = val;
              if (val > maxVal) maxVal = val;
          }
      }
      final range = maxVal - minVal;
      _displayYMin = (minVal - range * 0.15);
      _displayYMax = (maxVal + range * 0.15);
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
    await _valueSubscription?.cancel();
    await _connectionStateSubscription?.cancel();
    await _targetDevice?.disconnect();
    _webSocketChannel?.sink.close();
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
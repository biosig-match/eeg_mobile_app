import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;

import '../models/sensor_data.dart';
import '../utils/config.dart';
import 'auth_provider.dart';
import 'ble_provider_interface.dart';

/// Museデバイスから受信したEEGデータを解析するアイソレート関数
/// メインスレッドをブロックせずに重い処理を実行するために使用
Future<List<SensorDataPoint>> _parseMuseEegDataIsolate(Uint8List rawData) async {
  final List<SensorDataPoint> newPoints = [];
  
  try {
    print("Muse: Parsing data packet, length: ${rawData.length}");
    
    // データ長をチェック
    if (rawData.length < 2) {
      print("Muse: Data too short: ${rawData.length}");
      return newPoints;
    }
    
    // Muse2の実際のデータ形式に合わせて解析
    // 最初の2バイトはパケットインデックス
    final int packetIndex = (rawData[0] << 8) | rawData[1];
    print("Muse: Packet index: $packetIndex");
    
    // 残りのデータを4チャンネルに分割
    final int dataLength = rawData.length - 2;
    final int samplesPerChannel = dataLength ~/ 4;
    
    if (samplesPerChannel == 0) {
      print("Muse: No samples per channel");
      return newPoints;
    }
    
    print("Muse: Samples per channel: $samplesPerChannel");
    
    // 各チャンネルのデータを処理
    final List<int> tp9Data = [];
    final List<int> af7Data = [];
    final List<int> af8Data = [];
    final List<int> tp10Data = [];
    
    for (int i = 0; i < samplesPerChannel; i++) {
      final int offset = 2 + i;
      
      if (offset < rawData.length) {
        tp9Data.add(rawData[offset]);
      }
      if (offset + samplesPerChannel < rawData.length) {
        af7Data.add(rawData[offset + samplesPerChannel]);
      }
      if (offset + samplesPerChannel * 2 < rawData.length) {
        af8Data.add(rawData[offset + samplesPerChannel * 2]);
      }
      if (offset + samplesPerChannel * 3 < rawData.length) {
        tp10Data.add(rawData[offset + samplesPerChannel * 3]);
      }
    }
    
    // サンプル数に合わせてデータポイントを作成
    final int maxSamples = [tp9Data.length, af7Data.length, af8Data.length, tp10Data.length].reduce((a, b) => a < b ? a : b);
    
    for (int i = 0; i < maxSamples; i++) {
      final List<int> eegValues = [
        tp9Data.length > i ? tp9Data[i] : 0,
        af7Data.length > i ? af7Data[i] : 0,
        af8Data.length > i ? af8Data[i] : 0,
        tp10Data.length > i ? tp10Data[i] : 0,
      ];
      
      final timestamp = DateTime.now().add(Duration(milliseconds: i * (1000 ~/ 256)));
      
      final point = SensorDataPoint(
        eegValues: eegValues,
        timestamp: timestamp,
      );
      newPoints.add(point);
    }
    
    print("Muse: Created ${newPoints.length} data points");
    
  } catch (e) {
    print("Muse EEG data parsing error: $e");
    print("Muse: Raw data length: ${rawData.length}");
    if (rawData.isNotEmpty) {
      print("Muse: First 10 bytes: ${rawData.take(10).toList()}");
    }
  }
  
  return newPoints;
}

/// BLE接続の状態を表す列挙型
enum MuseConnectionState {
  disconnected,  // 未接続
  scanning,     // スキャン中
  connecting,   // 接続中
  connected,    // 接続済み
  streaming,    // ストリーミング中
}

// Muse GATTサービスとキャラクタリスティックのUUID
// Muse2の実際のサービスUUID（短縮UUID fe8d を完全UUIDに変換）
final Guid museServiceUuid = Guid("0000fe8d-0000-1000-8000-00805f9b34fb");
final Guid museStreamToggleUuid = Guid("0000fe8d-0000-1000-8000-00805f9b34fb");
final Guid museTp9Uuid = Guid("0000fe8d-0000-1000-8000-00805f9b34fb");
final Guid museAf7Uuid = Guid("0000fe8d-0000-1000-8000-00805f9b34fb");
final Guid museAf8Uuid = Guid("0000fe8d-0000-1000-8000-00805f9b34fb");
final Guid museTp10Uuid = Guid("0000fe8d-0000-1000-8000-00805f9b34fb");
final Guid museRightAuxUuid = Guid("0000fe8d-0000-1000-8000-00805f9b34fb");

/// Muse2デバイスとのBLE通信とEEGデータ処理を管理するプロバイダークラス
/// 既存のBleProviderと同様のインターフェースを提供
class MuseBleProvider with ChangeNotifier implements BleProviderInterface {
  final ServerConfig _config;
  final AuthProvider _authProvider;

  // BLE接続状態
  MuseConnectionState _connectionState = MuseConnectionState.disconnected;
  BluetoothDevice? _targetDevice;
  Map<Guid, StreamSubscription<List<int>>> _valueSubscriptions = {};
  
  // EEGデータ処理設定
  static const int sampleRate = 256;           // Museのサンプリングレート（Hz）
  static const double timeWindowSec = 5.0;     // 表示時間窓（秒）
  static final int bufferSize = (sampleRate * timeWindowSec).toInt();  // バッファサイズ
  final List<SensorDataPoint> _dataBuffer = [];
  
  // 表示設定
  double _displayYMin = -200.0;
  double _displayYMax = 200.0;
  
  // Muse通信用
  BluetoothCharacteristic? _streamToggleCharacteristic;
  
  // 感情分析履歴
  final List<(DateTime, double)> _valenceHistory = [];
  
  // Museデータ処理変数
  int _lastPacketIndex = -1;
  int _sampleIndex = 0;
  bool _firstSample = true;

  // UI更新制御（削除）

  // ステータス管理
  String _statusMessage = "未接続";
  String? connectedDeviceId;
  bool _serverConnectionAvailable = false;

  // ゲッター
  MuseConnectionState get connectionState => _connectionState;
  bool get isConnected => _connectionState == MuseConnectionState.streaming;
  String get statusMessage => _statusMessage;
  List<SensorDataPoint> get displayData {
    print("Muse: displayData getter called, buffer size: ${_dataBuffer.length}");
    return _dataBuffer;
  }
  int get channelCount => _dataBuffer.isNotEmpty ? _dataBuffer.first.eegValues.length : 0;
  double get displayYMin => _displayYMin;
  double get displayYMax => _displayYMax;
  List<(DateTime, double)> get valenceHistory => _valenceHistory;
  String? get deviceId => connectedDeviceId;
  bool get serverConnectionAvailable => _serverConnectionAvailable;

  /// コンストラクタ
  MuseBleProvider(this._config, this._authProvider) {
    print("MuseBleProvider: Constructor called");
    FlutterBluePlus.adapterState.listen((state) {
      if (state == BluetoothAdapterState.off) {
        _updateConnectionState(MuseConnectionState.disconnected);
      }
    });
    
    // UI更新タイマーは削除（直接notifyListeners()を使用）
  }

  /// 接続状態を更新してUIに通知
  void _updateConnectionState(MuseConnectionState state) {
    _connectionState = state;
    _updateStatus(_getStatusMessage(state));
    notifyListeners();
  }

  /// 状態に応じたステータスメッセージを取得
  String _getStatusMessage(MuseConnectionState state) {
    switch (state) {
      case MuseConnectionState.disconnected:
        return "未接続";
      case MuseConnectionState.scanning:
        return "Museデバイスをスキャン中...";
      case MuseConnectionState.connecting:
        return "接続中...";
      case MuseConnectionState.connected:
        return "接続完了";
      case MuseConnectionState.streaming:
        return "ストリーミング中";
    }
  }

  /// BLEデバイスのスキャンを開始
  /// Museという名前のデバイスを探す
  Future<void> startScan() async {
    if (_connectionState != MuseConnectionState.disconnected) return;
    
    _updateConnectionState(MuseConnectionState.scanning);
    _targetDevice = null;
    _dataBuffer.clear();
    _valenceHistory.clear();
    
    try {
      print("Muse: Starting BLE scan...");
      // 15秒間スキャンを実行
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
      
      // スキャン結果を監視して対象デバイスを探す
      FlutterBluePlus.scanResults.listen((results) {
        for (ScanResult r in results) {
          print("Muse: Found device: ${r.device.platformName}");
          if (r.device.platformName.toLowerCase().contains("muse")) {
            print("Muse: Muse device found, stopping scan");
            FlutterBluePlus.stopScan();
            _connectToDevice(r.device);
            break;
          }
        }
      });
    } catch (e) {
      print("Muse SCAN ERROR: $e");
      _updateConnectionState(MuseConnectionState.disconnected);
    }
    
    // 15秒後にスキャンを停止
    await Future.delayed(const Duration(seconds: 15));
    if (_connectionState == MuseConnectionState.scanning) {
      print("Muse: Scan timeout, stopping scan");
      FlutterBluePlus.stopScan();
      _updateConnectionState(MuseConnectionState.disconnected);
    }
  }

  /// 指定されたBLEデバイスに接続
  Future<void> _connectToDevice(BluetoothDevice device) async {
    if (_connectionState != MuseConnectionState.scanning) return;
    
    _updateConnectionState(MuseConnectionState.connecting);
    _targetDevice = device;
    
    // 接続状態を監視
    device.connectionState.listen((state) {
      print("Muse: Connection state changed: $state");
      if (state == BluetoothConnectionState.disconnected) {
        _updateConnectionState(MuseConnectionState.disconnected);
        _cleanUp();
      }
    });
    
    try {
      print("Muse: Attempting to connect to ${device.platformName}");
      // 20秒のタイムアウトで接続を試行
      await device.connect(timeout: const Duration(seconds: 20));
      print("Muse: Connected successfully");
      _updateConnectionState(MuseConnectionState.connected);
      await _discoverServices(device);
    } catch (e) {
      print("Muse CONNECTION ERROR: $e");
      try {
        await device.disconnect();
      } catch (disconnectError) {
        print("Muse: Error during disconnect: $disconnectError");
      }
      _updateConnectionState(MuseConnectionState.disconnected);
    }
  }

  /// デバイスのサービスとキャラクタリスティックを発見
  /// MuseのEEGデータ受信に必要なキャラクタリスティックを設定
  Future<void> _discoverServices(BluetoothDevice device) async {
    try {
      print("Muse: Discovering services...");
      List<BluetoothService> services = await device.discoverServices();
      print("Muse: Found ${services.length} services");
      
      for (var service in services) {
        print("Muse: Service UUID: ${service.uuid}");
        // Muse2のサービスUUIDをチェック（短縮UUID fe8d）
        if (service.uuid.toString().toLowerCase().contains("fe8d")) {
          print("Muse: Found Muse service");
          List<BluetoothCharacteristic> characteristics = service.characteristics;
          print("Muse: Found ${characteristics.length} characteristics");
          
          // すべてのキャラクタリスティックを表示
          for (int i = 0; i < characteristics.length; i++) {
            var char = characteristics[i];
            print("Muse: Characteristic $i UUID: ${char.uuid}");
            print("Muse: Characteristic $i properties: ${char.properties}");
          }
          
          // Muse2では、最初のキャラクタリスティックをストリーム制御に使用
          if (characteristics.isNotEmpty) {
            _streamToggleCharacteristic = characteristics[0];
            print("Muse: Using first characteristic for stream control");
            
            // 残りのキャラクタリスティックをEEGチャンネルとして使用
            List<BluetoothCharacteristic> eegCharacteristics = characteristics.skip(1).toList();
            if (eegCharacteristics.length >= 4) {
              print("Muse: Setting up EEG subscriptions with ${eegCharacteristics.length} channels");
              _setupEegSubscriptions(device, 
                eegCharacteristics[0], // TP9
                eegCharacteristics[1], // AF7
                eegCharacteristics[2], // AF8
                eegCharacteristics[3], // TP10
                eegCharacteristics.length > 4 ? eegCharacteristics[4] : null // Right Aux
              );
              return;
            } else {
              print("Muse: Not enough characteristics for EEG channels");
            }
          }
        }
      }
      
      print("Muse: Required Muse characteristics not found");
      disconnect();
    } catch (e) {
      print("Muse SERVICE DISCOVERY ERROR: $e");
      disconnect();
    }
  }

  /// EEGキャラクタリスティックの通知を設定
  /// 各チャンネルからのデータ受信を開始
  void _setupEegSubscriptions(BluetoothDevice device, BluetoothCharacteristic tp9, 
                              BluetoothCharacteristic af7, BluetoothCharacteristic af8, 
                              BluetoothCharacteristic tp10, BluetoothCharacteristic? rightAux) {
    // 既存のサブスクリプションをクリア
    _valueSubscriptions.values.forEach((sub) => sub.cancel());
    _valueSubscriptions.clear();
    
    // 各チャンネルの通知を有効化
    _subscribeToCharacteristic(tp9, "TP9");
    _subscribeToCharacteristic(af7, "AF7");
    _subscribeToCharacteristic(af8, "AF8");
    _subscribeToCharacteristic(tp10, "TP10");
    if (rightAux != null) {
      _subscribeToCharacteristic(rightAux, "RIGHTAUX");
    }
    
    // ストリーミング開始
    _startMuseStreaming();
  }

  /// キャラクタリスティックの値変更通知を購読
  /// 受信したデータを処理
  void _subscribeToCharacteristic(BluetoothCharacteristic characteristic, String channelName) {
    // 通知を有効化
    characteristic.setNotifyValue(true);
    
    // データ受信ストリームを監視
    final subscription = characteristic.lastValueStream.listen((value) {
      _processMuseEegData(value, channelName);
    });
    
    _valueSubscriptions[characteristic.uuid] = subscription;
  }

  /// MuseのEEGデータを処理
  /// 各チャンネルからのデータを受信して統合
  void _processMuseEegData(List<int> value, String channelName) {
    try {
      print("Muse: Received data from $channelName, length: ${value.length}");
      
      // データをUint8Listに変換
      final rawData = Uint8List.fromList(value);
      
      // データが空でない場合のみ処理
      if (rawData.isNotEmpty) {
        // アイソレートでデータを解析
        compute(_parseMuseEegDataIsolate, rawData).then((newPoints) {
          if (newPoints.isNotEmpty) {
            print("Muse: Processed ${newPoints.length} points from $channelName");
            _updateDataBuffer(newPoints);
          }
        }).catchError((error) {
          print("Muse: Error processing data from $channelName: $error");
        });
        
        // サーバーにデータを送信（オプショナル、非同期で実行）
        _sendDataToServerIfAvailable(rawData);
      }
      
    } catch (e) {
      print("Muse EEG data processing error: $e");
    }
  }

  /// Museストリーミングを開始
  /// 必要なコマンドを送信してEEGデータの送信を開始
  Future<void> _startMuseStreaming() async {
    if (_streamToggleCharacteristic == null) {
      print("Muse: Stream toggle characteristic is null");
      return;
    }
    
    try {
      print("Muse: Starting streaming...");
      
      // シンプルなストリーミング開始コマンド
      print("Muse: Sending streaming start command");
      await _writeMuseCommand('d');
      await Future.delayed(const Duration(milliseconds: 1000));
      
      _updateConnectionState(MuseConnectionState.streaming);
      print("Muse: Streaming started successfully");
      
    } catch (e) {
      print("Muse: Failed to start streaming: $e");
      _updateConnectionState(MuseConnectionState.connected);
    }
  }

  /// Museコマンドを送信
  Future<void> _writeMuseCommand(String cmd) async {
    if (_streamToggleCharacteristic == null) {
      print("Muse: Stream toggle characteristic is null, cannot send command");
      return;
    }
    
    try {
      final cmdBytes = [cmd.length + 1, ...cmd.codeUnits, 0x0a]; // \nで終了
      print("Muse: Sending command '$cmd' with bytes: $cmdBytes");
      await _streamToggleCharacteristic!.write(cmdBytes, withoutResponse: true);
      print("Muse: Command sent successfully");
    } catch (e) {
      print("Muse: Failed to write command '$cmd': $e");
    }
  }

  /// 新しいデータポイントをバッファに追加
  /// バッファサイズを超えた古いデータを削除
  void _updateDataBuffer(List<SensorDataPoint> newPoints) {
    if (newPoints.isEmpty) return;
    
    print("Muse: Adding ${newPoints.length} points to buffer (current: ${_dataBuffer.length})");
    
    // データポイントの詳細をログ出力
    if (newPoints.isNotEmpty) {
      final firstPoint = newPoints.first;
      print("Muse: First point - channels: ${firstPoint.eegValues.length}, values: ${firstPoint.eegValues.take(4).toList()}");
    }
    
    _dataBuffer.addAll(newPoints);
    
    // バッファサイズを超えた古いデータを削除
    if (_dataBuffer.length > bufferSize) {
      final removeCount = _dataBuffer.length - bufferSize;
      _dataBuffer.removeRange(0, removeCount);
      print("Muse: Removed $removeCount old points, buffer size: ${_dataBuffer.length}");
    }
    
    _updateYAxisRange();
    _calculateValence();
    
    // 強制的にUI更新を実行
    print("Muse: UI update requested, buffer size: ${_dataBuffer.length}");
    print("Muse: Calling notifyListeners()");
    notifyListeners();
  }

  /// 感情分析（valence）を計算
  /// 左右の脳波パワーの対数比から感情の偏りを算出
  void _calculateValence() {
    if (_dataBuffer.length < sampleRate) return;
    
    // 最新1秒分のデータを使用
    final recentData = _dataBuffer.sublist(_dataBuffer.length - sampleRate);
    double powerLeft = 0;   // 左脳のパワー（TP9, AF7）
    double powerRight = 0;  // 右脳のパワー（AF8, TP10）
    
    // 各データポイントのパワーを計算
    for (var point in recentData) {
      if (point.eegValues.length >= 4) {
        // 左脳：TP9（チャンネル0）とAF7（チャンネル1）
        powerLeft += pow(point.eegValues[0], 2) + pow(point.eegValues[1], 2);
        // 右脳：AF8（チャンネル2）とTP10（チャンネル3）
        powerRight += pow(point.eegValues[2], 2) + pow(point.eegValues[3], 2);
      }
    }
    
    // 平均パワーを計算
    powerLeft /= recentData.length;
    powerRight /= recentData.length;
    
    // 左右のパワー比から感情スコアを計算
    if (powerLeft > 0 && powerRight > 0) {
      final score = log(powerRight) - log(powerLeft);
      final timestamp = recentData.last.timestamp;
      _valenceHistory.add((timestamp, score));
      
      // 履歴は200ポイントまで保持
      if (_valenceHistory.length > 200) {
        _valenceHistory.removeAt(0);
      }
    }
  }

  /// 生データをサーバーに送信（オプショナル）
  /// 認証されていない場合やサーバーが利用できない場合は送信をスキップ
  Future<void> _sendDataToServerIfAvailable(Uint8List rawData) async {
    // 認証されていない場合は送信をスキップ
    if (!_authProvider.isAuthenticated) {
      _serverConnectionAvailable = false;
      return;
    }
    
    try {
      String base64Data = base64Encode(rawData);
      final body = jsonEncode({
        'user_id': _authProvider.userId,
        'payload_base64': base64Data,
        'device_type': 'muse'
      });
      
      final url = Uri.parse('${_config.httpBaseUrl}/api/v1/data');
      await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'X-User-Id': _authProvider.userId!
        },
        body: body,
      ).timeout(const Duration(seconds: 2)); // タイムアウトを短縮
      
      _serverConnectionAvailable = true;
      print("Muse data packet sent to server.");
    } catch (e) {
      _serverConnectionAvailable = false;
      // サーバー送信エラーは無視（リアルタイム表示に影響しない）
      print("Muse: Server send failed (ignored): $e");
    }
  }

  /// Y軸の表示範囲を自動調整
  /// データの最小・最大値に基づいて適切な範囲を設定
  void _updateYAxisRange() {
    if (_dataBuffer.isEmpty) return;
    
    // 全チャンネルの最小・最大値を計算
    int minVal = _dataBuffer.first.eegValues.reduce(min);
    int maxVal = _dataBuffer.first.eegValues.reduce(max);
    
    for (var point in _dataBuffer) {
      for (var val in point.eegValues) {
        if (val < minVal) minVal = val;
        if (val > maxVal) maxVal = val;
      }
    }
    
    // 現在の表示範囲を超える場合、範囲を拡張
    if (minVal < _displayYMin || maxVal > _displayYMax) {
      final range = maxVal - minVal;
      _displayYMin = (minVal - range * 0.15);  // 下に15%のマージン
      _displayYMax = (maxVal + range * 0.15);  // 上に15%のマージン
    }
  }

  /// BLE接続を切断し、リソースをクリーンアップ
  Future<void> disconnect() async {
    // ストリーミング停止
    if (_connectionState == MuseConnectionState.streaming) {
      await _stopMuseStreaming();
    }
    
    // サブスクリプションをキャンセル
    _valueSubscriptions.values.forEach((sub) => sub.cancel());
    _valueSubscriptions.clear();
    
    if (_targetDevice != null) {
      await _targetDevice!.disconnect();
    }
    
    // すべての状態をリセット
    _targetDevice = null;
    _streamToggleCharacteristic = null;
    _dataBuffer.clear();
    _valenceHistory.clear();
    _displayYMin = -200.0;
    _displayYMax = 200.0;
    _lastPacketIndex = -1;
    _sampleIndex = 0;
    _firstSample = true;
    connectedDeviceId = null;
    
    _updateConnectionState(MuseConnectionState.disconnected);
  }

  /// Museストリーミングを停止
  Future<void> _stopMuseStreaming() async {
    try {
      // 停止コマンド 'h' を送信
      await _writeMuseCommand('h');
      await Future.delayed(const Duration(milliseconds: 500));
      
      print("Muse streaming stopped");
    } catch (e) {
      print("Failed to stop Muse streaming: $e");
    }
  }

  /// ステータスメッセージを更新
  void _updateStatus(String message) {
    _statusMessage = message;
    notifyListeners();
  }

  /// リソースのクリーンアップ
  void _cleanUp() {
    _valueSubscriptions.values.forEach((sub) => sub.cancel());
    _valueSubscriptions.clear();
    _targetDevice = null;
    _streamToggleCharacteristic = null;
    _dataBuffer.clear();
    _valenceHistory.clear();
    _displayYMin = -200.0;
    _displayYMax = 200.0;
    _lastPacketIndex = -1;
    _sampleIndex = 0;
    _firstSample = true;
    connectedDeviceId = null;
    _serverConnectionAvailable = false;
    _updateConnectionState(MuseConnectionState.disconnected);
  }

  /// リソースの破棄
  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}

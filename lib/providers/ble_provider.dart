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
  static const int sampleRate = 250;
  static const double timeWindowSec = 5.0;
  static final int displayBufferSize = (sampleRate * timeWindowSec).toInt();
  final List<SensorDataPoint> _displayDataBuffer = [];
  final List<SensorDataPoint> _serverUploadBuffer = [];
  static const int samplesPerPayload = 250;
  final List<(DateTime, double)> _valenceHistory = [];

  // --- UI更新 ---
  bool _needsUiUpdate = false;
  Timer? _uiUpdateTimer;
  
  // --- スキャン状態管理 ---
  Timer? _scanTimeoutTimer;

  DateTime? _lastPayloadLogTime;

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

    _scanTimeoutTimer?.cancel();
    await _scanSubscription?.cancel();

    _scanSubscription = FlutterBluePlus.scanResults.listen(
      (results) {
        ScanResult? foundResult;
        for (ScanResult r in results) {
          final deviceName = r.device.platformName;
          if (deviceName.isEmpty) continue;
          
          bool isCustomDevice = deviceName.startsWith("ADS1299_EEG_NUS");
          bool isMuse = deviceName.toLowerCase().contains("muse");

          if ((targetDeviceType == DeviceType.customEeg && isCustomDevice) ||
              (targetDeviceType == DeviceType.muse2 && isMuse) ||
              (targetDeviceType == DeviceType.unknown && (isCustomDevice || isMuse))) {
            foundResult = r;
            break;
          }
        }

        if (foundResult != null) {
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
    
    if (device.platformName.startsWith("ADS1299_EEG_NUS")) {
      _deviceType = DeviceType.customEeg;
    } else if (device.platformName.toLowerCase().contains("muse")) {
      _deviceType = DeviceType.muse2;
    }

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
      try { await device.requestMtu(517); } catch (e) { debugPrint("[BLE] MTU request failed: $e"); }
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
        // lastValueStreamではなく、onValueReceivedを使用する
        _valueSubscriptions.add(txChar.onValueReceived.listen(_onDataDispatcher));
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
    // デバイス設定パケットのサイズチェック
    if (data.length < 88) {
      debugPrint("[BLE] ❌ Invalid DeviceConfigPacket size: ${data.length}");
      return;
    }
    final byteData = ByteData.view(Uint8List.fromList(data).buffer);
    final numChannels = byteData.getUint8(1);
    final newConfigs = <ElectrodeConfig>[];
    const headerSize = 8; // type(1) + num_ch(1) + reserved(6)
    const configStructSize = 10; // name(8) + type(1) + reserved(1)
    for (int i = 0; i < numChannels; i++) {
      final offset = headerSize + (i * configStructSize);
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
    if (_eegChannelCount == 0) {
      debugPrint("[BLE] ⚠️ Ignoring data chunk: channel count is not yet configured.");
      return;
    }

    _customEegReceiveBuffer.addAll(data);

    const int chunkedPacketSize = 504; // Header(4) + 25 samples * SampleData(20)
    const int sampleDataSize = 20;     // signals(8ch*2B) + trigger(1B) + reserved(3B)
    const int headerSize = 4;

    while (_customEegReceiveBuffer.length >= chunkedPacketSize) {
      final packetData = Uint8List.fromList(_customEegReceiveBuffer.sublist(0, chunkedPacketSize));
      _customEegReceiveBuffer.removeRange(0, chunkedPacketSize);

      final byteData = ByteData.view(packetData.buffer);

      if (byteData.getUint8(0) != 0x66) {
        debugPrint("[BLE] ❌ Invalid packet type. Expected 0x66, got 0x${byteData.getUint8(0).toRadixString(16)}.");
        continue;
      }

      final startIndex = byteData.getUint16(1, Endian.little);
      final numSamples = byteData.getUint8(3);
      final List<SensorDataPoint> newPoints = [];

      for (int i = 0; i < numSamples; i++) {
        final int sampleOffset = headerSize + (i * sampleDataSize);

        // EEG Signals (signed 16-bit)
        final List<int> eegValues = List.filled(_eegChannelCount, 0);
        for (int ch = 0; ch < _eegChannelCount; ch++) {
          eegValues[ch] = byteData.getInt16(sampleOffset + (ch * 2), Endian.little);
        }
        
        // Trigger state
        const int triggerOffsetInSample = 16; // 8 channels * 2 bytes
        final int triggerState = byteData.getUint8(sampleOffset + triggerOffsetInSample);

        newPoints.add(SensorDataPoint(
          sampleIndex: startIndex + i,
          eegValues: eegValues,
          accel: const [0, 0, 0],
          gyro: const [0, 0, 0],
          triggerState: triggerState,
          timestamp: DateTime.now(),
        ));
      }
      if (newPoints.isNotEmpty) {
        _updateDataBuffer(newPoints);
      }
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
        const double microVoltPerLsb12bit = 0.48828125;
        const double center12bit = 2048.0;
        final newPoints = <SensorDataPoint>[];
        for (int i = 0; i < 12; i++) {
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
                accel: const [0, 0, 0],
                gyro: const [0, 0, 0],
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
    if (_eegChannelCount == 0 || _serverUploadBuffer.length < samplesPerPayload) return;

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
        signalsBytes.setInt16(i * 2, sample.eegValues[i], Endian.little);
      }
      builder.add(signalsBytes.buffer.asUint8List());

      if (_deviceType == DeviceType.customEeg) {
        final triggerBytes = ByteData(2);
        triggerBytes.setUint16(0, sample.triggerState, Endian.little);
        builder.add(triggerBytes.buffer.asUint8List());
      }
      // モーションデータは0で埋める
      builder.add(Uint8List(12)); 
      
      final impedanceBytes = Uint8List(totalChannelsToServer)..fillRange(0, totalChannelsToServer, 255);
      builder.add(impedanceBytes);
    }

    final uncompressedPayload = builder.toBytes();
    
    final now = DateTime.now();
    final shouldLog = _lastPayloadLogTime == null || now.difference(_lastPayloadLogTime!).inSeconds >= 10;
    
    if (shouldLog) {
      debugPrint("--- PAYLOAD LOG (approx. every 10s) ---");
      final snippet = uncompressedPayload.sublist(0, min(64, uncompressedPayload.length));
      debugPrint("[UNCOMPRESSED] Size: ${uncompressedPayload.length} bytes. Snippet: ${snippet.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}...");
    }

    final compressedPayload = await uncompressedPayload.compress();
    
    if (shouldLog) {
      if (compressedPayload != null) {
        final snippet = compressedPayload.sublist(0, min(48, compressedPayload.length)); // Base64は長くなるので短めに
        debugPrint("[COMPRESSED] Size: ${compressedPayload.length} bytes. Snippet (Base64): ${base64Encode(snippet)}...");
      } else {
        debugPrint("[COMPRESSED] Compression failed.");
      }
      _lastPayloadLogTime = now;
      debugPrint("---------------------------------------");
    }

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
    
    if (_deviceType == DeviceType.customEeg) {
      // customEegのデータ(int16)は既に0中心なので、そのまま2乗する
      for (var point in recentData) {
        for (var i in leftIndices) powerLeft += pow(point.eegValues[i], 2);
        for (var i in rightIndices) powerRight += pow(point.eegValues[i], 2);
      }
    } else {
      // Muse用のロジック (uint16を想定)
      for (var point in recentData) {
        for (var i in leftIndices) powerLeft += pow(point.eegValues[i] - 32768, 2);
        for (var i in rightIndices) powerRight += pow(point.eegValues[i] - 32768, 2);
      }
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
    if (_targetDevice != null && _targetDevice!.isConnected) {
        try {
            await _targetDevice!.disconnect();
        } catch(e) {
            debugPrint("Error during disconnect: $e");
        }
    }
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
    _statusMessage = message;
    notifyListeners();
  }
}


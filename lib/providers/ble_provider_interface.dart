import '../models/sensor_data.dart';

/// BLEプロバイダーの共通インターフェース
/// ESP32とMuse2の両方のプロバイダーが実装する必要があるメソッドを定義
abstract class BleProviderInterface {
  /// 接続状態を取得
  bool get isConnected;
  
  /// ステータスメッセージを取得
  String get statusMessage;
  
  /// 表示用データを取得
  List<SensorDataPoint> get displayData;
  
  /// 感情分析履歴を取得
  List<(DateTime, double)> get valenceHistory;
  
  /// デバイスIDを取得
  String? get deviceId;
  
  /// チャンネル数を取得
  int get channelCount;
  
  /// スキャンを開始
  Future<void> startScan();
  
  /// 接続を切断
  Future<void> disconnect();
}

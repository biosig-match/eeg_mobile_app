import 'package:flutter/foundation.dart';
import '../utils/config.dart';
import 'auth_provider.dart';
import 'ble_provider_interface.dart';
import 'ble_provider.dart';
import 'muse_ble_provider.dart';

/// デバイスタイプを表す列挙型
enum DeviceType {
  esp32,  // ESP32デバイス
  muse2,  // Muse2デバイス
}

/// BLEプロバイダーのファクトリクラス
/// デバイスタイプに応じて適切なプロバイダーを生成
class BleProviderFactory with ChangeNotifier {
  final ServerConfig _config;
  final AuthProvider _authProvider;
  
  BleProviderInterface? _currentProvider;
  DeviceType? _currentDeviceType;
  
  // ゲッター
  BleProviderInterface? get currentProvider {
    print("BleProviderFactory: currentProvider getter called, provider: ${_currentProvider?.runtimeType}");
    return _currentProvider;
  }
  DeviceType? get currentDeviceType => _currentDeviceType;
  bool get hasProvider => _currentProvider != null;
  
  BleProviderFactory(this._config, this._authProvider) {
    // デフォルトでESP32プロバイダーを作成
    _currentProvider = createProvider(DeviceType.esp32);
    _currentDeviceType = DeviceType.esp32;
    print("BleProviderFactory: Initialized with default ESP32 provider");
  }
  
  /// 指定されたデバイスタイプのプロバイダーを作成
  BleProviderInterface createProvider(DeviceType deviceType) {
    switch (deviceType) {
      case DeviceType.esp32:
        return BleProvider(_config, _authProvider);
      case DeviceType.muse2:
        return MuseBleProvider(_config, _authProvider);
    }
  }
  
  /// プロバイダーを切り替え
  void switchProvider(DeviceType deviceType) {
    print("BleProviderFactory: Switching to device type: $deviceType");
    
    // 既存のプロバイダーを破棄
    if (_currentProvider != null) {
      print("BleProviderFactory: Disconnecting current provider");
      _currentProvider!.disconnect();
    }
    
    // 新しいプロバイダーを作成
    _currentProvider = createProvider(deviceType);
    _currentDeviceType = deviceType;
    print("BleProviderFactory: Created new provider: ${_currentProvider.runtimeType}");
    print("BleProviderFactory: Calling notifyListeners()");
    
    // 強制的にUI更新を実行
    Future.microtask(() {
      print("BleProviderFactory: Force UI update");
      notifyListeners();
    });
  }
  
  /// 現在のプロバイダーを取得（null安全）
  BleProviderInterface? get provider => _currentProvider;
  
  /// プロバイダーをリセット
  void reset() {
    if (_currentProvider != null) {
      _currentProvider!.disconnect();
    }
    _currentProvider = null;
    _currentDeviceType = null;
    notifyListeners();
  }
  
  @override
  void dispose() {
    if (_currentProvider != null) {
      _currentProvider!.disconnect();
    }
    super.dispose();
  }
}

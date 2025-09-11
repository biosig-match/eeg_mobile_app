import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart';

class ConfigLoader {
  static Future<Map<String, String>> loadEnv({String fileName = '.env'}) async {
    // (この部分は変更なし)
    try {
      final content = await rootBundle.loadString(fileName);
      final map = <String, String>{};
      for (final rawLine in content.split('\n')) {
        final line = rawLine.trim();
        if (line.isEmpty || line.startsWith('#')) continue;
        final idx = line.indexOf('=');
        if (idx <= 0) continue;
        final key = line.substring(0, idx).trim();
        final value = line.substring(idx + 1).trim();
        if (key.isNotEmpty) map[key] = value;
      }
      return map;
    } catch (e) {
      throw FlutterError(
        "Failed to load .env. Ensure 'mobile_app/.env' exists and is listed under assets in pubspec.yaml. Original error: $e",
      );
    }
  }
}

class ServerConfig {
  final String protocol;
  final String ip;
  final int port;

  ServerConfig({required this.protocol, required this.ip, required this.port});

  // ★★★ ここから修正しました ★★★
  String get httpBaseUrl => '$protocol://$ip:$port';
  
  String get wsBaseUrl {
    final wsProtocol = protocol == 'https' ? 'wss' : 'ws';
    return '$wsProtocol://$ip:$port';
  }
  // ★★★ 修正はここまで ★★★

  factory ServerConfig.fromEnv(Map<String, String> env) {
    // (この部分は変更なし)
    final errors = <String>[];
    final protocol = env['SERVER_PROTOCOL'];
    if (protocol == null || protocol.isEmpty) {
      errors.add("Missing SERVER_PROTOCOL (expected 'http' or 'https' in .env)");
    }
    final ip = env['SERVER_IP'];
    if (ip == null || ip.isEmpty) {
      errors.add("Missing SERVER_IP in .env");
    }
    final portStr = env['SERVER_PORT'];
    int? port;
    if (portStr == null || portStr.isEmpty) {
      errors.add("Missing SERVER_PORT in .env");
    } else {
      port = int.tryParse(portStr);
      if (port == null || port <= 0 || port > 65535) {
        errors.add("Invalid SERVER_PORT '$portStr'");
      }
    }
    if (errors.isNotEmpty) {
      throw FlutterError("Invalid .env configuration:\n - ${errors.join("\n - ")}");
    }
    return ServerConfig(
      protocol: protocol!.toLowerCase(),
      ip: ip!,
      port: port!,
    );
  }
}
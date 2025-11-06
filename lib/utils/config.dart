import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart';

// .envファイルをロードするためのクラス
class ConfigLoader {
  static Future<Map<String, String>> loadEnv({String fileName = '.env'}) async {
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
        "Failed to load .env. Ensure '.env' exists and is listed under assets in pubspec.yaml. Original error: $e",
      );
    }
  }
}

// サーバー設定を保持するクラス
class ServerConfig {
  final String protocol;
  final String ip;
  final int port;
  final String defaultUserId;
  final String? baseUrlOverride;

  ServerConfig({
    required this.protocol,
    required this.ip,
    required this.port,
    required this.defaultUserId,
    this.baseUrlOverride,
  });

  String get httpBaseUrl {
    if (baseUrlOverride != null && baseUrlOverride!.isNotEmpty) {
      final trimmed =
          baseUrlOverride!.endsWith('/') && baseUrlOverride!.length > 1
              ? baseUrlOverride!.substring(0, baseUrlOverride!.length - 1)
              : baseUrlOverride!;
      return trimmed;
    }
    final normalizedHost = ip.trim();
    final useDefaultPort = (protocol == 'https' && port == 443) ||
        (protocol == 'http' && port == 80);
    final uri = Uri(
      scheme: protocol,
      host: normalizedHost,
      port: useDefaultPort ? null : port,
    );
    return uri.toString();
  }

  String get wsBaseUrl {
    final base = httpBaseUrl;
    final parsed = Uri.tryParse(base);
    if (parsed != null && parsed.hasAuthority) {
      final wsScheme = parsed.scheme == 'https' ? 'wss' : 'ws';
      final defaultPort = parsed.scheme == 'https' ? 443 : 80;
      final wsUri = Uri(
        scheme: wsScheme,
        host: parsed.host,
        port: parsed.hasPort ? parsed.port : defaultPort,
        path: parsed.path,
      );
      return wsUri.toString();
    }
    final wsProtocol = protocol == 'https' ? 'wss' : 'ws';
    final useDefaultPort = (protocol == 'https' && port == 443) ||
        (protocol == 'http' && port == 80);
    final uri = Uri(
      scheme: wsProtocol,
      host: ip.trim(),
      port: useDefaultPort ? null : port,
    );
    return uri.toString();
  }

  factory ServerConfig.fromEnv(Map<String, String> env) {
    final errors = <String>[];
    final rawBaseUrl = env['SERVER_BASE_URL']?.trim();
    String? baseUrlOverride;
    if (rawBaseUrl != null && rawBaseUrl.isNotEmpty) {
      final parsed = Uri.tryParse(rawBaseUrl);
      if (parsed == null ||
          parsed.scheme.isEmpty ||
          parsed.host.isEmpty ||
          (!parsed.isScheme('http') && !parsed.isScheme('https'))) {
        errors.add(
            "Invalid SERVER_BASE_URL '$rawBaseUrl' (expected absolute http/https URL)");
      } else {
        final sanitized = parsed.toString();
        baseUrlOverride = sanitized.endsWith('/')
            ? sanitized.substring(0, sanitized.length - 1)
            : sanitized;
      }
    }
    final protocol = env['SERVER_PROTOCOL'];
    if (protocol == null || protocol.isEmpty) {
      errors
          .add("Missing SERVER_PROTOCOL (expected 'http' or 'https' in .env)");
    }
    final ip = env['SERVER_IP'];
    if ((ip == null || ip.isEmpty) && baseUrlOverride == null) {
      errors.add("Missing SERVER_IP in .env (or provide SERVER_BASE_URL)");
    }
    final portStr = env['SERVER_PORT'];
    int? port;
    if (portStr == null || portStr.isEmpty) {
      if (baseUrlOverride == null) {
        errors.add("Missing SERVER_PORT in .env");
      }
    } else {
      port = int.tryParse(portStr);
      if (port == null || port <= 0 || port > 65535) {
        errors.add("Invalid SERVER_PORT '$portStr'");
      }
    }
    if (errors.isNotEmpty) {
      throw FlutterError(
          "Invalid .env configuration:\n - ${errors.join("\n - ")}");
    }
    final rawUserId = env['DEFAULT_USER_ID']?.trim();
    final defaultUserId = (rawUserId != null && rawUserId.isNotEmpty)
        ? rawUserId
        : 'user-default-01';
    return ServerConfig(
      protocol: protocol!.toLowerCase(),
      ip: (ip ?? '').trim(),
      port: port ?? (protocol.toLowerCase() == 'https' ? 443 : 80),
      defaultUserId: defaultUserId,
      baseUrlOverride: baseUrlOverride,
    );
  }
}

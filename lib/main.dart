import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/analysis_provider.dart';
import 'providers/auth_provider.dart';
import 'providers/ble_provider.dart';
import 'providers/media_provider.dart';
import 'providers/session_provider.dart';
import 'screens/home_screen.dart';
import 'utils/config.dart';

void main() async {
  // main関数で非同期処理を呼び出すためのおまじない
  WidgetsFlutterBinding.ensureInitialized();
  // .envファイルから設定をロード
  final env = await ConfigLoader.loadEnv();
  final serverConfig = ServerConfig.fromEnv(env);

  runApp(MyApp(serverConfig: serverConfig));
}

class MyApp extends StatelessWidget {
  final ServerConfig serverConfig;
  const MyApp({super.key, required this.serverConfig});

  @override
  Widget build(BuildContext context) {
    // 複数のProviderをアプリケーション全体で利用可能にする
    return MultiProvider(
      providers: [
        // 認証情報を管理 (他のProviderが利用)
        ChangeNotifierProvider(create: (context) => AuthProvider()),
        // セッション情報を管理 (他のProviderが利用)
        ChangeNotifierProxyProvider<AuthProvider, SessionProvider>(
          create: (context) =>
              SessionProvider(serverConfig, context.read<AuthProvider>()),
          update: (_, auth, previous) => SessionProvider(serverConfig, auth),
        ),
        // BLE接続とセンサーデータ転送を管理
        ChangeNotifierProxyProvider<AuthProvider, BleProvider>(
          create: (context) =>
              BleProvider(serverConfig, context.read<AuthProvider>()),
          update: (_, auth, previous) => BleProvider(serverConfig, auth),
        ),
        // 解析結果の取得を管理
        ChangeNotifierProxyProvider<AuthProvider, AnalysisProvider>(
          create: (context) =>
              AnalysisProvider(serverConfig, context.read<AuthProvider>()),
          update: (_, auth, previous) => AnalysisProvider(serverConfig, auth),
        ),
        // メディア(画像・音声)の記録と転送を管理
        ChangeNotifierProxyProvider2<AuthProvider, SessionProvider,
            MediaProvider>(
          create: (context) => MediaProvider(serverConfig,
              context.read<AuthProvider>(), context.read<SessionProvider>()),
          update: (_, auth, session, previous) =>
              MediaProvider(serverConfig, auth, session),
        ),
      ],
      child: MaterialApp(
        title: 'EEG BIDS Collector',
        theme: ThemeData.dark().copyWith(
          primaryColor: Colors.cyanAccent,
          scaffoldBackgroundColor: const Color(0xFF121212),
          cardColor: const Color(0xFF1E1E1E),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF1E1E1E),
            elevation: 0,
          ),
          colorScheme: const ColorScheme.dark(
            primary: Colors.cyanAccent,
            secondary: Colors.blueAccent,
          ),
        ),
        home: const HomeScreen(),
      ),
    );
  }
}

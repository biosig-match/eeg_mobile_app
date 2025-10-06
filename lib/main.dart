import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/analysis_provider.dart';
import 'providers/auth_provider.dart';
import 'providers/bids_provider.dart';
import 'providers/ble_provider.dart';
import 'providers/media_provider.dart';
import 'providers/session_provider.dart';
import 'providers/stimulus_provider.dart';
import 'screens/home_screen.dart';
import 'utils/config.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final env = await ConfigLoader.loadEnv();
  final serverConfig = ServerConfig.fromEnv(env);

  runApp(MyApp(serverConfig: serverConfig));
}

class MyApp extends StatelessWidget {
  final ServerConfig serverConfig;
  const MyApp({super.key, required this.serverConfig});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (context) => AuthProvider()),
        ChangeNotifierProxyProvider<AuthProvider, SessionProvider>(
          create: (context) =>
              SessionProvider(serverConfig, context.read<AuthProvider>()),
          update: (_, auth, previous) => SessionProvider(serverConfig, auth),
        ),
        ChangeNotifierProxyProvider<AuthProvider, BleProvider>(
          create: (context) =>
              BleProvider(serverConfig, context.read<AuthProvider>()),
          update: (_, auth, previous) => BleProvider(serverConfig, auth),
        ),
        ChangeNotifierProxyProvider<AuthProvider, AnalysisProvider>(
          create: (context) =>
              AnalysisProvider(serverConfig, context.read<AuthProvider>()),
          update: (_, auth, previous) => AnalysisProvider(serverConfig, auth),
        ),
        ChangeNotifierProxyProvider2<AuthProvider, SessionProvider,
            MediaProvider>(
          create: (context) => MediaProvider(serverConfig,
              context.read<AuthProvider>(), context.read<SessionProvider>()),
          update: (_, auth, session, previous) =>
              MediaProvider(serverConfig, auth, session),
        ),
        ChangeNotifierProxyProvider<AuthProvider, StimulusProvider>(
          create: (context) =>
              StimulusProvider(serverConfig, context.read<AuthProvider>()),
          update: (_, auth, __) => StimulusProvider(serverConfig, auth),
        ),
        ChangeNotifierProxyProvider<AuthProvider, BidsProvider>(
          create: (context) =>
              BidsProvider(serverConfig, context.read<AuthProvider>()),
          update: (_, auth, __) => BidsProvider(serverConfig, auth),
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

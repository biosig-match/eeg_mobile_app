import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/ble_provider.dart';
import 'providers/analysis_provider.dart';
import 'providers/experiment_provider.dart';
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
        ChangeNotifierProvider(create: (context) => ExperimentProvider(serverConfig)),
        // ★★★ ExperimentProviderに依存するように変更 ★★★
        ChangeNotifierProxyProvider<ExperimentProvider, BleProvider>(
          create: (context) => BleProvider(serverConfig),
          update: (context, experimentProvider, bleProvider) {
            if (bleProvider == null) throw ArgumentError.notNull('bleProvider');
            // BleProviderにExperimentProviderのインスタンスを渡す
            bleProvider.experimentProvider = experimentProvider;
            return bleProvider;
          },
        ),
        ChangeNotifierProvider(create: (context) => AnalysisProvider(serverConfig)),
      ],
      child: MaterialApp(
        title: 'EEG BIDS Collector',
        theme: ThemeData.dark().copyWith(
          primaryColor: Colors.cyanAccent,
          floatingActionButtonTheme: const FloatingActionButtonThemeData(
            foregroundColor: Colors.white,
          ),
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
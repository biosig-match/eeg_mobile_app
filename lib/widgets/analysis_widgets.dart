import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:collection/collection.dart';
import 'package:intl/intl.dart';
import '../providers/ble_provider.dart';
import 'package:provider/provider.dart';

class AnalysisImageViewer extends StatelessWidget {
  final Uint8List? Function() imageProvider;
  const AnalysisImageViewer({super.key, required this.imageProvider});

  @override
  Widget build(BuildContext context) {
    final imageData = imageProvider();
    if (imageData == null) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text("Waiting for analysis results...", style: TextStyle(color: Colors.white70)),
          ],
        ),
      );
    }
    return InteractiveViewer(
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Image.memory(imageData, gaplessPlayback: true),
      ),
    );
  }
}

class ValenceMonitor extends StatelessWidget {
  const ValenceMonitor({super.key});

  @override
  Widget build(BuildContext context) {
    final bleProvider = context.watch<BleProvider>();
    final history = bleProvider.valenceHistory;

    if (history.isEmpty) {
      return const Center(child: Text("Calculating valence from raw data...", style: TextStyle(color: Colors.white70)));
    }

    final spots = history.map((e) {
      return FlSpot(e.$1.millisecondsSinceEpoch.toDouble(), e.$2);
    }).toList();

    final minVal = spots.map((e) => e.y).min;
    final maxVal = spots.map((e) => e.y).max;
    final range = (maxVal - minVal).abs();
    final minY = minVal - range * 0.2;
    final maxY = maxVal + range * 0.2;

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: LineChart(
        LineChartData(
          minY: minY,
          maxY: maxY,
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              color: Colors.amberAccent,
              barWidth: 2.5,
              dotData: const FlDotData(show: false),
            )
          ],
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 40,
                getTitlesWidget: (value, meta) {
                  // ★修正: fl_chart v1.1.0+ ではSideTitleWidgetは不要になりました。
                  // Textウィジェットを直接返します。
                  return Text(
                    meta.formattedValue,
                    style: const TextStyle(color: Colors.white70, fontSize: 10),
                  );
                },
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 30,
                interval: 30000, // 30秒
                getTitlesWidget: (value, meta) {
                  final dt = DateTime.fromMillisecondsSinceEpoch(value.toInt());
                  // ★修正: fl_chart v1.1.0+ ではSideTitleWidgetは不要になりました。
                  // Textウィジェットを直接返します。
                  return Text(DateFormat('HH:mm:ss').format(dt), style: const TextStyle(color: Colors.white70, fontSize: 10));
                },
              ),
            ),
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          gridData: const FlGridData(show: true),
          borderData: FlBorderData(show: true),
        ),
      ),
    );
  }
}
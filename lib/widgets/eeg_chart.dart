import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/ble_provider.dart';

// ★★★ マルチチャンネルチャートを新設 ★★★
class EegMultiChannelChart extends StatelessWidget {
  final List<SensorDataPoint> data;
  final int channelCount;

  const EegMultiChannelChart({
    super.key,
    required this.data,
    required this.channelCount,
  });

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) {
      return const Center(child: Text("Connecting to device..."));
    }
    // ListView.builderを使うことで、チャンネル数が増えても描画できる
    return ListView.builder(
      itemCount: channelCount,
      itemBuilder: (context, index) {
        return EegSingleChannelChart(channelIndex: index);
      },
    );
  }
}

// ★★★ シングルチャンネルチャートを簡略化 ★★★
class EegSingleChannelChart extends StatelessWidget {
  final int channelIndex;

  const EegSingleChannelChart({super.key, required this.channelIndex});

  @override
  Widget build(BuildContext context) {
    // Providerをwatchして、データが更新されるたびに再描画する
    final bleProvider = context.watch<BleProvider>();
    final dataPoints = bleProvider.displayData;

    if (dataPoints.isEmpty || dataPoints.first.eegValues.length <= channelIndex) {
      return const SizedBox(height: 50); // 空のSizedBox
    }

    final List<FlSpot> spots = [];
    for (int i = 0; i < dataPoints.length; i++) {
      spots.add(FlSpot(i.toDouble(), dataPoints[i].eegValues[channelIndex].toDouble()));
    }

    return AspectRatio(
      aspectRatio: 6, // 縦幅を狭くする
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 8.0),
        child: LineChart(
          LineChartData(
            minY: bleProvider.displayYMin,
            maxY: bleProvider.displayYMax,
            lineBarsData: [
              LineChartBarData(
                spots: spots,
                isCurved: false,
                color: Colors.cyan,
                barWidth: 1.5,
                dotData: const FlDotData(show: false),
              ),
            ],
            titlesData: const FlTitlesData(show: false), // タイトルは非表示
            gridData: const FlGridData(show: false),
            borderData: FlBorderData(show: false),
          ),
        ),
      ),
    );
  }
}
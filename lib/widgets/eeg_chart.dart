import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../models/sensor_data.dart';

class EegMultiChannelChart extends StatelessWidget {
  final List<SensorDataPoint> data;
  final int channelCount;

  const EegMultiChannelChart(
      {super.key, required this.data, this.channelCount = 8});

  @override
  Widget build(BuildContext context) {
    return LineChart(
      LineChartData(
        lineBarsData: List.generate(channelCount, (channelIndex) {
          final double verticalOffset =
              (channelCount - 1 - channelIndex) * 500.0;
          return LineChartBarData(
            spots: data.asMap().entries.map((entry) {
              final index = entry.key;
              final point = entry.value;
              return FlSpot(
                  index.toDouble(),
                  point.eegValues[channelIndex].toDouble() -
                      2048 +
                      verticalOffset);
            }).toList(),
            isCurved: false,
            color: Colors.cyanAccent,
            barWidth: 1.5,
            dotData: const FlDotData(show: false),
          );
        }),
        gridData: const FlGridData(show: false),
        titlesData: const FlTitlesData(
          leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(
            show: true, border: Border.all(color: Colors.grey[800]!)),
        minY: -500,
        maxY: (channelCount) * 500,
      ),
    );
  }
}

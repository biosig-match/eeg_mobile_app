import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'dart:math';
import '../models/sensor_data.dart';
import '../providers/ble_provider.dart';
import 'package:provider/provider.dart';

/// 複数チャンネルのEEGを縦に並べて表示する。
/// 右上の「範囲フィット」ボタンで、現時点のバッファ最小最大を
/// チャンネルごとに固定レンジとして適用する（スナップショット方式）。
class EegMultiChannelChart extends StatefulWidget {
  /// 表示するセンサーデータのリスト
  final List<SensorDataPoint> data;

  /// EEGチャンネル数
  final int channelCount;

  /// データのサンプリングレート (Hz)
  final int sampleRate;

  const EegMultiChannelChart({
    super.key,
    required this.data,
    this.channelCount = 8,
    required this.sampleRate,
  });
  @override
  State<EegMultiChannelChart> createState() => _EegMultiChannelChartState();
}

class _EegMultiChannelChartState extends State<EegMultiChannelChart> {
  // チャンネルごとにボタン押下時の最小最大を固定保持
  final Map<int, (double, double)> _lockedRanges = {};

  void _fitRanges() {
    if (widget.data.isEmpty) return;

    // Providerから現在のデバイスの変換係数を取得
    final bleProvider = context.read<BleProvider>();
    final lsbToMicrovolts = bleProvider.deviceProfile?.lsbToMicrovolts;
    if (lsbToMicrovolts == null) return; // プロファイル未設定

    // データが存在する最大チャンネル数を推定
    int maxChannelsInData = 0;
    for (final p in widget.data) {
      final len = p.eegValues.length;
      if (len > maxChannelsInData) maxChannelsInData = len;
    }

    final int channelsToProcess = min(widget.channelCount, maxChannelsInData);
    final Map<int, (double, double)> next = {};
    for (int ch = 0; ch < channelsToProcess; ch++) {
      double? localMin;
      double? localMax;
      for (final p in widget.data) {
        if (ch < p.eegValues.length) {
          // 常に生のADC値から、取得した係数でµVに変換
          final y = p.eegValues[ch].toDouble() * lsbToMicrovolts;
          localMin = (localMin == null) ? y : min(y, localMin);
          localMax = (localMax == null) ? y : max(y, localMax);
        }
      }
      if (localMin != null && localMax != null) {
        // クランプ前の生データでの範囲に，視認性のため5%（最低±1µV）の余白を追加
        final double span = (localMax - localMin).abs();
        final double pad = span > 0 ? max(1.0, span * 0.05) : 1.0;
        next[ch] = (localMin - pad, localMax + pad);
      }
    }
    setState(() {
      _lockedRanges
        ..clear()
        ..addAll(next);
    });
  }

  @override
  Widget build(BuildContext context) {
    // データが空の場合は待機メッセージを表示
    if (widget.data.isEmpty) {
      return Center(
        child: Container(
          padding: const EdgeInsets.all(16.0),
          decoration: BoxDecoration(
            color: const Color(0xff232d37),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white24),
          ),
          child: Text('受信待機中... (データ: ${widget.data.length}点)'),
        ),
      );
    }

    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6.0),
            child: OutlinedButton.icon(
              onPressed: _fitRanges,
              icon: const Icon(Icons.fullscreen, size: 16),
              label: const Text('範囲フィット'),
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 32),
                  visualDensity: VisualDensity.compact),
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: widget.channelCount,
            itemBuilder: (context, index) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 4.0),
                child: SizedBox(
                  height: 160,
                  child: _SingleChannelChart(
                    data: widget.data,
                    sampleRate: widget.sampleRate,
                    channelIndex: index,
                    yMinLocked: _lockedRanges[index]?.$1,
                    yMaxLocked: _lockedRanges[index]?.$2,
                    showBottomTitles: true,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 単一チャンネルのEEG可視化。
class _SingleChannelChart extends StatelessWidget {
  final List<SensorDataPoint> data;
  final int sampleRate;
  final int channelIndex;
  final bool showBottomTitles;
  final double? yMinLocked;
  final double? yMaxLocked;

  const _SingleChannelChart({
    required this.data,
    required this.sampleRate,
    required this.channelIndex,
    required this.yMinLocked,
    required this.yMaxLocked,
    required this.showBottomTitles,
  });

  @override
  Widget build(BuildContext context) {
    // Providerから変換係数を取得
    final bleProvider = context.watch<BleProvider>();
    final lsbToMicrovolts = bleProvider.deviceProfile?.lsbToMicrovolts;

    const double defaultYMin = -100.0;
    const double defaultYMax = 100.0;

    // ボタン押下時に固定された範囲があればそれを使用、無ければ既定。
    final double yMin = yMinLocked ?? defaultYMin;
    final double yMax = yMaxLocked ?? defaultYMax;

    return Container(
      padding: const EdgeInsets.only(top: 16, right: 16, bottom: 8),
      child: LineChart(
        LineChartData(
          backgroundColor: const Color(0xff232d37),

          // === データプロット定義 ===
          lineBarsData: [
            LineChartBarData(
              spots: data
                  .asMap()
                  .entries
                  .map((entry) {
                    final index = entry.key;
                    final point = entry.value;

                    if (lsbToMicrovolts == null ||
                        channelIndex >= point.eegValues.length) {
                      return FlSpot.nullSpot;
                    }

                    // 常に生のADC値からµVに変換してプロット
                    final y = point.eegValues[channelIndex].toDouble() *
                        lsbToMicrovolts;
                    final double yClamped = y.clamp(yMin, yMax);

                    return FlSpot(
                      index.toDouble(), // X座標はデータのインデックス
                      yClamped,
                    );
                  })
                  .where((spot) => spot != FlSpot.nullSpot)
                  .toList(),
              isCurved: false,
              color: Colors.cyanAccent,
              barWidth: 1.2,
              dotData: const FlDotData(show: false),
            )
          ],

          // === 軸範囲 ===
          minX: 0,
          maxX: (data.length - 1).toDouble(),
          minY: yMin,
          maxY: yMax,

          // === グリッド線 ===
          gridData: FlGridData(
            show: true,
            drawVerticalLine: true,
            verticalInterval: sampleRate.toDouble(), // 1秒ごとに縦線
            drawHorizontalLine: true,
            getDrawingHorizontalLine: (value) {
              if (value == 0) {
                return FlLine(
                  color: Colors.white.withOpacity(0.3),
                  strokeWidth: 0.8,
                );
              }
              return const FlLine(
                color: Colors.white24,
                strokeWidth: 0.5,
              );
            },
            getDrawingVerticalLine: (value) => const FlLine(
              color: Colors.white24,
              strokeWidth: 0.5,
            ),
          ),

          // === 軸タイトルと目盛り ===
          titlesData: FlTitlesData(
            topTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: showBottomTitles,
                reservedSize: 30.0,
                interval: sampleRate.toDouble(),
                getTitlesWidget: (value, meta) {
                  final index = value.toInt();
                  if (index < 0 || index >= data.length) {
                    return const SizedBox.shrink();
                  }
                  final time = data[index].timestamp;
                  final formattedTime =
                      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
                  if (index >= meta.max) return const SizedBox.shrink();

                  return SideTitleWidget(
                    axisSide: meta.axisSide,
                    space: 4.0,
                    child: Text(
                      formattedTime,
                      style: TextStyle(
                          color: Colors.grey[400],
                          fontSize: 9.0,
                          overflow: TextOverflow.ellipsis),
                    ),
                  );
                },
              ),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 45.0,
                getTitlesWidget: (value, meta) {
                  if (value == 0) {
                    return SideTitleWidget(
                      axisSide: meta.axisSide,
                      space: 4.0,
                      child: Text('Ch${channelIndex + 1}',
                          style: TextStyle(
                              color: Colors.grey[400], fontSize: 10.0)),
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
            ),
            rightTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 50.0,
                interval: (yMax - yMin).abs(),
                getTitlesWidget: (value, meta) {
                  if (value == 0) {
                    return const SizedBox.shrink();
                  }
                  return SideTitleWidget(
                    axisSide: meta.axisSide,
                    space: 4.0,
                    child: Text('${value.toStringAsFixed(0)} µV',
                        style:
                            TextStyle(color: Colors.grey[400], fontSize: 10.0)),
                  );
                },
              ),
            ),
          ),

          borderData: FlBorderData(
            show: true,
            border: Border.all(color: Colors.white24),
          ),
          lineTouchData: const LineTouchData(enabled: false),
        ),
        duration: Duration.zero,
      ),
    );
  }
}

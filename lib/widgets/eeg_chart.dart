import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'dart:math';
import '../models/sensor_data.dart';

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

    // ADS1299用の変換係数を定義 (Vref=4.5V, Gain=24, 24bitADCを16bitで利用)
    // LSB(16bit) = (Vref / Gain) / (2^23) * 2^8  [V]
    const double ads1299MicroVoltsPerLsb = (4.5 / 24.0) * 256.0 / 8388608.0 * 1000000.0;

    // データが存在する最大チャンネル数を推定
    int maxChannelsInData = 0;
    for (final p in widget.data) {
      final len = p.eegMicroVolts?.length ?? p.eegValues.length;
      if (len > maxChannelsInData) maxChannelsInData = len;
    }

    final int channelsToProcess = min(widget.channelCount, maxChannelsInData);
    final Map<int, (double, double)> next = {};
    for (int ch = 0; ch < channelsToProcess; ch++) {
      double? localMin;
      double? localMax;
      for (final p in widget.data) {
        double? y;
        if (p.eegMicroVolts != null && ch < p.eegMicroVolts!.length) {
          // 既にμVに変換されているデータ (Muse2など)
          y = p.eegMicroVolts![ch];
        } else if (ch < p.eegValues.length) {
          // 生データからμVに変換 (ADS1299を想定)
          // ADS1299は符号付き16bitなので、オフセットなしで係数を掛ける
          y = p.eegValues[ch].toDouble() * ads1299MicroVoltsPerLsb;
        }
        if (y == null) continue;
        localMin = (localMin == null) ? y : min(y, localMin);
        localMax = (localMax == null) ? y : max(y, localMax);
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
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 32), visualDensity: VisualDensity.compact),
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
/// - y値は受信時に変換済みのµVがあればそれを採用、なければADS1299用の16bit換算にフォールバック。
/// - yレンジは親からロックされた値があればそれを使用、無ければ既定±100µV。
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
    // ADS1299用の変換係数
    const double ads1299MicroVoltsPerLsb = (4.5 / 24.0) * 256.0 / 8388608.0 * 1000000.0; // 約 5.722
    const double defaultYMin = -100.0;
    const double defaultYMax = 100.0;

    // ボタン押下時に固定された範囲があればそれを使用、無ければ既定。
    final double yMin = yMinLocked ?? defaultYMin;
    final double yMax = yMaxLocked ?? defaultYMax;

    return Container(
      padding: const EdgeInsets.only(top: 16, right: 16, bottom: 8),
      // プロットエリア以外の背景は、Scaffoldの背景色に依存
      child: LineChart(
        LineChartData(
          // プロットエリアの背景色
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

                    double? y;
                    if (point.eegMicroVolts != null && channelIndex < point.eegMicroVolts!.length) {
                      // 変換済みデータ (Muse2など)
                      y = point.eegMicroVolts![channelIndex];
                    } else if (channelIndex < point.eegValues.length) {
                      // 生データから変換 (ADS1299を想定)
                      y = point.eegValues[channelIndex].toDouble() * ads1299MicroVoltsPerLsb;
                    }

                    if (y == null) return FlSpot.nullSpot;
                    // 表示は視認性のためにレンジ内へクランプ
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
              // 0のベースラインのみ少し濃い線にする
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

            // --- 下軸（横軸：時刻）---
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: showBottomTitles, // 表示/非表示を切り替え
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

            // --- 左軸（縦軸：チャンネル）---
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 45.0,
                getTitlesWidget: (value, meta) {
                  // 中央のチャンネル名だけ表示
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

            // --- 右軸（縦軸：電圧）---
            rightTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 50.0,
                // 上下端に1本（0は非表示）
                interval: (yMax - yMin).abs(),
                getTitlesWidget: (value, meta) {
                  // 0の目盛りは左軸とかぶるので表示しない
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

          // === 枠線 ===
          borderData: FlBorderData(
            show: true,
            border: Border.all(color: Colors.white24),
          ),

          // === その他 ===
          lineTouchData: const LineTouchData(enabled: false),
        ),
        // アニメーションを無効化
        duration: Duration.zero,
      ),
    );
  }
}

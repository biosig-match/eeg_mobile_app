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

  /// 現在の表示バッファを走査して、各チャンネルの生値(µV)の
  /// 最小最大を求め、5%（最低±1µV）の余白を付けて固定する。
  void _fitRanges() {
    if (widget.data.isEmpty) return;
    const double microVoltPerLsb12bit = 0.48828125;
    const double center12bit = 2048.0;
    // データが存在する最大チャンネル数を推定
    int maxChannelsInData = 0;
    for (final p in widget.data) {
      final len = p.eegMicroVolts != null ? p.eegMicroVolts!.length : p.eegValues.length;
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
          y = p.eegMicroVolts![ch];
        } else if (ch < p.eegValues.length) {
          y = (p.eegValues[ch].toDouble() - center12bit) * microVoltPerLsb12bit;
        }
        if (y == null) continue;
        localMin = (localMin == null) ? y : (y < localMin ? y : localMin);
        localMax = (localMax == null) ? y : (y > localMax ? y : localMax);
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
/// - y値は受信時に変換済みのµVがあればそれを採用、なければ12bit換算にフォールバック。
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
    // フォールバック用の12bitスケール（Muse既定）。受信時にµVへ変換済みの場合はそちらを優先。
    const double microVoltPerLsb12bit = 0.48828125;
    const double center12bit = 2048.0;
    const double defaultYMin = -100.0;
    const double defaultYMax = 100.0;

    // 一点のy(µV)を取得。µVが未設定なら12bit生値から換算。
    double? yMicroVolts(SensorDataPoint p) {
      if (p.eegMicroVolts != null && channelIndex < p.eegMicroVolts!.length) {
        return p.eegMicroVolts![channelIndex];
      }
      if (channelIndex < p.eegValues.length) {
        return (p.eegValues[channelIndex].toDouble() - center12bit) * microVoltPerLsb12bit;
      }
      return null;
    }
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

                    final y = yMicroVolts(point);
                    if (y == null) return FlSpot.nullSpot;
                    // 表示は視認性のためにレンジ内へクランプ
                    final double yClamped = y < yMin ? yMin : (y > yMax ? yMax : y);

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

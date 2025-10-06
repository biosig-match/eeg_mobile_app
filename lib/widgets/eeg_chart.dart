import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'dart:math';
import '../models/sensor_data.dart';

/// 複数のEEGチャンネルデータを、チャンネルごとに分離されたスクロール可能な
/// グラフリストとして表示するウィジェットです。
class EegMultiChannelChart extends StatelessWidget {
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
  Widget build(BuildContext context) {
    // デバッグ情報を表示
    print("EegMultiChannelChart: build() called, data.length=${data.length}, channelCount=$channelCount");
    if (data.isNotEmpty) {
      print("EegMultiChannelChart: First data point: ${data.first.eegValues.take(4).toList()}");
    }
    
    // データが空の場合は待機メッセージを表示
    if (data.isEmpty) {
      return Center(
        child: Container(
          padding: const EdgeInsets.all(16.0),
          decoration: BoxDecoration(
            color: const Color(0xff232d37),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white24),
          ),
          child: Text('受信待機中... (データ: ${data.length}点)'),
        ),
      );
    }

    // 各チャンネルのグラフを縦に並べてスクロール可能にする
    return ListView.builder(
      itemCount: channelCount,
      itemBuilder: (context, index) {
        // 各チャンネルのグラフウィジェットを生成
        return Padding(
          // グラフ間のスペース
          padding: const EdgeInsets.only(bottom: 8.0),
          child: SizedBox(
            height: 110, // 各グラフの描画エリアの高さは固定
            child: _SingleChannelChart(
              data: data,
              sampleRate: sampleRate,
              channelIndex: index,
              // すべてのグラフに横軸の目盛りを表示する
              showBottomTitles: true,
            ),
          ),
        );
      },
    );
  }
}

/// 単一チャンネルのEEGデータを表示するためのプライベートウィジェット
class _SingleChannelChart extends StatelessWidget {
  final List<SensorDataPoint> data;
  final int sampleRate;
  final int channelIndex;
  final bool showBottomTitles;

  const _SingleChannelChart({
    required this.data,
    required this.sampleRate,
    required this.channelIndex,
    required this.showBottomTitles,
  });

  @override
  Widget build(BuildContext context) {
    // --- 縦軸の動的スケーリング処理 ---
    double maxAbsValue = 0.0;
    if (data.isNotEmpty) {
      // このチャンネルのデータから、中心(2048)からの振幅の絶対値の最大を求める
      final values = data
          .where((p) => channelIndex < p.eegValues.length)
          .map((p) => (p.eegValues[channelIndex].toDouble() - 2048).abs());
      if (values.isNotEmpty) {
        maxAbsValue = values.reduce(max);
      }
    }
    // 最小の表示範囲を100に設定し、現在の最大振幅値に15%の余裕を持たせる
    final double verticalRange = max(100.0, maxAbsValue * 1.15);

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

                    if (channelIndex >= point.eegValues.length) {
                      return FlSpot.nullSpot;
                    }
                    // Y座標は、値から中央値を引いたもの
                    final yValue =
                        point.eegValues[channelIndex].toDouble() - 2048;

                    return FlSpot(
                      index.toDouble(), // X座標はデータのインデックス
                      yValue,
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
          minY: -verticalRange, // 計算した動的な範囲を設定
          maxY: verticalRange, // 計算した動的な範囲を設定

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
                interval: verticalRange, // スケールの上端と下端に目盛り
                getTitlesWidget: (value, meta) {
                  // 0の目盛りは左軸とかぶるので表示しない
                  if (value == 0) {
                    return const SizedBox.shrink();
                  }
                  return SideTitleWidget(
                    axisSide: meta.axisSide,
                    space: 4.0,
                    child: Text(value.toStringAsFixed(0),
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
      ),
    );
  }
}

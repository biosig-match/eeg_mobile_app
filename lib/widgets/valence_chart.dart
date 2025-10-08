import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class ValenceChart extends StatelessWidget {
  final List<(DateTime, double)> data;

  const ValenceChart({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 直近1分間のデータのみを抽出
    final oneMinuteAgo = DateTime.now().subtract(const Duration(minutes: 1));
    final recentData = data.where((d) => d.$1.isAfter(oneMinuteAgo)).toList();

    // データが空の場合は、メッセージを表示
    if (recentData.isEmpty) {
      return const Center(
        child: Text("快不快のデータがありません。"),
      );
    }

    List<FlSpot> spots = recentData.map((point) {
      return FlSpot(point.$1.millisecondsSinceEpoch.toDouble(), point.$2);
    }).toList();

    // Y軸の最大値・最小値を動的に計算
    final values = recentData.map((d) => d.$2);
    double minValence = values.reduce(min);
    double maxValence = values.reduce(max);

    double minY;
    double maxY;
    final double range = maxValence - minValence;

    // 全てのデータが同じ値の場合、デフォルトのマージンを設定
    if (range.abs() < 1e-9) {
      minY = minValence - 0.5;
      maxY = maxValence + 0.5;
    } else {
      // 最大値・最小値に15%のマージンを追加
      final double margin = range * 0.15;
      minY = minValence - margin;
      maxY = maxValence + margin;
    }

    return LineChart(
      LineChartData(
        minY: minY,
        maxY: maxY,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: true,
          horizontalInterval: (maxY - minY) / 4, // 横線を4本に自動調整
          verticalInterval: 10000, // 10秒ごとに縦線
          getDrawingHorizontalLine: (value) {
            // 0のラインを強調表示
            if (value.abs() < 1e-6) {
              return FlLine(
                color: theme.colorScheme.secondary.withOpacity(0.7),
                strokeWidth: 1.5,
              );
            }
            return const FlLine(color: Colors.white10, strokeWidth: 1);
          },
          getDrawingVerticalLine: (value) {
            return const FlLine(color: Colors.white10, strokeWidth: 1);
          },
        ),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            axisNameWidget: const Text(
              '快不快度 (左右パワー対数差)',
              style: TextStyle(fontSize: 12),
            ),
            axisNameSize: 24,
            sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 50, // 指数表記のため少し幅を広げる
                interval: (maxY - minY) / 4,
                getTitlesWidget: (value, meta) {
                  // ★★★ 縦軸の目盛りの両端を非表示に ★★★
                  if (value == meta.max || value == meta.min) {
                    return const SizedBox.shrink();
                  }
                  // 縦軸の目盛りを有効数字3桁の指数表記でフォーマット
                  final String text = NumberFormat('0.00E0').format(value);
                  return SideTitleWidget(
                    axisSide: meta.axisSide,
                    space: 4.0,
                    child: Text(
                      text,
                      style: const TextStyle(fontSize: 10),
                    ),
                  );
                }),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 30,
              interval: 10000,
              getTitlesWidget: (value, meta) {
                // 横軸の目盛りの両端を非表示に
                if (value == meta.min || value == meta.max) {
                  return const SizedBox.shrink();
                }
                final dt = DateTime.fromMillisecondsSinceEpoch(value.toInt());
                return SideTitleWidget(
                  axisSide: meta.axisSide,
                  child: Text(DateFormat('HH:mm:ss').format(dt),
                      style: const TextStyle(fontSize: 10)),
                );
              },
            ),
          ),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData:
            FlBorderData(show: true, border: Border.all(color: Colors.white24)),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: theme.colorScheme.primary,
            barWidth: 2,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                colors: [
                  theme.colorScheme.primary.withAlpha((255 * 0.3).round()),
                  theme.colorScheme.primary.withAlpha(0),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
        ],
      ),
      duration: Duration.zero,
    );
  }
}

/// 画面下部からスライドで表示/非表示を切り替えられる快不快パネル。
/// 表示トグルは右上の ^ ボタン。
class ValencePanel extends StatefulWidget {
  final List<(DateTime, double)> data;

  const ValencePanel({super.key, required this.data});

  @override
  State<ValencePanel> createState() => _ValencePanelState();
}

class _ValencePanelState extends State<ValencePanel> with SingleTickerProviderStateMixin {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Stack(
      children: [
        // スライドインするパネル本体
        Align(
          alignment: Alignment.bottomCenter,
          child: AnimatedSlide(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            offset: _expanded ? Offset.zero : const Offset(0, 1),
            child: Material(
              color: Colors.transparent,
              child: Container(
                margin: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xff1b242e),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    )
                  ],
                ),
                height: 180,
                child: ValenceChart(data: widget.data),
              ),
            ),
          ),
        ),

        // トグルボタン（常に右下に表示）
        Align(
          alignment: Alignment.bottomRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 12, bottom: 12),
            child: FloatingActionButton.small(
              heroTag: 'valence_toggle',
              backgroundColor: theme.colorScheme.primary.withOpacity(0.85),
              onPressed: () => setState(() => _expanded = !_expanded),
              child: Icon(_expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up),
            ),
          ),
        ),
      ],
    );
  }
}

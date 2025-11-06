import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'dart:math';
import '../models/sensor_data.dart';
import '../providers/ble_provider.dart';
import '../providers/analysis_provider.dart';
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
  final List<ElectrodeConfig>? electrodes;
  final Map<String, ChannelQualityStatus>? channelQuality;

  const EegMultiChannelChart({
    super.key,
    required this.data,
    this.channelCount = 8,
    required this.sampleRate,
    this.electrodes,
    this.channelQuality,
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

  ChannelQualityStatus? _qualityForChannel(String channelName) {
    final qualityMap = widget.channelQuality;
    if (qualityMap == null || qualityMap.isEmpty) return null;
    final upper = channelName.toUpperCase();
    return qualityMap[upper] ??
        qualityMap[channelName] ??
        qualityMap[channelName.toLowerCase()];
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
              final electrodeName = widget.electrodes != null &&
                      index < (widget.electrodes?.length ?? 0)
                  ? widget.electrodes![index].name
                  : 'CH${index + 1}';
              final quality = _qualityForChannel(electrodeName);
              return Padding(
                padding: const EdgeInsets.only(bottom: 4.0),
                child: SizedBox(
                  height: 180,
                  child: _SingleChannelChart(
                    data: widget.data,
                    sampleRate: widget.sampleRate,
                    channelIndex: index,
                    yMinLocked: _lockedRanges[index]?.$1,
                    yMaxLocked: _lockedRanges[index]?.$2,
                    showBottomTitles: true,
                    channelName: electrodeName,
                    quality: quality,
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
  final String channelName;
  final ChannelQualityStatus? quality;

  const _SingleChannelChart({
    required this.data,
    required this.sampleRate,
    required this.channelIndex,
    required this.yMinLocked,
    required this.yMaxLocked,
    required this.showBottomTitles,
    required this.channelName,
    required this.quality,
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

    LineChartData _chartData() => LineChartData(
          backgroundColor: const Color(0xff232d37),
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
                    final y = point.eegValues[channelIndex].toDouble() *
                        lsbToMicrovolts;
                    final double yClamped = y.clamp(yMin, yMax);
                    return FlSpot(index.toDouble(), yClamped);
                  })
                  .where((spot) => spot != FlSpot.nullSpot)
                  .toList(),
              isCurved: false,
              color: Colors.cyanAccent,
              barWidth: 1.2,
              dotData: const FlDotData(show: false),
            ),
          ],
          minX: 0,
          maxX: max(0, (data.length - 1).toDouble()),
          minY: yMin,
          maxY: yMax,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: true,
            verticalInterval: sampleRate.toDouble(),
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
                  if (index < 0 || index >= data.length || index >= meta.max) {
                    return const SizedBox.shrink();
                  }
                  final time = data[index].timestamp;
                  final formattedTime =
                      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
                  return SideTitleWidget(
                    axisSide: meta.axisSide,
                    space: 4.0,
                    child: Text(
                      formattedTime,
                      style: TextStyle(
                        color: Colors.grey[400],
                        fontSize: 9.0,
                        overflow: TextOverflow.ellipsis,
                      ),
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
                      child: Text(
                        channelName,
                        style:
                            TextStyle(color: Colors.grey[400], fontSize: 10.0),
                      ),
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
                interval: max(1, (yMax - yMin).abs()),
                getTitlesWidget: (value, meta) {
                  if (value == 0) {
                    return const SizedBox.shrink();
                  }
                  return SideTitleWidget(
                    axisSide: meta.axisSide,
                    space: 4.0,
                    child: Text(
                      '${value.toStringAsFixed(0)} µV',
                      style: TextStyle(color: Colors.grey[400], fontSize: 10.0),
                    ),
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
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          child: Row(
            children: [
              Text(
                channelName,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 8),
              _QualityBadge(status: quality),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: Container(
            padding: const EdgeInsets.only(top: 16, right: 16, bottom: 8),
            child: LineChart(
              _chartData(),
              duration: Duration.zero,
            ),
          ),
        ),
      ],
    );
  }
}

class _QualityBadge extends StatelessWidget {
  final ChannelQualityStatus? status;
  const _QualityBadge({required this.status});

  String _translateReason(String reason) {
    final lower = reason.toLowerCase();
    if (lower.startsWith('impedance high')) {
      final suffix = reason.substring('impedance high'.length).trim();
      return 'インピーダンス高 ${suffix.isNotEmpty ? suffix : ''}'.trim();
    }
    if (lower.startsWith('impedance unknown')) {
      final suffix = reason.substring('impedance unknown'.length).trim();
      return 'インピーダンス不明 ${suffix.isNotEmpty ? suffix : ''}'.trim();
    }
    if (lower.startsWith('zero-fill')) {
      final suffix = reason.substring('zero-fill'.length).trim();
      return 'ゼロ値が継続 ${suffix.isNotEmpty ? suffix : ''}'.trim();
    }
    if (lower.contains('flatline')) {
      return '振幅がフラット';
    }
    return reason;
  }

  @override
  Widget build(BuildContext context) {
    String label = '未取得';
    Color color = Colors.blueGrey;
    List<String> reasons = const ['リアルタイム解析の結果を待機しています'];

    if (status != null) {
      final translatedReasons = status!.reasons
          .map(_translateReason)
          .where((value) => value.isNotEmpty)
          .toList();
      if (status!.status == 'bad') {
        label = '要調整';
        color = Colors.redAccent;
        reasons =
            translatedReasons.isNotEmpty ? translatedReasons : ['信号品質が低下しています'];
      } else if (status!.hasWarning || translatedReasons.isNotEmpty) {
        label = '注意';
        color = Colors.amberAccent;
        reasons = translatedReasons;
      } else {
        label = '良好';
        color = Colors.lightGreenAccent;
        reasons = const ['信号は安定しています'];
      }
    }

    return Tooltip(
      message: reasons.join('\n'),
      waitDuration: const Duration(milliseconds: 400),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.18),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.6)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w600,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

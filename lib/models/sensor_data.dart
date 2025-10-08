class SensorDataPoint {
  final int sampleIndex;
  final List<int> eegValues;
  // µVに変換済みのEEG値（必要に応じて設定）。未設定の場合はnull。
  final List<double>? eegMicroVolts;
  final List<int> accel;
  final List<int> gyro;
  final int triggerState;
  final DateTime timestamp;

  SensorDataPoint({
    required this.sampleIndex,
    required this.eegValues,
    this.eegMicroVolts,
    required this.accel,
    required this.gyro,
    required this.triggerState,
    required this.timestamp,
  });
}

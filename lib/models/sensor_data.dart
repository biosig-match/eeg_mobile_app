class SensorDataPoint {
  final int sampleIndex;
  final List<int> eegValues;
  final List<int> accel;
  final List<int> gyro;
  final int triggerState;
  final DateTime timestamp;

  SensorDataPoint({
    required this.sampleIndex,
    required this.eegValues,
    required this.accel,
    required this.gyro,
    required this.triggerState,
    required this.timestamp,
  });
}

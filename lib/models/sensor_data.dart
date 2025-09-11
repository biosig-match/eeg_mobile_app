import 'dart:typed_data';

class SensorDataPoint {
  final List<int> eegValues;
  final DateTime timestamp;
  SensorDataPoint({required this.eegValues, required this.timestamp});
}

class DecodedPacket {
  final String deviceId;
  final List<SensorDataPoint> points;
  DecodedPacket(this.deviceId, this.points);
}

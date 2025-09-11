enum SessionState { idle, running, finished }

enum SessionType { calibration, main }

class Session {
  final String id;
  final String userId;
  final String experimentId;
  final String deviceId; // ★★★ デバイスIDを保持するフィールドを追加 ★★★
  final DateTime startTime;
  final SessionType type;

  DateTime? endTime;
  SessionState state;

  Session({
    required this.id,
    required this.userId,
    required this.experimentId,
    required this.deviceId, // ★★★ コンストラクタに追加 ★★★
    required this.startTime,
    required this.type,
    this.state = SessionState.running,
  });

  void endSession() {
    endTime = DateTime.now().toUtc();
    state = SessionState.finished;
  }

  Map<String, dynamic> toJson() {
    return {
      'session_id': id,
      'user_id': userId,
      'experiment_id': experimentId,
      'device_id': deviceId, // ★★★ 送信するJSONに追加 ★★★
      'start_time': startTime.toIso8601String(),
      'end_time': endTime?.toIso8601String(),
      'session_type': type.toString().split('.').last,
    };
  }
}

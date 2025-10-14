enum SessionState { idle, running, finished }

// ★★★ 外部実行のタイプを追加 ★★★
enum SessionType { calibration, main_task, main_external }

class Session {
  final String id;
  final String userId;
  final String? experimentId;
  final String deviceId;
  final DateTime startTime;
  final SessionType type;
  // ★★★ 時刻同期情報を保持するフィールドを追加 ★★★
  final Map<String, dynamic>? clockOffsetInfo;

  DateTime? endTime;
  SessionState state;

  Session({
    required this.id,
    required this.userId,
    this.experimentId,
    required this.deviceId,
    required this.startTime,
    required this.type,
    this.clockOffsetInfo, // ★★★ コンストラクタに追加 ★★★
    this.state = SessionState.running,
  });

  void endSession() {
    endTime = DateTime.now().toUtc();
    state = SessionState.finished;
  }

  Map<String, dynamic> toJson() {
    final payload = <String, dynamic>{
      'session_id': id,
      'user_id': userId,
      'device_id': deviceId,
      'start_time': startTime.toIso8601String(),
      'end_time': endTime?.toIso8601String(),
      'session_type': type.toString().split('.').last,
    };

    if (experimentId != null && experimentId!.isNotEmpty) {
      payload['experiment_id'] = experimentId;
    }

    if (clockOffsetInfo != null) {
      payload['clock_offset_info'] = clockOffsetInfo;
    }

    return payload;
  }
}

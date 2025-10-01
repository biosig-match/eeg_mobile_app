enum SessionState { idle, running, finished }

// ★★★ 外部実行のタイプを追加 ★★★
enum SessionType { calibration, main_task, main_external }

class Session {
  final String id;
  final String userId;
  final String experimentId;
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
    required this.experimentId,
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
    return {
      'session_id': id,
      'user_id': userId,
      'experiment_id': experimentId,
      'device_id': deviceId,
      'start_time': startTime.toIso8601String(),
      'end_time': endTime?.toIso8601String(),
      'session_type': type.toString().split('.').last,
      // ★★★ 送信するJSONにclock_offset_infoを追加 ★★★
      'clock_offset_info': clockOffsetInfo,
    };
  }
}

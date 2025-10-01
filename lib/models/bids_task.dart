enum BidsTaskStatus { pending, processing, completed, failed }

class BidsTask {
  final String experimentId;
  final String taskId;
  final BidsTaskStatus status;
  final int progress;
  final String message;
  final String? resultFilePath;
  final String? errorMessage;
  final DateTime createdAt;
  DateTime updatedAt;

  BidsTask({
    required this.experimentId,
    required this.taskId,
    required this.status,
    required this.progress,
    required this.message,
    this.resultFilePath,
    this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
  });

  factory BidsTask.fromStartJson(
      String experimentId, Map<String, dynamic> json) {
    return BidsTask(
      experimentId: experimentId,
      taskId: json['task_id'],
      status: _statusFromString(json['status']),
      progress: 0,
      message: json['message'] ?? 'Task started',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
  }

  factory BidsTask.fromStatusJson(
      String experimentId, String taskId, Map<String, dynamic> json) {
    return BidsTask(
      experimentId: experimentId,
      taskId: taskId,
      status: _statusFromString(json['status']),
      progress: json['progress'] ?? 0,
      message: json['status_message'] ?? '',
      resultFilePath: json['result_file_path'],
      errorMessage: json['error_message'],
      createdAt: DateTime.tryParse(json['created_at'] ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(json['updated_at'] ?? '') ?? DateTime.now(),
    );
  }

  static BidsTaskStatus _statusFromString(String? status) {
    switch (status) {
      case 'pending':
        return BidsTaskStatus.pending;
      case 'processing':
      case 'running':
        return BidsTaskStatus.processing;
      case 'completed':
        return BidsTaskStatus.completed;
      case 'failed':
        return BidsTaskStatus.failed;
      default:
        return BidsTaskStatus.pending;
    }
  }
}

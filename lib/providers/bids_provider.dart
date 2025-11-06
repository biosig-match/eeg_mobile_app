import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../models/bids_task.dart';
import '../utils/config.dart';
import 'auth_provider.dart';

class BidsProvider with ChangeNotifier {
  final ServerConfig _config;
  final AuthProvider _authProvider;

  final Map<String, BidsTask> _tasks = {};
  final Map<String, Timer> _pollingTimers = {};
  String _statusMessage = '';

  List<BidsTask> get tasks => _tasks.values.toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  String get statusMessage => _statusMessage;

  BidsProvider(this._config, this._authProvider);

  Future<void> refreshTasks({bool silent = false}) async {
    if (!_authProvider.isAuthenticated) return;
    if (!silent) {
      _statusMessage = 'エクスポートタスクを更新しています...';
      notifyListeners();
    }

    try {
      final url =
          Uri.parse('${_config.httpBaseUrl}/api/v1/export-tasks?limit=50');
      final response =
          await http.get(url, headers: {'X-User-Id': _authProvider.userId!});

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        final Map<String, BidsTask> refreshed = {};
        for (final raw in data) {
          if (raw is! Map<String, dynamic>) continue;
          final taskId = raw['task_id']?.toString();
          final experimentId = raw['experiment_id']?.toString() ?? '';
          if (taskId == null) continue;
          final task = BidsTask.fromStatusJson(experimentId, taskId, raw);
          refreshed[taskId] = task;
        }

        final removedTaskIds =
            _tasks.keys.where((id) => !refreshed.containsKey(id)).toList();
        for (final removedId in removedTaskIds) {
          _cancelPolling(removedId);
        }

        _tasks
          ..clear()
          ..addAll(refreshed);

        for (final task in _tasks.values) {
          if (!task.isTerminal) {
            _startPolling(task.taskId);
          } else {
            _cancelPolling(task.taskId);
          }
        }

        if (!silent) {
          _statusMessage =
              _tasks.isEmpty ? 'エクスポートタスクはありません。' : 'タスク一覧を更新しました。';
        }
      } else {
        throw Exception('タスク一覧の取得に失敗: ${response.statusCode}');
      }
    } catch (e) {
      if (!silent) {
        _statusMessage = 'エラー: $e';
      }
    }
    notifyListeners();
  }

  Future<void> startExport(String experimentId) async {
    if (!_authProvider.isAuthenticated) return;
    _statusMessage = 'BIDSエクスポートを開始しています...';
    notifyListeners();

    try {
      final url = Uri.parse(
          '${_config.httpBaseUrl}/api/v1/experiments/$experimentId/export');
      final response =
          await http.post(url, headers: {'X-User-Id': _authProvider.userId!});

      if (response.statusCode == 202) {
        final data = jsonDecode(response.body);
        final task = BidsTask.fromStartJson(experimentId, data);
        _tasks[task.taskId] = task;
        _statusMessage = 'エクスポートタスクを開始しました。';
        _startPolling(task.taskId);
      } else {
        final data = jsonDecode(response.body);
        throw Exception('エクスポート開始に失敗: ${data['error'] ?? response.statusCode}');
      }
    } catch (e) {
      _statusMessage = 'エラー: $e';
    }
    notifyListeners();
  }

  void _startPolling(String taskId) {
    final task = _tasks[taskId];
    if (task == null || task.isTerminal) {
      _cancelPolling(taskId);
      return;
    }

    _cancelPolling(taskId);
    _pollingTimers[taskId] =
        Timer.periodic(const Duration(seconds: 5), (timer) async {
      final task = _tasks[taskId];
      if (task == null ||
          task.status == BidsTaskStatus.completed ||
          task.status == BidsTaskStatus.failed) {
        timer.cancel();
        return;
      }

      try {
        final url =
            Uri.parse('${_config.httpBaseUrl}/api/v1/export-tasks/$taskId');
        final response =
            await http.get(url, headers: {'X-User-Id': _authProvider.userId!});

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final updatedTask =
              BidsTask.fromStatusJson(task.experimentId, taskId, data);
          _tasks[taskId] = updatedTask;
          notifyListeners();

          if (updatedTask.status == BidsTaskStatus.completed ||
              updatedTask.status == BidsTaskStatus.failed) {
            timer.cancel();
          }
        }
      } catch (e) {
        debugPrint("Polling error for task $taskId: $e");
      }
    });
  }

  void _cancelPolling(String taskId) {
    final timer = _pollingTimers.remove(taskId);
    timer?.cancel();
  }

  Future<void> downloadBidsFile(String taskId) async {
    final task = _tasks[taskId];
    if (task == null || task.status != BidsTaskStatus.completed) return;

    final url = Uri.parse(
        '${_config.httpBaseUrl}/api/v1/export-tasks/$taskId/download');

    try {
      final launched =
          await launchUrl(url, mode: LaunchMode.externalApplication);
      if (!launched) {
        final fallback = await launchUrl(url, mode: LaunchMode.platformDefault);
        if (!fallback) {
          throw Exception('launchUrl returned false');
        }
      }
    } catch (e) {
      debugPrint('[BIDS] Failed to launch download URL: $e');
      _statusMessage = 'ダウンロードURLを開けませんでした。別のブラウザをお試しください。（詳細: $e）';
      notifyListeners();
    }
  }

  @override
  void dispose() {
    for (var timer in _pollingTimers.values) {
      timer.cancel();
    }
    _pollingTimers.clear();
    super.dispose();
  }
}

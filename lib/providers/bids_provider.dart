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
    _pollingTimers[taskId]?.cancel();
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

  Future<void> downloadBidsFile(String taskId) async {
    final task = _tasks[taskId];
    if (task == null || task.status != BidsTaskStatus.completed) return;

    final url = Uri.parse(
        '${_config.httpBaseUrl}/api/v1/export-tasks/$taskId/download');

    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } else {
      _statusMessage = 'ダウンロードURLを開けませんでした: $url';
      notifyListeners();
    }
  }

  @override
  void dispose() {
    for (var timer in _pollingTimers.values) {
      timer.cancel();
    }
    super.dispose();
  }
}

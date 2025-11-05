import 'package:flutter/material.dart';

// 認証情報を管理するProvider
class AuthProvider with ChangeNotifier {
  String? _userId;

  AuthProvider([String? initialUserId]) {
    _userId = (initialUserId != null && initialUserId.isNotEmpty)
        ? initialUserId
        : 'user-default-01';
  }

  bool get isAuthenticated => _userId != null;
  String? get userId => _userId;

  // ★★★ HTTPヘッダーを簡単に取得するためのゲッターを追加 ★★★
  Map<String, String> get headers {
    if (isAuthenticated) {
      return {'X-User-Id': _userId!};
    }
    return {};
  }

  void updateUserId(String userId) {
    if (userId.trim().isEmpty) return;
    _userId = userId.trim();
    notifyListeners();
  }
}

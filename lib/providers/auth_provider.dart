import 'package:flutter/material.dart';

// 認証情報を管理するProvider
class AuthProvider with ChangeNotifier {
  String? _userId = "user-default-01"; // モック用の固定ユーザーID
  bool get isAuthenticated => _userId != null;
  String? get userId => _userId;
}

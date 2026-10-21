import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../models/user.dart';

class UserRepository {
  final Database _db;

  UserRepository(this._db);

  String _hashPassword(String password) {
    return sha256.convert(utf8.encode(password)).toString();
  }

  Future<void> seedDefaultUser() async {
    final result = await _db.rawQuery('SELECT COUNT(*) as count FROM users');
    final count = result.first['count'] as int;

    if (count == 0) {
      final defaultUser = User(
        id: const Uuid().v4(),
        username: 'owner',
        passwordHash: _hashPassword('admin'),
        role: 'OWNER',
      );
      await _db.insert('users', defaultUser.toMap());
    }
  }

  Future<User?> authenticate(String username, String password) async {
    final maps = await _db.query(
      'users',
      where: 'username = ? AND password_hash = ? AND is_active = 1',
      whereArgs: [username, _hashPassword(password)],
      limit: 1,
    );

    if (maps.isEmpty) return null;
    return User.fromMap(maps.first);
  }

  Future<void> createUser(String username, String password, String role) async {
    final newUser = User(
      id: const Uuid().v4(),
      username: username,
      passwordHash: _hashPassword(password),
      role: role,
    );
    await _db.insert('users', newUser.toMap());
  }

  Future<List<User>> getAllUsers() async {
    final maps = await _db.query('users', orderBy: 'username ASC');
    return maps.map((m) => User.fromMap(m)).toList();
  }
}

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../models/user.dart';

class UserRepository {
  final Database _db;

  UserRepository(this._db);

  String _generateSalt() {
    final random = Random.secure();
    final values = List<int>.generate(16, (i) => random.nextInt(256));
    return base64Url.encode(values);
  }

  String _hashPassword(String password, String salt) {
    return sha256.convert(utf8.encode(password + salt)).toString();
  }

  Future<void> seedDefaultUser() async {
    final result = await _db.rawQuery('SELECT COUNT(*) as count FROM users');
    final count = result.first['count'] as int;

    if (count == 0) {
      final salt = _generateSalt();
      final defaultUser = User(
        id: const Uuid().v4(),
        username: 'owner',
        passwordHash: _hashPassword('admin', salt),
        salt: salt,
        role: 'OWNER',
      );
      await _db.insert('users', defaultUser.toMap());
    }
  }

  Future<User?> authenticate(String username, String password) async {
    final maps = await _db.query(
      'users',
      where: 'username = ? AND is_active = 1',
      whereArgs: [username],
      limit: 1,
    );

    if (maps.isEmpty) return null;

    final user = User.fromMap(maps.first);
    final expectedHash = _hashPassword(password, user.salt);

    if (user.passwordHash == expectedHash) return user;
    return null;
  }

  Future<void> createUser(String username, String password, String role) async {
    final salt = _generateSalt();
    final newUser = User(
      id: const Uuid().v4(),
      username: username,
      passwordHash: _hashPassword(password, salt),
      salt: salt,
      role: role,
    );
    await _db.insert('users', newUser.toMap());
  }

  Future<List<User>> getAllUsers() async {
    final maps = await _db.query('users', orderBy: 'username ASC');
    return maps.map((m) => User.fromMap(m)).toList();
  }
}

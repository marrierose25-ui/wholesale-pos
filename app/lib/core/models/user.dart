class User {
  final String id;
  final String username;
  final String passwordHash;
  final String role;
  final bool isActive;

  User({
    required this.id,
    required this.username,
    required this.passwordHash,
    required this.role,
    this.isActive = true,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'username': username,
      'password_hash': passwordHash,
      'role': role,
      'is_active': isActive ? 1 : 0,
      'created_at': DateTime.now().toIso8601String(),
    };
  }

  factory User.fromMap(Map<String, dynamic> map) {
    return User(
      id: map['id'] as String,
      username: map['username'] as String,
      passwordHash: map['password_hash'] as String,
      role: map['role'] as String,
      isActive: (map['is_active'] as int) == 1,
    );
  }
}

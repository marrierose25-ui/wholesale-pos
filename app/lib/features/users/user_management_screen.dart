import 'package:flutter/material.dart';

import '../../core/models/user.dart';
import '../../core/repositories/user_repository.dart';

class UserManagementScreen extends StatefulWidget {
  final UserRepository userRepository;

  const UserManagementScreen({super.key, required this.userRepository});

  @override
  State<UserManagementScreen> createState() => _UserManagementScreenState();
}

class _UserManagementScreenState extends State<UserManagementScreen> {
  List<User> _users = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    setState(() => _isLoading = true);
    final users = await widget.userRepository.getAllUsers();
    setState(() {
      _users = users;
      _isLoading = false;
    });
  }

  void _showAddUserDialog() {
    final usernameController = TextEditingController();
    final passwordController = TextEditingController();
    String selectedRole = 'CASHIER';

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: const Text('Add New User'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: usernameController,
                  decoration: const InputDecoration(labelText: 'Username'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Password'),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: selectedRole,
                  decoration: const InputDecoration(labelText: 'Role'),
                  items: const [
                    DropdownMenuItem(value: 'CASHIER', child: Text('Cashier')),
                    DropdownMenuItem(
                      value: 'OWNER',
                      child: Text('Owner / Admin'),
                    ),
                  ],
                  onChanged: (val) => setDialogState(() => selectedRole = val!),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () async {
                  if (usernameController.text.trim().isEmpty ||
                      passwordController.text.isEmpty) {
                    return;
                  }

                  await widget.userRepository.createUser(
                    usernameController.text.trim(),
                    passwordController.text,
                    selectedRole,
                  );

                  if (context.mounted) Navigator.pop(context);
                  _loadUsers();
                },
                child: const Text('Create User'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    return Scaffold(
      appBar: AppBar(
        title: const Text('User Management'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadUsers),
        ],
      ),
      body: ListView.builder(
        itemCount: _users.length,
        itemBuilder: (context, index) {
          final user = _users[index];
          return ListTile(
            leading: CircleAvatar(
              backgroundColor: user.role == 'OWNER' ? Colors.blue : Colors.grey,
              child: Icon(Icons.person, color: Colors.white),
            ),
            title: Text(user.username),
            subtitle: Text(user.role),
            trailing: user.isActive
                ? const Chip(label: Text('Active'))
                : const Chip(
                    label: Text('Disabled'),
                    backgroundColor: Colors.red,
                  ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddUserDialog,
        icon: const Icon(Icons.person_add),
        label: const Text('Add User'),
      ),
    );
  }
}

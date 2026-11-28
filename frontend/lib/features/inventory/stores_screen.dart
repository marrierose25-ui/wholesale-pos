import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:pos_contracts/pos_contracts.dart';
import 'package:pos_core/inventory.dart';
import '../../core/theme/app_design.dart';

/// Store management: the locations that hold inventory stock. Deliberately
/// simple — a name is the only field; a store can only be deleted while it
/// holds no product stock at all.
class StoresScreen extends StatefulWidget {
  final InventoryRepository repository;

  /// Fired after a local write so the shell can nudge the sync engine.
  final VoidCallback? onDataChanged;

  const StoresScreen({super.key, required this.repository, this.onDataChanged});

  @override
  State<StoresScreen> createState() => StoresScreenState();
}

class StoresScreenState extends State<StoresScreen> {
  late Future<List<Store>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.repository.getStores();
  }

  void refresh() {
    final future = widget.repository.getStores();
    setState(() {
      _future = future;
    });
  }

  void _snack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: isError ? AppDesign.danger : AppDesign.card,
        ),
      );
  }

  Future<void> _createStore() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppDesign.card,
        title: Text('New store', style: TextStyle(color: AppDesign.textHi)),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          style: TextStyle(color: AppDesign.textHi),
          decoration: InputDecoration(
            hintText: 'Store name',
            hintStyle: TextStyle(color: AppDesign.textFaint),
          ),
          onSubmitted: (v) => Navigator.pop(dialogContext, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text('Cancel', style: TextStyle(color: AppDesign.textLo)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: Text('Save', style: TextStyle(color: AppDesign.accent)),
          ),
        ],
      ),
    );
    if (name == null || !mounted) return;
    try {
      await widget.repository.createStore(name);
      widget.onDataChanged?.call();
      refresh();
      _snack('Store created.');
    } catch (e) {
      _snack('$e', isError: true);
    }
  }

  Future<void> _deleteStore(Store store) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppDesign.card,
        title: Text(
          'Delete ${store.name}?',
          style: TextStyle(color: AppDesign.textHi),
        ),
        content: Text(
          'Only an empty store can be deleted. This cannot be undone.',
          style: TextStyle(color: AppDesign.textLo),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text('Cancel', style: TextStyle(color: AppDesign.textLo)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text('Delete', style: TextStyle(color: AppDesign.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.repository.deleteStore(store.id);
      widget.onDataChanged?.call();
      refresh();
      _snack('Store deleted.');
    } catch (e) {
      _snack('$e', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppDesign.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Stores',
                          style: TextStyle(
                            color: AppDesign.textHi,
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.4,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Locations that hold your stock',
                          style: TextStyle(
                            color: AppDesign.textLo,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Pressable(
                    onTap: _createStore,
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: AppDesign.buttonGradient,
                      ),
                      child: const Icon(
                        CupertinoIcons.add,
                        color: AppDesign.onBlue,
                        size: 20,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: FutureBuilder<List<Store>>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CupertinoActivityIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          '${snapshot.error}',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppDesign.danger),
                        ),
                      ),
                    );
                  }
                  final stores = snapshot.data ?? const <Store>[];
                  if (stores.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconChip(
                              icon: CupertinoIcons.bag,
                              size: 56,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'No stores yet',
                              style: TextStyle(
                                color: AppDesign.textHi,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Add a store to start tracking stock by location.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: AppDesign.textLo,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                    itemCount: stores.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, i) {
                      final store = stores[i];
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          color: AppDesign.card,
                          borderRadius: BorderRadius.circular(
                            AppDesign.radiusCard,
                          ),
                          border: Border.all(color: AppDesign.stroke),
                          boxShadow: AppDesign.cardShadow(),
                        ),
                        child: Row(
                          children: [
                            IconChip(
                              icon: CupertinoIcons.bag,
                              size: 40,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                store.name,
                                style: TextStyle(
                                  color: AppDesign.textHi,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Pressable(
                              onTap: () => _deleteStore(store),
                              child: Padding(
                                padding: const EdgeInsets.all(8),
                                child: Icon(
                                  CupertinoIcons.trash,
                                  size: 18,
                                  color: AppDesign.danger,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

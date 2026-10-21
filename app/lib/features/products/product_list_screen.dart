import 'package:flutter/material.dart';

import '../../core/models/product.dart';
import '../../core/repositories/product_repository.dart';
import '../../core/utils/money_utils.dart';
import 'add_product_dialog.dart';

class ProductListScreen extends StatefulWidget {
  final ProductRepository repository;

  const ProductListScreen({super.key, required this.repository});

  @override
  State<ProductListScreen> createState() => _ProductListScreenState();
}

class _ProductListScreenState extends State<ProductListScreen> {
  List<Product> _products = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadProducts();
  }

  Future<void> _loadProducts() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final products = await widget.repository.getAllActive();
      if (!mounted) return;
      setState(() {
        _products = products;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'Could not load products.';
      });
    }
  }

  Future<void> _saveProduct(Product product) async {
    await widget.repository.save(product);
    await _loadProducts();
  }

  Future<void> _showAddDialog() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AddProductDialog(onSave: _saveProduct),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Product Catalog'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadProducts),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _loadProducts,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            )
          : _products.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.inventory_2_outlined, size: 48),
                  const SizedBox(height: 16),
                  const Text('No products yet.'),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _showAddDialog,
                    icon: const Icon(Icons.add),
                    label: const Text('Add Product'),
                  ),
                ],
              ),
            )
          : ListView.separated(
              itemCount: _products.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final product = _products[index];
                final category = product.category;
                return ListTile(
                  title: Text(product.name),
                  subtitle: Text(
                    '${product.code} • ${product.unit}'
                    '${category == null || category.isEmpty ? '' : ' • $category'}',
                  ),
                  trailing: Text(
                    '${MoneyUtils.minorUnitsToString(product.sellingPriceMinorUnits)} ETB',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddDialog,
        icon: const Icon(Icons.add),
        label: const Text('Add Product'),
      ),
    );
  }
}

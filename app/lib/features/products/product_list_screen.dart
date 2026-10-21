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

  @override
  void initState() {
    super.initState();
    _loadProducts();
  }

  Future<void> _loadProducts() async {
    setState(() => _isLoading = true);
    final products = await widget.repository.getAllActive();
    setState(() {
      _products = products;
      _isLoading = false;
    });
  }

  Future<void> _saveProduct(Product product) async {
    await widget.repository.save(product);
    await _loadProducts();
  }

  void _showAddDialog() {
    showDialog(
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
          : _products.isEmpty
          ? const Center(child: Text('No products found. Add one below.'))
          : ListView.builder(
              itemCount: _products.length,
              itemBuilder: (context, index) {
                final product = _products[index];
                return ListTile(
                  title: Text(product.name),
                  subtitle: Text('${product.code} • ${product.unit}'),
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

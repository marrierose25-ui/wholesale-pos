import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../features/sales/sale.dart';
import 'money_utils.dart';

class ReceiptPdfGenerator {
  static Future<void> printReceipt(Sale sale) async {
    final pdf = pw.Document();

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.roll80,
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Center(
                child: pw.Text(
                  'WHOLESALE POS',
                  style: pw.TextStyle(
                    fontSize: 18,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
              pw.Center(child: pw.Text('Sales Receipt')),
              pw.SizedBox(height: 10),
              pw.Text('Date: ${sale.createdAt.toString().split('.')[0]}'),
              if (sale.customerName != null &&
                  sale.customerName!.trim().isNotEmpty)
                pw.Text('Customer: ${sale.customerName}'),
              pw.Divider(),
              ...sale.items.map(
                (item) => pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        pw.Expanded(child: pw.Text(item.productNameSnapshot)),
                        pw.Text(MoneyUtils.formatBr(item.lineTotalMinorUnits)),
                      ],
                    ),
                    pw.Text(
                      '${item.quantityText} @ '
                      '${MoneyUtils.formatBr(item.unitPriceSnapshotMinorUnits)}'
                      ' each',
                      style: const pw.TextStyle(fontSize: 8),
                    ),
                    if (item.notes != null && item.notes!.trim().isNotEmpty)
                      pw.Text(
                        'Note: ${item.notes}',
                        style: const pw.TextStyle(fontSize: 8),
                      ),
                    pw.SizedBox(height: 4),
                  ],
                ),
              ),
              pw.Divider(),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Subtotal:'),
                  pw.Text(MoneyUtils.formatBr(sale.subtotalMinorUnits)),
                ],
              ),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    'TOTAL:',
                    style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                  ),
                  pw.Text(
                    MoneyUtils.formatBr(sale.totalMinorUnits),
                    style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                  ),
                ],
              ),
              pw.SizedBox(height: 8),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    '${sale.paymentMethod == 'CASH' ? 'Cash' : 'Bank'} Paid:',
                  ),
                  pw.Text(MoneyUtils.formatBr(sale.amountPaidMinorUnits)),
                ],
              ),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Change:'),
                  pw.Text(MoneyUtils.formatBr(sale.changeMinorUnits)),
                ],
              ),
              pw.SizedBox(height: 20),
              pw.Center(child: pw.Text('Thank you for your business!')),
            ],
          );
        },
      ),
    );

    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdf.save(),
    );
  }
}

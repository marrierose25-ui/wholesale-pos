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
              pw.Text('Receipt: ${sale.receiptNumber}'),
              pw.Text('Date: ${sale.createdAt.toString().split('.')[0]}'),
              pw.Divider(),
              ...sale.items.map(
                (item) => pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Expanded(
                      child: pw.Text(
                        '${item.quantity}x ${item.productNameSnapshot}',
                      ),
                    ),
                    pw.Text(
                      '${MoneyUtils.minorUnitsToString(item.lineTotalMinorUnits)} ETB',
                    ),
                  ],
                ),
              ),
              pw.Divider(),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Subtotal:'),
                  pw.Text(
                    '${MoneyUtils.minorUnitsToString(sale.subtotalMinorUnits)} ETB',
                  ),
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
                    '${MoneyUtils.minorUnitsToString(sale.totalMinorUnits)} ETB',
                    style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                  ),
                ],
              ),
              pw.SizedBox(height: 8),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Cash Paid:'),
                  pw.Text(
                    '${MoneyUtils.minorUnitsToString(sale.amountPaidMinorUnits)} ETB',
                  ),
                ],
              ),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Change:'),
                  pw.Text(
                    '${MoneyUtils.minorUnitsToString(sale.changeMinorUnits)} ETB',
                  ),
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

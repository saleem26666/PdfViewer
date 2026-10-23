import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/main.dart';

void main() {
  testWidgets('Home shows Open book', (tester) async {
    await tester.pumpWidget(const PdfReaderApp());
    expect(find.textContaining('Open book'), findsWidgets);
  });
}

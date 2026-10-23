import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/books/book_content.dart';
import 'package:pdf_viewer/books/urdu_translate.dart';

void main() {
  test('paragraphs stay together until the word limit', () {
    final text = List.filled(40, 'The garden was quiet and full of light.').join('\n\n');
    final parts = packParagraphs(text, maxWords: 30);
    expect(parts.length, greaterThan(1));
    expect(parts.every((part) => part.contains('\n\n') || part.split(' ').length <= 30), isTrue);
    expect(parts.join('\n'), contains('The garden was quiet'));
  });

  test('Gemini Urdu keeps grammar-ready paragraphs and pictures', () async {
    final book = LoadedBook(
      title: 'Garden Story',
      chapters: [
        BookChapter(
          title: 'Morning',
          blocks: [
            BookBlock.text(const [TextRun('The sun rose over the garden. Birds began to sing.')]),
            BookBlock.image(Uint8List.fromList(const [1, 2, 3])),
            BookBlock.text(const [TextRun('She opened the gate and walked inside.')]),
          ],
        ),
      ],
    );

    final translated = await translateBookToUrdu(book, (prompt) async {
      if (prompt.contains('book title')) return 'باغ کی کہانی';
      expect(prompt, contains('fluent Pakistani Urdu'));
      return '## صبح\n\nسورج باغ پر چمکا اور پرندے گانے لگے۔\n\nاس نے دروازہ کھولا اور اندر چل پڑی۔';
    });

    expect(translated.title, 'باغ کی کہانی');
    expect(translated.chapters.single.title, 'صبح');
    final text = translated.chapters.single.blocks
        .where((block) => !block.isImage)
        .map((block) => block.runs!.single.text)
        .join('\n');
    expect(text, contains('سورج باغ پر چمکا'));
    expect(text, contains('دروازہ کھولا'));
    expect(translated.chapters.single.blocks.where((block) => block.isImage), isNotEmpty);
  });

  test('a book that is already Urdu is left alone', () async {
    final book = LoadedBook(
      title: 'کتاب',
      chapters: [
        BookChapter(
          title: 'پہلا باب',
          blocks: [
            BookBlock.text(const [TextRun('یہ ایک کہانی ہے جو اردو میں لکھی گئی ہے اور اسے دوبارہ ترجمہ نہیں کرنا۔')]),
          ],
        ),
      ],
    );
    expect(
      () => translateBookToUrdu(book, (prompt) async => fail('Gemini should not be called')),
      throwsA(isA<BookOpenException>()),
    );
  });
}

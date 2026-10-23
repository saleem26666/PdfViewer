import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/books/book_content.dart';
import 'package:pdf_viewer/books/book_export.dart';
import 'package:pdf_viewer/books/book_kind.dart';
import 'package:pdf_viewer/books/book_loader.dart';
import 'package:pdf_viewer/books/mobi_book.dart';

void main() {
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  );
  final book = LoadedBook(
    title: 'Sample',
    chapters: [
      BookChapter(
        title: 'Chapter',
        blocks: [
          BookBlock.text(const [TextRun('Hello world')]),
          BookBlock.image(png),
        ],
      ),
    ],
  );

  String textOf(LoadedBook loaded) {
    return loaded.chapters
        .expand((chapter) => chapter.blocks)
        .where((block) => !block.isImage)
        .expand((block) => block.runs ?? const <TextRun>[])
        .map((run) => run.text)
        .join(' ');
  }

  test('EPUB export keeps text and pictures', () async {
    final bytes = await exportBook(book, ExportFormat.epub);
    final loaded = await BookLoader.load('Sample.epub', BookKind.epub, bytes);
    expect(loaded.title, 'Sample');
    expect(textOf(loaded), contains('Hello world'));
    expect(loaded.chapters.expand((c) => c.blocks).any((b) => b.isImage), isTrue);
  });

  test('MOBI export is a Kindle file our reader can open', () async {
    final bytes = await exportBook(book, ExportFormat.mobi);
    final loaded = MobiBook.parse(bytes, fallbackTitle: 'Book');
    expect(loaded.title, 'Sample');
    expect(textOf(loaded), contains('Hello world'));
    expect(loaded.chapters.expand((c) => c.blocks).any((b) => b.isImage), isTrue);
  });

  test('FB2 and DOCX export roundtrip', () async {
    final fb2 = await exportBook(book, ExportFormat.fb2);
    final loadedFb2 = await BookLoader.load('Sample.fb2', BookKind.fb2, fb2);
    expect(loadedFb2.title, 'Sample');
    expect(textOf(loadedFb2), contains('Hello world'));
    expect(loadedFb2.chapters.expand((c) => c.blocks).any((b) => b.isImage), isTrue);

    final docx = await exportBook(book, ExportFormat.docx);
    final loadedDocx = await BookLoader.load('Sample.docx', BookKind.docx, docx);
    expect(textOf(loadedDocx), contains('Hello world'));
    expect(textOf(loadedDocx), contains('[Picture]'));
  });

  test('plain text, markdown, RTF, and PDF exports', () async {
    final txt = utf8.decode(await exportBook(book, ExportFormat.txt));
    expect(txt, contains('Hello world'));
    expect(txt, contains('[Picture]'));

    final markdown = utf8.decode(await exportBook(book, ExportFormat.markdown));
    expect(markdown, contains('## Chapter'));

    final rtf = latin1.decode(await exportBook(
      LoadedBook(
        title: 'Urdu',
        chapters: [
          BookChapter(title: 'باب', blocks: [BookBlock.text(const [TextRun('سلام')])]),
        ],
      ),
      ExportFormat.rtf,
    ));
    expect(rtf, contains(r'\u'));
    expect(rtf, isNot(contains('سلام')));

    final pdf = await exportBook(book, ExportFormat.pdf);
    expect(ascii.decode(pdf.sublist(0, 5)), '%PDF-');

    final urdu = await exportBook(
      LoadedBook(
        title: 'کتاب',
        chapters: [
          BookChapter(title: 'باب', blocks: [BookBlock.text(const [TextRun('سلام دنیا')])]),
        ],
      ),
      ExportFormat.pdf,
    );
    expect(ascii.decode(urdu.sublist(0, 5)), '%PDF-');
    expect(urdu.length, greaterThan(1000));
  });

  test('CBZ keeps pictures and refuses a text-only book', () async {
    final cbz = await exportBook(book, ExportFormat.cbz);
    final archive = ZipDecoder().decodeBytes(cbz);
    expect(archive.files.single.name, endsWith('.png'));

    expect(
      () => exportBook(
        LoadedBook(
          title: 'Notes',
          chapters: [
            BookChapter(title: 'Notes', blocks: [BookBlock.text(const [TextRun('Only words')])]),
          ],
        ),
        ExportFormat.cbz,
      ),
      throwsA(isA<BookOpenException>()),
    );
  });
}

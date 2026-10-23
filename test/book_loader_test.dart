import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/books/book_content.dart';
import 'package:pdf_viewer/books/book_kind.dart';
import 'package:pdf_viewer/books/book_loader.dart';
import 'package:pdf_viewer/books/mobi_book.dart';

void main() {
  test('PalmDOC copies literals and repeats a back-reference', () {
    final hello = decompressPalmDoc(Uint8List.fromList([0x05, 0x48, 0x65, 0x6C, 0x6C, 0x6F]));
    expect(utf8.decode(hello), 'Hello');

    // "Hi" then a distance-2 length-3 copy of the same bytes.
    final repeated = decompressPalmDoc(Uint8List.fromList([0x48, 0x69, 0x80, 0x10]));
    expect(utf8.decode(repeated), 'HiHiH');
  });

  test('HTML chapters keep headings and paragraphs', () {
    final chapters = htmlToChapters(
      '<html><body><h1>One</h1><p>Hello <b>there</b></p><h2>Two</h2><p>Next</p></body></html>',
      fallbackTitle: 'Book',
    );
    expect(chapters.map((c) => c.title), ['One', 'Two']);
    final first = chapters.first.blocks.expand((b) => b.runs!).map((r) => r.text).join();
    expect(first, contains('Hello'));
    expect(first, contains('there'));
    expect(chapters.last.blocks.last.runs!.map((r) => r.text).join(), 'Next');
  });

  test('EPUB spine is read in order', () async {
    final archive = Archive()
      ..addFile(ArchiveFile.string(
        'META-INF/container.xml',
        '''
<?xml version="1.0"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''',
      ))
      ..addFile(ArchiveFile.string(
        'OEBPS/content.opf',
        '''
<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Sample</dc:title>
  </metadata>
  <manifest>
    <item id="c1" href="chap.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="c1"/>
  </spine>
</package>
''',
      ))
      ..addFile(ArchiveFile.string(
        'OEBPS/chap.xhtml',
        '<html><body><h1>Hello</h1><p>World</p></body></html>',
      ));
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
    final book = await BookLoader.load('Sample.epub', BookKind.epub, bytes);
    expect(book.title, 'Sample');
    expect(book.chapters.first.title, 'Hello');
    expect(book.chapters.first.blocks.last.runs!.single.text, 'World');
  });
}

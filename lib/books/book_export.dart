import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart' hide PdfDocument, PdfPage;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';

import 'book_content.dart';
import 'book_kind.dart';
import 'book_loader.dart';

enum ExportFormat {
  epub('EPUB', 'epub'),
  mobi('MOBI', 'mobi'),
  azw('AZW', 'azw'),
  azw3('AZW3', 'azw3'),
  fb2('FB2', 'fb2'),
  pdf('PDF', 'pdf'),
  html('HTML', 'html'),
  txt('Plain text', 'txt'),
  markdown('Markdown', 'md'),
  rtf('RTF', 'rtf'),
  docx('DOCX', 'docx'),
  cbz('CBZ comic', 'cbz');

  const ExportFormat(this.label, this.extension);
  final String label;
  final String extension;
}

class _StoredImage {
  _StoredImage(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
}

Future<LoadedBook> loadBookForExport(
  String path, {
  void Function(String status)? onStatus,
}) async {
  final kind = await BookKindDetect.resolve(path);
  final title = _titleFromPath(path);
  onStatus?.call('Reading the book…');
  if (kind == BookKind.pdf) return _loadPdf(path, title, onStatus);
  if (kind == BookKind.comic) return _loadComic(path, title);
  if (kind == BookKind.unsupported) {
    throw BookOpenException('This file is not a supported book.');
  }
  final bytes = await File(path).readAsBytes();
  return BookLoader.load(path, kind, bytes);
}

Future<Uint8List> exportBook(LoadedBook book, ExportFormat format) async {
  if (book.chapters.every((chapter) => chapter.blocks.isEmpty)) {
    throw BookOpenException('This book has nothing to convert.');
  }
  switch (format) {
    case ExportFormat.epub:
      return _epub(book);
    case ExportFormat.mobi:
    case ExportFormat.azw:
    case ExportFormat.azw3:
      return _mobi(book);
    case ExportFormat.fb2:
      return Uint8List.fromList(utf8.encode(_fb2(book)));
    case ExportFormat.html:
      return Uint8List.fromList(utf8.encode(_html(book, dataImages: true)));
    case ExportFormat.txt:
      return Uint8List.fromList(utf8.encode(_plain(book, markdown: false)));
    case ExportFormat.markdown:
      return Uint8List.fromList(utf8.encode(_plain(book, markdown: true)));
    case ExportFormat.rtf:
      return Uint8List.fromList(utf8.encode(_rtf(book)));
    case ExportFormat.docx:
      return _docx(book);
    case ExportFormat.pdf:
      return _pdf(book);
    case ExportFormat.cbz:
      return _cbz(book);
  }
}

Uint8List? readSystemTextFont() {
  const paths = [
    '/system/fonts/NotoNaskhArabic-Regular.ttf',
    '/system/fonts/NotoSansArabic-Regular.ttf',
    '/system/fonts/NotoSerif-Regular.ttf',
    '/system/fonts/NotoSans-Regular.ttf',
    '/system/fonts/Roboto-Regular.ttf',
    '/system/fonts/DroidSans.ttf',
  ];
  for (final path in paths) {
    try {
      final file = File(path);
      if (!file.existsSync()) continue;
      final bytes = file.readAsBytesSync();
      if (bytes.length > 1000) return bytes;
    } catch (_) {}
  }
  return null;
}

Future<LoadedBook> _loadPdf(
  String path,
  String title,
  void Function(String status)? onStatus,
) async {
  await pdfrxFlutterInitialize();
  final document = await PdfDocument.openFile(path);
  try {
    final chapters = <BookChapter>[];
    final count = document.pages.length;
    for (var i = 0; i < count; i++) {
      onStatus?.call('Reading page ${i + 1} of $count…');
      await Future<void>.delayed(Duration.zero);
      final page = document.pages[i];
      final raw = await page.loadText();
      final text = raw?.fullText.trim() ?? '';
      if (text.length >= 20) {
        chapters.add(BookChapter(title: 'Page ${i + 1}', blocks: [BookBlock.text([TextRun(text)])]));
        continue;
      }
      final image = await _renderPdfPage(page);
      if (image != null) {
        chapters.add(BookChapter(title: 'Page ${i + 1}', blocks: [BookBlock.image(image)]));
      } else if (text.isNotEmpty) {
        chapters.add(BookChapter(title: 'Page ${i + 1}', blocks: [BookBlock.text([TextRun(text)])]));
      }
    }
    if (chapters.isEmpty) {
      throw BookOpenException('No text or pages could be read from this PDF.');
    }
    return LoadedBook(title: title, chapters: chapters);
  } finally {
    await document.dispose();
  }
}

Future<Uint8List?> _renderPdfPage(PdfPage page) async {
  try {
    final scale = math.min(1.5, 900 / math.max(page.width, 1));
    final width = math.max(200, (page.width * scale).round());
    final height = math.max(200, (page.height * scale).round());
    final rendered = await page.render(fullWidth: width.toDouble(), fullHeight: height.toDouble());
    if (rendered == null) return null;
    try {
      final image = await rendered.createImage();
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) return null;
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } finally {
        image.dispose();
      }
    } finally {
      rendered.dispose();
    }
  } catch (_) {
    return null;
  }
}

LoadedBook _loadComic(String path, String title) {
  final bytes = File(path).readAsBytesSync();
  final Archive archive;
  final lower = path.toLowerCase();
  try {
    archive = lower.endsWith('.cbt') || lower.endsWith('.tar')
        ? TarDecoder().decodeBytes(bytes)
        : ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw BookOpenException('This comic archive could not be read.');
  }
  final files = archive.files.where((file) => file.isFile && BookKindDetect.isImageName(file.name)).toList()
    ..sort((a, b) => _natural(a.name, b.name));
  if (files.isEmpty) throw BookOpenException('No pictures were found in this file.');
  return LoadedBook(
    title: title,
    chapters: [
      BookChapter(
        title: title,
        blocks: [for (final file in files) BookBlock.image(Uint8List.fromList(file.content))],
      ),
    ],
  );
}

Uint8List _epub(LoadedBook book) {
  final images = <_StoredImage>[];
  final archive = Archive();
  archive.addFile(
    ArchiveFile.string('mimetype', 'application/epub+zip')..compression = CompressionType.none,
  );
  archive.addFile(ArchiveFile.string(
    'META-INF/container.xml',
    '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''',
  ));

  final chapterNames = <String>[];
  for (var i = 0; i < book.chapters.length; i++) {
    final name = 'c${i + 1}.xhtml';
    chapterNames.add(name);
    archive.addFile(ArchiveFile.string('OEBPS/$name', _xhtml(book.chapters[i], book.title, images)));
  }
  for (final image in images) {
    archive.addFile(ArchiveFile('OEBPS/images/${image.name}', image.bytes.length, image.bytes));
  }
  archive.addFile(ArchiveFile.string('OEBPS/content.opf', _opf(book.title, chapterNames, images)));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

String _xhtml(BookChapter chapter, String bookTitle, List<_StoredImage> images) {
  final body = StringBuffer();
  final heading = chapter.title.isEmpty ? bookTitle : chapter.title;
  body.writeln('<h1>${_xml(heading)}</h1>');
  for (final block in chapter.blocks) {
    if (block.isImage && block.bytes != null) {
      final name = 'img${images.length + 1}.${_imageExt(block.bytes!)}';
      images.add(_StoredImage(name, block.bytes!));
      body.writeln('<p><img src="images/$name" alt=""/></p>');
    } else {
      body.writeln(_textTag(block.runs ?? const []));
    }
  }
  return '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>${_xml(heading)}</title></head>
<body>
$body</body>
</html>
''';
}

String _opf(String title, List<String> chapters, List<_StoredImage> images) {
  final manifest = StringBuffer();
  final spine = StringBuffer();
  for (var i = 0; i < chapters.length; i++) {
    manifest.writeln('    <item id="c$i" href="${chapters[i]}" media-type="application/xhtml+xml"/>');
    spine.writeln('    <itemref idref="c$i"/>');
  }
  for (var i = 0; i < images.length; i++) {
    manifest.writeln(
      '    <item id="img$i" href="images/${images[i].name}" media-type="${_mimeForName(images[i].name)}"/>',
    );
  }
  return '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">urn:uuid:${DateTime.now().microsecondsSinceEpoch}</dc:identifier>
    <dc:title>${_xml(title)}</dc:title>
    <dc:language>und</dc:language>
  </metadata>
  <manifest>
$manifest  </manifest>
  <spine>
$spine  </spine>
</package>
''';
}

Uint8List _mobi(LoadedBook book) {
  final images = <Uint8List>[];
  final html = _html(book, dataImages: false, mobiImages: images);
  final htmlBytes = Uint8List.fromList(utf8.encode(html));
  const recordSize = 4096;
  final textRecords = <Uint8List>[];
  if (htmlBytes.isEmpty) {
    textRecords.add(Uint8List(0));
  } else {
    for (var i = 0; i < htmlBytes.length; i += recordSize) {
      final end = math.min(i + recordSize, htmlBytes.length);
      textRecords.add(Uint8List.sublistView(htmlBytes, i, end));
    }
  }

  final titleBytes = Uint8List.fromList(utf8.encode(book.title));
  const headerEnd = 0xF8;
  final record0 = Uint8List(headerEnd + titleBytes.length);
  final view = ByteData.sublistView(record0);
  view.setUint16(0, 1);
  view.setUint32(4, htmlBytes.length);
  view.setUint16(8, textRecords.length);
  view.setUint16(10, recordSize);
  record0.setRange(0x10, 0x14, ascii.encode('MOBI'));
  view.setUint32(0x14, 0xE8);
  view.setUint32(0x18, 2);
  view.setUint32(0x1C, 65001);
  view.setUint32(0x20, 1);
  view.setUint32(0x24, 6);
  view.setUint32(0x54, headerEnd);
  view.setUint32(0x58, titleBytes.length);
  view.setUint32(0x68, 6);
  view.setUint32(0x6C, 1 + textRecords.length);
  record0.setRange(headerEnd, headerEnd + titleBytes.length, titleBytes);
  return _palmDatabase(book.title, [record0, ...textRecords, ...images]);
}

Uint8List _palmDatabase(String name, List<Uint8List> records) {
  final header = Uint8List(78);
  final nameBytes = utf8.encode(name);
  header.setRange(0, math.min(31, nameBytes.length), nameBytes);
  header.setRange(60, 64, ascii.encode('BOOK'));
  header.setRange(64, 68, ascii.encode('MOBI'));
  ByteData.sublistView(header).setUint16(76, records.length);

  final index = Uint8List(records.length * 8);
  final indexView = ByteData.sublistView(index);
  var offset = 78 + index.length;
  for (var i = 0; i < records.length; i++) {
    indexView.setUint32(i * 8, offset);
    offset += records[i].length;
  }
  final out = BytesBuilder(copy: false);
  out.add(header);
  out.add(index);
  for (final record in records) {
    out.add(record);
  }
  return out.toBytes();
}

String _fb2(LoadedBook book) {
  final images = <_StoredImage>[];
  final body = StringBuffer();
  for (final chapter in book.chapters) {
    body.writeln('    <section>');
    body.writeln('      <title><p>${_xml(chapter.title)}</p></title>');
    for (final block in chapter.blocks) {
      if (block.isImage && block.bytes != null) {
        final id = 'img${images.length + 1}';
        images.add(_StoredImage(id, block.bytes!));
        body.writeln('      <image l:href="#$id"/>');
      } else {
        body.writeln('      ${_textTag(block.runs ?? const [])}');
      }
    }
    body.writeln('    </section>');
  }
  final binaries = StringBuffer();
  for (final image in images) {
    binaries.writeln(
      '  <binary id="${image.name}" content-type="${_mime(image.bytes)}">${base64.encode(image.bytes)}</binary>',
    );
  }
  return '''
<?xml version="1.0" encoding="utf-8"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
  <description>
    <title-info>
      <book-title>${_xml(book.title)}</book-title>
      <lang>und</lang>
    </title-info>
  </description>
  <body>
$body  </body>
$binaries</FictionBook>
''';
}

String _html(LoadedBook book, {required bool dataImages, List<Uint8List>? mobiImages}) {
  final body = StringBuffer();
  body.writeln('<h1>${_xml(book.title)}</h1>');
  for (final chapter in book.chapters) {
    if (chapter.title.isNotEmpty) body.writeln('<h2>${_xml(chapter.title)}</h2>');
    for (final block in chapter.blocks) {
      if (block.isImage && block.bytes != null) {
        if (mobiImages != null) {
          mobiImages.add(block.bytes!);
          final index = mobiImages.length.toString().padLeft(5, '0');
          body.writeln('<p><img recindex="$index"/></p>');
        } else if (dataImages) {
          body.writeln(
            '<p><img src="data:${_mime(block.bytes!)};base64,${base64.encode(block.bytes!)}" alt=""/></p>',
          );
        } else {
          body.writeln('<p>[Picture]</p>');
        }
      } else {
        body.writeln(_textTag(block.runs ?? const []));
      }
    }
  }
  return '''
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>${_xml(book.title)}</title></head>
<body>
$body</body></html>
''';
}

String _plain(LoadedBook book, {required bool markdown}) {
  final out = StringBuffer();
  out.writeln(markdown ? '# ${book.title}' : book.title);
  out.writeln();
  for (final chapter in book.chapters) {
    if (chapter.title.isNotEmpty) {
      out.writeln(markdown ? '## ${chapter.title}' : chapter.title);
      out.writeln();
    }
    for (final block in chapter.blocks) {
      if (block.isImage) {
        out.writeln(markdown ? '*[Picture]*' : '[Picture]');
        out.writeln();
        continue;
      }
      final text = (block.runs ?? const <TextRun>[]).map((run) => run.text).join().trim();
      if (text.isEmpty) continue;
      final heading = (block.runs ?? const <TextRun>[]).fold<int>(0, (max, run) => math.max(max, run.heading));
      if (markdown && heading > 0) {
        out.writeln('${'#' * (heading + 1)} $text');
      } else {
        out.writeln(text);
      }
      out.writeln();
    }
  }
  return out.toString().trimRight();
}

String _rtf(LoadedBook book) {
  final out = StringBuffer()..write(r'{\rtf1\ansi\uc1\deff0{\fonttbl{\f0\fnil Arial;}}');
  out.write(r'\f0\fs24 ');
  out.write(_rtfText(book.title));
  out.write(r'\par\par ');
  for (final chapter in book.chapters) {
    if (chapter.title.isNotEmpty) {
      out.write(r'\b ');
      out.write(_rtfText(chapter.title));
      out.write(r'\b0\par\par ');
    }
    for (final block in chapter.blocks) {
      if (block.isImage) {
        out.write(r'[Picture]\par ');
        continue;
      }
      final text = (block.runs ?? const <TextRun>[]).map((run) => run.text).join();
      final bold = (block.runs ?? const <TextRun>[]).any((run) => run.bold || run.heading > 0);
      if (bold) out.write(r'\b ');
      out.write(_rtfText(text));
      if (bold) out.write(r'\b0 ');
      out.write(r'\par\par ');
    }
  }
  out.write('}');
  return out.toString();
}

String _rtfText(String text) {
  final out = StringBuffer();
  for (final rune in text.runes) {
    if (rune == 10 || rune == 13) {
      out.write(r'\line ');
      continue;
    }
    if (rune == 92 || rune == 123 || rune == 125) {
      out.write('\\${String.fromCharCode(rune)}');
      continue;
    }
    if (rune < 128) {
      out.writeCharCode(rune);
      continue;
    }
    final value = rune > 32767 ? rune - 65536 : rune;
    out.write('\\u$value?');
  }
  return out.toString();
}

Uint8List _docx(LoadedBook book) {
  final body = StringBuffer();
  void paragraph(String text, {bool bold = false}) {
    final escaped = _xml(text);
    final style = bold ? '<w:rPr><w:b/></w:rPr>' : '';
    body.write('<w:p><w:r>$style<w:t xml:space="preserve">$escaped</w:t></w:r></w:p>');
  }

  paragraph(book.title, bold: true);
  for (final chapter in book.chapters) {
    if (chapter.title.isNotEmpty) paragraph(chapter.title, bold: true);
    for (final block in chapter.blocks) {
      if (block.isImage) {
        paragraph('[Picture]');
        continue;
      }
      final text = (block.runs ?? const <TextRun>[]).map((run) => run.text).join().trim();
      if (text.isEmpty) continue;
      final bold = (block.runs ?? const <TextRun>[]).any((run) => run.bold || run.heading > 0);
      paragraph(text, bold: bold);
    }
  }
  final document = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>$body</w:body>
</w:document>
''';
  const contentTypes = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>
''';
  const rels = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>
''';
  final archive = Archive()
    ..addFile(ArchiveFile.string('[Content_Types].xml', contentTypes))
    ..addFile(ArchiveFile.string('_rels/.rels', rels))
    ..addFile(ArchiveFile.string('word/document.xml', document));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Future<pw.Font?> _pdfFont() async {
  final bundled = await _bundledFontBytes();
  if (bundled != null) {
    try {
      return pw.Font.ttf(ByteData.sublistView(bundled));
    } catch (_) {}
  }
  final system = readSystemTextFont();
  if (system == null) return null;
  try {
    return pw.Font.ttf(ByteData.sublistView(system));
  } catch (_) {
    return null;
  }
}

Future<Uint8List?> _bundledFontBytes() async {
  try {
    final data = await rootBundle.load('assets/fonts/NotoNaskhArabic-Regular.ttf');
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    if (bytes.length > 1000) return bytes;
  } catch (_) {}
  final file = File('assets/fonts/NotoNaskhArabic-Regular.ttf');
  try {
    if (file.existsSync()) {
      final bytes = file.readAsBytesSync();
      if (bytes.length > 1000) return bytes;
    }
  } catch (_) {}
  return null;
}

Future<Uint8List> _pdf(LoadedBook book) async {
  final font = await _pdfFont();
  final base = _pdfStyle(font, 12);
  final doc = pw.Document();
  final widgets = <pw.Widget>[
    _pdfParagraph(book.title, _pdfStyle(font, 18)),
    pw.SizedBox(height: 8),
  ];
  for (final chapter in book.chapters) {
    if (chapter.title.isNotEmpty) {
      widgets.add(_pdfParagraph(chapter.title, _pdfStyle(font, 16)));
    }
    for (final block in chapter.blocks) {
      if (block.isImage && block.bytes != null) {
        final image = _pdfImage(block.bytes!);
        widgets.add(image ?? pw.Text('[Picture]', style: base));
      } else {
        final text = (block.runs ?? const <TextRun>[]).map((run) => run.text).join().trim();
        if (text.isEmpty) continue;
        widgets.add(_pdfParagraph(text, base));
      }
    }
  }
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      build: (context) => widgets,
    ),
  );
  try {
    return await doc.save();
  } catch (_) {
    throw BookOpenException(
      'This book could not be written as a PDF. Try HTML or EPUB instead.',
    );
  }
}

pw.TextStyle _pdfStyle(pw.Font? font, double size) {
  if (font == null) return pw.TextStyle(fontSize: size);
  return pw.TextStyle(font: font, fontFallback: [pw.Font.helvetica()], fontSize: size);
}

pw.Widget _pdfParagraph(String text, pw.TextStyle style) {
  final rtl = _hasArabic(text);
  return pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 8),
    child: pw.Text(
      text,
      style: style,
      textAlign: rtl ? pw.TextAlign.right : pw.TextAlign.left,
      textDirection: rtl ? pw.TextDirection.rtl : pw.TextDirection.ltr,
    ),
  );
}

pw.Widget? _pdfImage(Uint8List bytes) {
  try {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 8),
      child: pw.Image(
        pw.MemoryImage(bytes),
        fit: pw.BoxFit.contain,
        width: 450,
        height: 620,
      ),
    );
  } catch (_) {
    return null;
  }
}

bool _hasArabic(String text) {
  for (final rune in text.runes) {
    if (rune >= 0x0600 && rune <= 0x06FF) return true;
    if (rune >= 0x0750 && rune <= 0x077F) return true;
    if (rune >= 0x08A0 && rune <= 0x08FF) return true;
    if (rune >= 0xFB50 && rune <= 0xFDFF) return true;
    if (rune >= 0xFE70 && rune <= 0xFEFF) return true;
  }
  return false;
}

Uint8List _cbz(LoadedBook book) {
  final archive = Archive();
  var index = 1;
  for (final chapter in book.chapters) {
    for (final block in chapter.blocks) {
      if (!block.isImage || block.bytes == null) continue;
      final name = 'page_${index.toString().padLeft(4, '0')}.${_imageExt(block.bytes!)}';
      archive.addFile(ArchiveFile(name, block.bytes!.length, block.bytes!));
      index++;
    }
  }
  if (archive.files.isEmpty) {
    throw BookOpenException(
      'This book has no pictures, so it cannot be saved as a CBZ comic. Choose EPUB, PDF, TXT, or another text format.',
    );
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

String _textTag(List<TextRun> runs) {
  if (runs.isEmpty) return '';
  final heading = runs.fold<int>(0, (max, run) => math.max(max, run.heading));
  final tag = heading == 1
      ? 'h1'
      : heading == 2
          ? 'h2'
          : heading >= 3
              ? 'h3'
              : 'p';
  final inner = StringBuffer();
  for (final run in runs) {
    var text = _xml(run.text);
    if (heading == 0 && run.italic) text = '<em>$text</em>';
    if (heading == 0 && run.bold) text = '<strong>$text</strong>';
    inner.write(text);
  }
  final value = inner.toString().trim();
  if (value.isEmpty) return '';
  return '<$tag>$value</$tag>';
}

String _xml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String _imageExt(Uint8List bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8) return 'jpg';
  if (bytes.length >= 8 && bytes[0] == 0x89 && bytes[1] == 0x50) return 'png';
  if (bytes.length >= 6 && bytes[0] == 0x47 && bytes[1] == 0x49) return 'gif';
  if (bytes.length >= 12 && ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') return 'webp';
  return 'img';
}

String _mime(Uint8List bytes) => _mimeForName('file.${_imageExt(bytes)}');

String _mimeForName(String name) {
  final ext = p.extension(name).toLowerCase();
  switch (ext) {
    case '.png':
      return 'image/png';
    case '.gif':
      return 'image/gif';
    case '.webp':
      return 'image/webp';
    default:
      return 'image/jpeg';
  }
}

String _titleFromPath(String path) {
  final name = p.basename(path);
  final dot = name.lastIndexOf('.');
  final base = dot > 0 ? name.substring(0, dot) : name;
  final cleaned = base.replaceAll('_', ' ').trim();
  return cleaned.isEmpty ? 'Book' : cleaned;
}

int _natural(String a, String b) {
  final re = RegExp(r'\d+|\D+');
  final aa = re.allMatches(a.toLowerCase()).map((m) => m.group(0)!).toList();
  final bb = re.allMatches(b.toLowerCase()).map((m) => m.group(0)!).toList();
  final n = math.min(aa.length, bb.length);
  for (var i = 0; i < n; i++) {
    final an = int.tryParse(aa[i]);
    final bn = int.tryParse(bb[i]);
    final c = an != null && bn != null ? an.compareTo(bn) : aa[i].compareTo(bb[i]);
    if (c != 0) return c;
  }
  return aa.length.compareTo(bb.length);
}

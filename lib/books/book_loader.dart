import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'book_content.dart';
import 'book_kind.dart';
import 'mobi_book.dart';

class BookLoader {
  static Future<LoadedBook> load(String path, BookKind kind, List<int> bytes) async {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final title = _fileTitle(path);
    switch (kind) {
      case BookKind.epub:
        return _epub(data, title);
      case BookKind.mobi:
        return MobiBook.parse(data, fallbackTitle: title);
      case BookKind.fb2:
        return _fb2(data, title);
      case BookKind.docx:
        return _docx(data, title);
      case BookKind.html:
        return _html(data, title);
      case BookKind.rtf:
        return _plain(_rtfToText(latin1.decode(data, allowInvalid: true)), title);
      case BookKind.text:
        return _plain(_textBody(data, path), title);
      case BookKind.comic:
      case BookKind.pdf:
      case BookKind.unsupported:
        throw BookOpenException('This format cannot be opened as a flowing book.');
    }
  }

  static String _fileTitle(String path) {
    final slash = path.replaceAll('\\', '/');
    final name = slash.split('/').last;
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    return base.replaceAll('_', ' ').trim().isEmpty ? 'Book' : base.replaceAll('_', ' ').trim();
  }

  static LoadedBook _html(Uint8List bytes, String title) {
    final text = _decodeMarkup(bytes);
    final chapters = htmlToChapters(text, fallbackTitle: title);
    if (chapters.isEmpty) throw BookOpenException('This HTML file has no readable text.');
    return LoadedBook(title: title, chapters: chapters);
  }

  static LoadedBook _plain(String text, String title) {
    final cleaned = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
    if (cleaned.isEmpty) throw BookOpenException('This file is empty.');
    final lines = cleaned.split('\n');
    final chapters = <BookChapter>[];
    final blocks = <BookBlock>[];
    var chapterTitle = title;
    final paragraph = StringBuffer();

    void flushParagraph() {
      final value = paragraph.toString().trim();
      paragraph.clear();
      if (value.isEmpty) return;
      blocks.add(BookBlock.text([TextRun(value)]));
    }

    void flushChapter() {
      flushParagraph();
      if (blocks.isEmpty) return;
      chapters.add(BookChapter(title: chapterTitle, blocks: List<BookBlock>.from(blocks)));
      blocks.clear();
    }

    for (final raw in lines) {
      final line = raw.trimRight();
      final heading = RegExp(r'^(#{1,3})\s+(.+)$').firstMatch(line.trim());
      if (heading != null) {
        flushChapter();
        chapterTitle = heading.group(2)!.trim();
        blocks.add(BookBlock.text([TextRun(chapterTitle, bold: true, heading: heading.group(1)!.length)]));
        continue;
      }
      if (line.trim().isEmpty) {
        flushParagraph();
        continue;
      }
      if (paragraph.isNotEmpty) paragraph.write(' ');
      paragraph.write(line.trim());
    }
    flushChapter();
    if (chapters.isEmpty) throw BookOpenException('This file is empty.');
    if (chapters.length == 1) {
      return LoadedBook(title: title, chapters: [BookChapter(title: title, blocks: chapters.first.blocks)]);
    }
    return LoadedBook(title: title, chapters: chapters);
  }

  static String _textBody(Uint8List bytes, String path) {
    final lower = path.toLowerCase();
    final text = utf8.decode(bytes, allowMalformed: true);
    if (!lower.endsWith('.md') && !lower.endsWith('.markdown')) {
      return text.replaceAll(RegExp(r'^#{1,3}\s+', multiLine: true), '');
    }
    return text;
  }

  static LoadedBook _epub(Uint8List bytes, String fallbackTitle) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw BookOpenException('This EPUB is damaged or not a zip file.');
    }
    final files = <String, Uint8List>{};
    for (final file in archive.files) {
      if (!file.isFile) continue;
      files[_norm(file.name)] = file.content;
    }
    final container = files['meta-inf/container.xml'];
    if (container == null) throw BookOpenException('This EPUB has no container.xml.');
    final containerDoc = XmlDocument.parse(_decodeMarkup(container));
    final root = _elements(containerDoc, 'rootfile').firstOrNull;
    final opfPath = root?.getAttribute('full-path');
    if (opfPath == null || opfPath.isEmpty) {
      throw BookOpenException('This EPUB does not point at a package file.');
    }
    final opfKey = _norm(opfPath);
    final opfBytes = files[opfKey];
    if (opfBytes == null) throw BookOpenException('Missing EPUB package: $opfPath');
    final opf = XmlDocument.parse(_decodeMarkup(opfBytes));
    final title = _elements(opf, 'title').map((e) => e.innerText.trim()).firstWhere(
          (t) => t.isNotEmpty,
          orElse: () => fallbackTitle,
        );
    final manifest = <String, String>{};
    for (final item in _elements(opf, 'item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id != null && href != null) manifest[id] = href;
    }
    final chapters = <BookChapter>[];
    for (final ref in _elements(opf, 'itemref')) {
      final id = ref.getAttribute('idref');
      final href = id == null ? null : manifest[id];
      if (href == null) continue;
      final full = _joinZip(opfKey, Uri.decodeFull(href.split('#').first));
      final data = files[full];
      if (data == null) continue;
      final markup = _decodeMarkup(data).trimLeft();
      if (!markup.startsWith('<')) {
        throw BookOpenException(
          'This EPUB is encrypted. Open a DRM-free copy.',
        );
      }
      final part = htmlToChapters(
        markup,
        fallbackTitle: 'Chapter ${chapters.length + 1}',
        images: (src) {
          final key = _joinZip(full, Uri.decodeFull(src.split('#').first));
          return files[key] ?? files[key.toLowerCase()];
        },
      );
      chapters.addAll(part);
    }
    if (chapters.isEmpty) throw BookOpenException('This EPUB has no readable chapters.');
    return LoadedBook(title: title, chapters: chapters);
  }

  static LoadedBook _fb2(Uint8List bytes, String fallbackTitle) {
    var data = bytes;
    if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
      data = Uint8List.fromList(GZipDecoder().decodeBytes(bytes));
    }
    if (bytes.length >= 2 && bytes[0] == 0x50 && bytes[1] == 0x4b) {
      final archive = ZipDecoder().decodeBytes(bytes);
      final fb2 = archive.files.where((f) => f.isFile && f.name.toLowerCase().endsWith('.fb2')).firstOrNull;
      if (fb2 == null) throw BookOpenException('No FB2 file was found in this zip.');
      data = fb2.content;
    }
    final doc = XmlDocument.parse(_decodeMarkup(data));
    final title = _elements(doc, 'book-title').map((e) => e.innerText.trim()).firstWhere(
          (t) => t.isNotEmpty,
          orElse: () => fallbackTitle,
        );
    final images = <String, Uint8List>{};
    for (final binary in _elements(doc, 'binary')) {
      final id = binary.getAttribute('id');
      if (id == null) continue;
      try {
        images[id] = Uint8List.fromList(base64.decode(binary.innerText.replaceAll(RegExp(r'\s+'), '')));
      } catch (_) {}
    }
    final chapters = <BookChapter>[];
    void walkSection(XmlElement section, String parentTitle) {
      final titleText = section.childElements
          .where((e) => e.name.local == 'title')
          .map((e) => e.innerText.replaceAll(RegExp(r'\s+'), ' ').trim())
          .firstWhere((t) => t.isNotEmpty, orElse: () => parentTitle);
      final blocks = <BookBlock>[];
      for (final child in section.childElements) {
        final name = child.name.local;
        if (name == 'p' || name == 'subtitle' || name == 'title') {
          final text = child.innerText.replaceAll(RegExp(r'\s+'), ' ').trim();
          if (text.isNotEmpty) {
            blocks.add(
              BookBlock.text([
                TextRun(
                  text,
                  bold: name != 'p',
                  heading: name == 'title' ? 1 : name == 'subtitle' ? 2 : 0,
                ),
              ]),
            );
          }
          for (final image in child.childElements.where((e) => e.name.local == 'image')) {
            _addFb2Image(image, images, blocks);
          }
        } else if (name == 'image') {
          _addFb2Image(child, images, blocks);
        }
      }
      if (blocks.isNotEmpty) {
        chapters.add(BookChapter(title: titleText.isEmpty ? 'Section ${chapters.length + 1}' : titleText, blocks: blocks));
      }
      for (final child in section.childElements.where((e) => e.name.local == 'section')) {
        walkSection(child, titleText);
      }
    }

    final bodies = _elements(doc, 'body').where((b) => (b.getAttribute('name') ?? '') != 'notes');
    for (final body in bodies) {
      for (final section in body.childElements.where((e) => e.name.local == 'section')) {
        walkSection(section, title);
      }
    }
    if (chapters.isEmpty) throw BookOpenException('This FB2 file has no readable text.');
    return LoadedBook(title: title, chapters: chapters);
  }

  static LoadedBook _docx(Uint8List bytes, String fallbackTitle) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw BookOpenException('This DOCX is damaged.');
    }
    final document = archive.files.where((f) => f.name.replaceAll('\\', '/') == 'word/document.xml').firstOrNull;
    if (document == null) throw BookOpenException('This DOCX has no document.xml.');
    final xml = XmlDocument.parse(utf8.decode(document.content, allowMalformed: true));
    final blocks = <BookBlock>[];
    for (final paragraph in _elements(xml, 'p')) {
      final buffer = StringBuffer();
      var bold = false;
      for (final node in paragraph.descendants.whereType<XmlElement>()) {
        if (node.name.local == 't') buffer.write(node.innerText);
        if (node.name.local == 'tab') buffer.write('\t');
        if (node.name.local == 'br') buffer.write('\n');
        if (node.name.local == 'b' && node.getAttribute('w:val') != '0') bold = true;
      }
      final text = buffer.toString().trim();
      if (text.isEmpty) continue;
      final style = paragraph.descendants
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'pStyle')
          .map((e) => e.getAttribute('w:val') ?? e.attributes.where((a) => a.name.local == 'val').map((a) => a.value).firstOrNull ?? '')
          .firstOrNull;
      final heading = style != null && style.toLowerCase().contains('heading');
      blocks.add(BookBlock.text([TextRun(text, bold: bold || heading, heading: heading ? 2 : 0)]));
    }
    if (blocks.isEmpty) throw BookOpenException('This DOCX has no readable text.');
    return LoadedBook(title: fallbackTitle, chapters: [BookChapter(title: fallbackTitle, blocks: blocks)]);
  }

  static void _addFb2Image(XmlElement image, Map<String, Uint8List> images, List<BookBlock> blocks) {
    final href = image.attributes.where((a) => a.name.local == 'href').map((a) => a.value).firstOrNull ?? '';
    final id = href.startsWith('#') ? href.substring(1) : href;
    final bytes = images[id];
    if (bytes != null) blocks.add(BookBlock.image(bytes));
  }

  static Iterable<XmlElement> _elements(XmlNode node, String local) =>
      node.descendants.whereType<XmlElement>().where((e) => e.name.local == local);

  static String _norm(String path) => path.replaceAll('\\', '/').replaceAll(RegExp(r'^\./'), '').toLowerCase();

  static String _joinZip(String baseFile, String relative) {
    final rel = relative.trim().replaceAll('\\', '/');
    if (rel.isEmpty) return _norm(baseFile);
    if (rel.startsWith('/')) return _norm(rel.substring(1));
    final slash = baseFile.lastIndexOf('/');
    final dir = slash >= 0 ? baseFile.substring(0, slash) : '';
    final combined = dir.isEmpty ? rel : '$dir/$rel';
    final parts = <String>[];
    for (final part in combined.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else {
        parts.add(part);
      }
    }
    return parts.join('/').toLowerCase();
  }

  static String _decodeMarkup(Uint8List bytes) {
    final sample = latin1.decode(bytes.take(bytes.length < 240 ? bytes.length : 240).toList(), allowInvalid: true);
    final match = RegExp("encoding\\s*=\\s*[\"']([^\"']+)", caseSensitive: false).firstMatch(sample);
    final encoding = match?.group(1)?.toLowerCase() ?? '';
    if (encoding.contains('1251') || encoding.contains('windows-1251') || encoding.contains('cp1251')) {
      return _decode1251(bytes);
    }
    if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static String _decode1251(Uint8List bytes) {
    const high = <int>[
      0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021,
      0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F,
      0x0452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
      0x0098, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F,
      0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7,
      0x0401, 0x00A9, 0x0404, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x0407,
      0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7,
      0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457,
    ];
    final out = StringBuffer();
    for (final b in bytes) {
      if (b < 0x80) {
        out.writeCharCode(b);
      } else if (b < 0xC0) {
        out.writeCharCode(high[b - 0x80]);
      } else {
        out.writeCharCode(0x0410 + (b - 0xC0));
      }
    }
    return out.toString();
  }

  static String _rtfToText(String rtf) {
    final out = StringBuffer();
    var i = 0;

    void skipGroup() {
      var depth = 1;
      i++;
      while (i < rtf.length && depth > 0) {
        final c = rtf[i++];
        if (c == '{') depth++;
        if (c == '}') depth--;
        if (c == '\\' && i < rtf.length) i++;
      }
    }

    while (i < rtf.length) {
      final c = rtf[i];
      if (c == '{') {
        final snapshot = i;
        var j = i + 1;
        if (j < rtf.length && rtf[j] == '\\') {
          if (j + 1 < rtf.length && rtf[j + 1] == '*') j += 2;
          final start = j + (rtf[j] == '\\' ? 1 : 0);
          var k = start;
          while (k < rtf.length && RegExp(r'[A-Za-z]').hasMatch(rtf[k])) {
            k++;
          }
          final word = rtf.substring(start, k);
          const skip = {
            'fonttbl',
            'colortbl',
            'stylesheet',
            'info',
            'pict',
            'object',
            'header',
            'footer',
            'headerl',
            'headerr',
            'footerl',
            'footerr',
            'footnote',
            'xe',
            'tc',
            'field',
            'datafield',
            'datastore',
            'themedata',
            'colorschememapping',
            'latentstyles',
            'rsidtbl',
          };
          if (skip.contains(word)) {
            i = snapshot;
            skipGroup();
            continue;
          }
        }
        i++;
        continue;
      }
      if (c == '}') {
        i++;
        continue;
      }
      if (c == '\\') {
        i++;
        if (i >= rtf.length) break;
        final n = rtf[i];
        if (n == '\\' || n == '{' || n == '}') {
          out.write(n);
          i++;
          continue;
        }
        if (n == "'") {
          if (i + 2 < rtf.length) {
            final code = int.tryParse(rtf.substring(i + 1, i + 3), radix: 16);
            if (code != null) out.writeCharCode(code);
            i += 3;
          } else {
            i++;
          }
          continue;
        }
        if (n == 'u' && i + 1 < rtf.length && (rtf[i + 1] == '-' || _digit(rtf[i + 1]))) {
          i++;
          final start = i;
          if (rtf[i] == '-') i++;
          while (i < rtf.length && _digit(rtf[i])) {
            i++;
          }
          var code = int.tryParse(rtf.substring(start, i)) ?? 0;
          if (code < 0) code += 65536;
          if (code > 0 && code <= 0x10FFFF) out.writeCharCode(code);
          if (i < rtf.length && (rtf[i] == '?' || rtf[i] == ' ')) i++;
          continue;
        }
        final start = i;
        while (i < rtf.length && RegExp(r'[A-Za-z]').hasMatch(rtf[i])) {
          i++;
        }
        final word = rtf.substring(start, i);
        if (i < rtf.length && rtf[i] == '-') i++;
        while (i < rtf.length && _digit(rtf[i])) {
          i++;
        }
        if (i < rtf.length && rtf[i] == ' ') i++;
        if (word == 'par' || word == 'line') out.write('\n');
        if (word == 'tab') out.write('\t');
        continue;
      }
      if (c == '\n' || c == '\r') {
        i++;
        continue;
      }
      out.write(c);
      i++;
    }
    return out.toString();
  }

  static bool _digit(String c) => c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (!iterator.moveNext()) return null;
    return iterator.current;
  }
}

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

enum BookKind { pdf, epub, mobi, fb2, html, text, rtf, docx, comic, unsupported }

class BookKindDetect {
  static BookKind fromPath(String path) {
    final name = p.basename(path).toLowerCase();
    if (name.endsWith('.fb2.zip')) return BookKind.fb2;
    switch (p.extension(name)) {
      case '.pdf':
        return BookKind.pdf;
      case '.epub':
        return BookKind.epub;
      case '.mobi':
      case '.azw':
      case '.azw3':
      case '.azw4':
      case '.prc':
      case '.kf8':
        return BookKind.mobi;
      case '.fb2':
        return BookKind.fb2;
      case '.html':
      case '.htm':
      case '.xhtml':
        return BookKind.html;
      case '.txt':
      case '.text':
      case '.md':
      case '.markdown':
        return BookKind.text;
      case '.rtf':
        return BookKind.rtf;
      case '.docx':
        return BookKind.docx;
      case '.cbz':
      case '.cbt':
      case '.tar':
        return BookKind.comic;
      case '.zip':
        return BookKind.comic;
      default:
        return BookKind.unsupported;
    }
  }

  /// Uses the extension, then the file header, so shared files without a
  /// useful name still open.
  static Future<BookKind> resolve(String path) async {
    final named = fromPath(path);
    final file = File(path);
    if (!await file.exists()) return named;
    final length = await file.length();
    if (length == 0) return named;
    final raf = await file.open();
    Uint8List head;
    try {
      head = await raf.read(math.min(512, length));
    } finally {
      await raf.close();
    }
    if (_startsWith(head, '%PDF')) return BookKind.pdf;
    if (named == BookKind.pdf ||
        named == BookKind.epub ||
        named == BookKind.mobi ||
        named == BookKind.fb2 ||
        named == BookKind.html ||
        named == BookKind.text ||
        named == BookKind.rtf ||
        named == BookKind.docx) {
      return named;
    }
    if (_isMobi(head)) return BookKind.mobi;
    if (_startsWith(head, '{\\rtf')) return BookKind.rtf;
    if (_isZip(head) || _isGzip(head) || named == BookKind.comic) {
      final bytes = await file.readAsBytes();
      final sniffed = sniffContainer(bytes);
      if (sniffed != BookKind.unsupported) return sniffed;
    }
    if (named != BookKind.unsupported) return named;
    if (_looksLikeXml(head, 'fictionbook')) return BookKind.fb2;
    if (_looksLikeXml(head, 'html')) return BookKind.html;
    if (_looksLikeText(head)) return BookKind.text;
    return BookKind.unsupported;
  }

  static BookKind sniffContainer(Uint8List bytes) {
    if (_isGzip(bytes)) {
      try {
        final raw = Uint8List.fromList(GZipDecoder().decodeBytes(bytes));
        if (_looksLikeXml(raw, 'fictionbook')) return BookKind.fb2;
        if (_looksLikeXml(raw, 'html')) return BookKind.html;
      } catch (_) {}
    }
    if (!_isZip(bytes)) return BookKind.unsupported;
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final names = archive.files.map((f) => f.name.replaceAll('\\', '/').toLowerCase()).toList();
      if (names.any((n) => n == 'mimetype' || n.endsWith('/mimetype'))) {
        for (final file in archive.files) {
          final name = file.name.replaceAll('\\', '/').toLowerCase();
          if (name == 'mimetype' || name.endsWith('/mimetype')) {
            final text = String.fromCharCodes(file.content);
            if (text.contains('epub')) return BookKind.epub;
          }
        }
      }
      if (names.any((n) => n == 'meta-inf/container.xml' || n.endsWith('/container.xml'))) {
        return BookKind.epub;
      }
      if (names.any((n) => n.endsWith('.fb2'))) return BookKind.fb2;
      if (names.any((n) => n == 'word/document.xml')) return BookKind.docx;
      if (names.any(isImageName)) return BookKind.comic;
    } catch (_) {}
    return BookKind.unsupported;
  }

  static bool isImageName(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp');
  }

  static bool _startsWith(Uint8List bytes, String text) {
    if (bytes.length < text.length) return false;
    for (var i = 0; i < text.length; i++) {
      if (bytes[i] != text.codeUnitAt(i)) return false;
    }
    return true;
  }

  static bool _isZip(Uint8List bytes) =>
      bytes.length >= 2 && bytes[0] == 0x50 && bytes[1] == 0x4b;

  static bool _isGzip(Uint8List bytes) =>
      bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;

  static bool _isMobi(Uint8List bytes) {
    if (bytes.length < 68) return false;
    final creator = String.fromCharCodes(bytes.sublist(64, 68));
    final type = String.fromCharCodes(bytes.sublist(60, 64));
    return creator == 'MOBI' || type == 'BOOK';
  }

  static bool _looksLikeXml(Uint8List bytes, String tag) {
    final sample = String.fromCharCodes(bytes.take(math.min(bytes.length, 400))).toLowerCase();
    return sample.contains('<$tag');
  }

  static bool _looksLikeText(Uint8List bytes) {
    final n = math.min(bytes.length, 256);
    if (n == 0) return false;
    var printable = 0;
    for (var i = 0; i < n; i++) {
      final b = bytes[i];
      if (b == 9 || b == 10 || b == 13 || (b >= 32 && b < 127)) printable++;
    }
    return printable / n > 0.85;
  }
}

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'book_content.dart';

class MobiBook {
  static LoadedBook parse(Uint8List bytes, {required String fallbackTitle}) {
    if (bytes.length >= 5 && String.fromCharCodes(bytes.take(5)) == '%PDF-') {
      throw BookOpenException('This file is a PDF. Open it as a PDF.');
    }
    final records = _palmRecords(bytes);
    if (records.isEmpty) {
      throw BookOpenException('This is not a Kindle book.');
    }
    final header = records.first;
    if (header.length < 16) {
      throw BookOpenException('This Kindle file is damaged.');
    }
    final view = ByteData.sublistView(header);
    final compression = view.getUint16(0);
    final textLength = view.getUint32(4);
    final textRecords = view.getUint16(8);
    final encryption = header.length >= 14 ? view.getUint16(12) : 0;
    if (encryption != 0) {
      throw BookOpenException(
        'This Kindle file is locked with DRM. Open an EPUB or a DRM-free copy instead.',
      );
    }

    var codepage = 65001;
    var title = fallbackTitle;
    var firstImage = 0;
    var trailers = 0;
    var multibyte = false;
    if (header.length >= 0x1C && _ascii(header, 0x10, 4) == 'MOBI') {
      codepage = view.getUint32(0x1C);
      if (header.length >= 0x5C) {
        final titleOffset = view.getUint32(0x54);
        final titleLen = view.getUint32(0x58);
        if (titleLen > 0 && titleOffset + titleLen <= header.length) {
          title = _decode(header.sublist(titleOffset, titleOffset + titleLen), codepage).trim();
          if (title.isEmpty) title = fallbackTitle;
        }
      }
      if (header.length >= 0x70) {
        firstImage = view.getUint32(0x6C);
      }
      if (header.length >= 0xF4) {
        final headerLength = view.getUint32(0x14);
        final minVersion = view.getUint32(0x68);
        if (headerLength >= 0xE4 && minVersion >= 5) {
          var flags = view.getUint16(0xF2);
          multibyte = flags & 1 != 0;
          while (flags > 1) {
            if (flags & 2 != 0) trailers++;
            flags >>= 1;
          }
        }
      }
      final exthTitle = _exthTitle(header, codepage);
      if ((title == fallbackTitle || title.isEmpty) && exthTitle != null && exthTitle.isNotEmpty) {
        title = exthTitle;
      }
    }

    if (compression == 17480) {
      final scanned = _scanHtml(bytes);
      if (scanned == null) {
        throw BookOpenException(
          'This Kindle file uses Huff compression. Convert it to EPUB, then open the EPUB.',
        );
      }
      return _fromHtml(scanned, title, const []);
    }
    if (compression != 1 && compression != 2) {
      throw BookOpenException('This Kindle compression ($compression) is not supported.');
    }

    final out = BytesBuilder(copy: false);
    final last = math.min(textRecords, records.length - 1);
    for (var i = 1; i <= last; i++) {
      var record = records[i];
      if (trailers > 0 || multibyte) {
        record = _trimTrailers(record, trailers, multibyte);
      }
      if (compression == 2) {
        out.add(decompressPalmDoc(record));
      } else {
        out.add(record);
      }
    }
    var textBytes = out.toBytes();
    if (textLength > 0 && textLength < textBytes.length) {
      textBytes = Uint8List.sublistView(textBytes, 0, textLength);
    }
    final html = _decode(textBytes, codepage);
    final images = _images(records, firstImage);
    return _fromHtml(html, title, images);
  }

  static LoadedBook _fromHtml(String html, String title, List<Uint8List> images) {
    final chapters = htmlToChapters(
      html,
      fallbackTitle: title,
      images: (src) => _lookupImage(src, images),
    );
    if (chapters.isEmpty) {
      throw BookOpenException('No readable text was found in this Kindle file.');
    }
    return LoadedBook(title: title, chapters: chapters);
  }

  static Uint8List? _lookupImage(String src, List<Uint8List> images) {
    if (images.isEmpty || src.isEmpty) return null;
    final embed = RegExp(r'(?:recindex|embed)[^\d]*(\d+)', caseSensitive: false).firstMatch(src);
    final digits = embed?.group(1) ?? (RegExp(r'^\d+$').hasMatch(src.trim()) ? src.trim() : null);
    if (digits == null) return null;
    final index = int.tryParse(digits);
    if (index == null) return null;
    final zero = index - 1;
    if (zero < 0 || zero >= images.length) return null;
    return images[zero];
  }

  static List<Uint8List> _images(List<Uint8List> records, int firstImage) {
    if (firstImage <= 0 || firstImage >= records.length) {
      final found = <Uint8List>[];
      for (final record in records.skip(1)) {
        if (_isImage(record)) found.add(record);
      }
      return found;
    }
    final images = <Uint8List>[];
    for (var i = firstImage; i < records.length; i++) {
      final record = records[i];
      if (_isImage(record)) images.add(record);
    }
    return images;
  }

  static bool _isImage(Uint8List bytes) {
    if (bytes.length < 4) return false;
    if (bytes[0] == 0xFF && bytes[1] == 0xD8) return true;
    if (bytes[0] == 0x89 && bytes[1] == 0x50) return true;
    if (bytes[0] == 0x47 && bytes[1] == 0x49) return true;
    if (bytes[0] == 0x42 && bytes[1] == 0x4D) return true;
    return false;
  }

  static String? _scanHtml(Uint8List bytes) {
    final text = latin1.decode(bytes, allowInvalid: true);
    final start = text.toLowerCase().indexOf('<html');
    if (start < 0) return null;
    final end = text.toLowerCase().lastIndexOf('</html>');
    final slice = end > start ? text.substring(start, end + 7) : text.substring(start);
    if (slice.length < 40) return null;
    return slice;
  }

  static String? _exthTitle(Uint8List header, int codepage) {
    final marker = latin1.decode(header, allowInvalid: true).indexOf('EXTH');
    if (marker < 0 || marker + 12 > header.length) return null;
    final view = ByteData.sublistView(header);
    final count = view.getUint32(marker + 8);
    var pos = marker + 12;
    for (var i = 0; i < count; i++) {
      if (pos + 8 > header.length) return null;
      final type = view.getUint32(pos);
      final length = view.getUint32(pos + 4);
      if (length < 8 || pos + length > header.length) return null;
      if (type == 503) {
        return _decode(header.sublist(pos + 8, pos + length), codepage).replaceAll('\u0000', '').trim();
      }
      pos += length;
    }
    return null;
  }

  static List<Uint8List> _palmRecords(Uint8List bytes) {
    if (bytes.length < 78) {
      throw BookOpenException('This is not a Kindle book.');
    }
    final view = ByteData.sublistView(bytes);
    final count = view.getUint16(76);
    if (count <= 0 || 78 + count * 8 > bytes.length) {
      throw BookOpenException('This Kindle file is damaged.');
    }
    final offsets = <int>[];
    for (var i = 0; i < count; i++) {
      offsets.add(view.getUint32(78 + i * 8));
    }
    final records = <Uint8List>[];
    for (var i = 0; i < count; i++) {
      final start = offsets[i];
      final end = i + 1 < count ? offsets[i + 1] : bytes.length;
      if (start < 0 || end < start || end > bytes.length) {
        throw BookOpenException('This Kindle file is damaged.');
      }
      records.add(Uint8List.sublistView(bytes, start, end));
    }
    return records;
  }

  static Uint8List _trimTrailers(Uint8List data, int trailers, bool multibyte) {
    var end = data.length;
    for (var i = 0; i < trailers; i++) {
      if (end <= 0) break;
      final size = _trailingSize(data, end);
      if (size <= 0 || size > end) break;
      end -= size;
    }
    if (multibyte && end > 0) {
      final size = (data[end - 1] & 3) + 1;
      if (size <= end) end -= size;
    }
    if (end == data.length) return data;
    return Uint8List.sublistView(data, 0, end);
  }

  static int _trailingSize(Uint8List data, int end) {
    var num = 0;
    final start = math.max(0, end - 4);
    for (var i = start; i < end; i++) {
      final v = data[i];
      if (v & 0x80 != 0) num = 0;
      num = (num << 7) | (v & 0x7f);
    }
    return num;
  }

  static String _ascii(Uint8List bytes, int offset, int length) {
    if (offset + length > bytes.length) return '';
    return String.fromCharCodes(bytes.sublist(offset, offset + length));
  }

  static String _decode(Uint8List bytes, int codepage) {
    if (codepage == 65001) return utf8.decode(bytes, allowMalformed: true);
    return latin1.decode(bytes, allowInvalid: true);
  }
}

/// PalmDOC / Mobipocket LZ77. Exposed for tests.
Uint8List decompressPalmDoc(Uint8List input) {
  final out = <int>[];
  var i = 0;
  while (i < input.length) {
    final c = input[i++];
    if (c == 0 || (c >= 0x09 && c <= 0x7f)) {
      out.add(c);
    } else if (c <= 8) {
      final n = math.min(c, input.length - i);
      out.addAll(input.sublist(i, i + n));
      i += n;
    } else if (c <= 0xbf) {
      if (i >= input.length) break;
      final next = input[i++];
      final distance = (((c << 8) | next) >> 3) & 0x7ff;
      final length = (next & 7) + 3;
      if (distance <= 0 || distance > out.length) continue;
      for (var n = 0; n < length; n++) {
        out.add(out[out.length - distance]);
      }
    } else {
      out.add(0x20);
      out.add(c ^ 0x80);
    }
  }
  return Uint8List.fromList(out);
}

import 'dart:typed_data';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

class BookOpenException implements Exception {
  BookOpenException(this.message);
  final String message;

  @override
  String toString() => message;
}

class TextRun {
  const TextRun(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.heading = 0,
  });

  final String text;
  final bool bold;
  final bool italic;
  final int heading;
}

class BookBlock {
  const BookBlock.text(this.runs) : bytes = null;
  const BookBlock.image(Uint8List this.bytes) : runs = null;

  final List<TextRun>? runs;
  final Uint8List? bytes;

  bool get isImage => bytes != null;
}

class BookChapter {
  BookChapter({required this.title, required this.blocks});

  final String title;
  final List<BookBlock> blocks;
}

class LoadedBook {
  LoadedBook({required this.title, required this.chapters});

  final String title;
  final List<BookChapter> chapters;
}

typedef ImageLookup = Uint8List? Function(String src);

List<BookChapter> htmlToChapters(
  String source, {
  String fallbackTitle = 'Book',
  ImageLookup? images,
}) {
  final document = html_parser.parse(source);
  final body = document.body;
  if (body == null) {
    final plain = source.trim();
    if (plain.isEmpty) return [];
    return [
      BookChapter(
        title: fallbackTitle,
        blocks: [BookBlock.text([TextRun(plain)])],
      ),
    ];
  }

  final builders = <_ChapterBuilder>[];

  void ensure([String? title]) {
    if (builders.isEmpty) {
      builders.add(_ChapterBuilder(title ?? fallbackTitle));
    }
  }

  void startChapter(String title) {
    if (builders.isNotEmpty && builders.last.isEmpty) {
      if (title.trim().isNotEmpty) builders.last.title = title.trim();
      return;
    }
    builders.add(_ChapterBuilder(title.trim().isEmpty ? 'Section ${builders.length + 1}' : title.trim()));
  }

  void walk(Node node, _Style style) {
    if (node is Text) {
      ensure();
      builders.last.addText(node.text, style);
      return;
    }
    if (node is! Element) return;
    final name = node.localName?.toLowerCase() ?? '';
    if (name == 'script' || name == 'style' || name == 'head' || name == 'svg') return;

    if (name == 'h1' || name == 'h2' || name == 'pagebreak') {
      final title = name == 'pagebreak' ? '' : _elementText(node);
      startChapter(title.isEmpty ? 'Section ${builders.length + 1}' : title);
      if (name.startsWith('h')) {
        builders.last.addText(title, style.copy(heading: name == 'h1' ? 1 : 2, bold: true));
        builders.last.flush();
      }
      return;
    }

    if (name == 'img' || name == 'image') {
      ensure();
      final src = node.attributes['src'] ??
          node.attributes['recindex'] ??
          node.attributes['href'] ??
          _attrEnding(node, 'href') ??
          '';
      final bytes = images?.call(src);
      if (bytes != null && bytes.isNotEmpty) {
        builders.last.flush();
        builders.last.blocks.add(BookBlock.image(bytes));
      }
      return;
    }

    if (name == 'br') {
      ensure();
      builders.last.breakLine();
      return;
    }

    final next = style.apply(name);
    for (final child in node.nodes) {
      walk(child, next);
    }
    if (_isBlock(name)) {
      ensure();
      builders.last.flush();
    }
  }

  walk(body, const _Style());
  final chapters = builders.map((b) => b.build()).where((c) => c.blocks.isNotEmpty).toList();
  if (chapters.isEmpty) return [];
  if (chapters.length == 1 && (chapters.first.title.isEmpty || chapters.first.title.startsWith('Section'))) {
    return [BookChapter(title: fallbackTitle, blocks: chapters.first.blocks)];
  }
  return chapters;
}

String _elementText(Element element) => element.text.replaceAll(RegExp(r'\s+'), ' ').trim();

String? _attrEnding(Element element, String suffix) {
  for (final entry in element.attributes.entries) {
    if (entry.key.toString().toLowerCase().endsWith(suffix) && entry.value.isNotEmpty) {
      return entry.value;
    }
  }
  return null;
}

bool _isBlock(String name) {
  switch (name) {
    case 'p':
    case 'div':
    case 'li':
    case 'tr':
    case 'blockquote':
    case 'h3':
    case 'h4':
    case 'h5':
    case 'h6':
    case 'section':
    case 'article':
      return true;
    default:
      return false;
  }
}

class _Style {
  const _Style({this.bold = false, this.italic = false, this.heading = 0});

  final bool bold;
  final bool italic;
  final int heading;

  _Style apply(String name) {
    final b = bold || name == 'b' || name == 'strong' || name.startsWith('h');
    final i = italic || name == 'i' || name == 'em';
    final h = name == 'h1'
        ? 1
        : name == 'h2'
            ? 2
            : name == 'h3'
                ? 3
                : heading;
    if (b == bold && i == italic && h == heading) return this;
    return _Style(bold: b, italic: i, heading: h);
  }

  _Style copy({bool? bold, bool? italic, int? heading}) => _Style(
        bold: bold ?? this.bold,
        italic: italic ?? this.italic,
        heading: heading ?? this.heading,
      );
}

class _ChapterBuilder {
  _ChapterBuilder(this.title);

  String title;
  final blocks = <BookBlock>[];
  final _runs = <TextRun>[];
  var _pendingSpace = false;

  bool get isEmpty => blocks.isEmpty && _runs.isEmpty;

  void addText(String raw, _Style style) {
    final text = raw.replaceAll(RegExp(r'\s+'), ' ');
    if (text.trim().isEmpty) {
      if (_runs.isNotEmpty) _pendingSpace = true;
      return;
    }
    final needsSpace = _pendingSpace || (_runs.isNotEmpty && !_runs.last.text.endsWith(' ') && !text.startsWith(' '));
    _pendingSpace = false;
    final value = '${needsSpace ? ' ' : ''}${text.trim()}';
    if (value.trim().isEmpty) return;
    _runs.add(TextRun(value, bold: style.bold, italic: style.italic, heading: style.heading));
  }

  void breakLine() {
    if (_runs.isEmpty) return;
    _runs.add(const TextRun('\n'));
  }

  void flush() {
    if (_runs.isEmpty) return;
    final text = _runs.map((r) => r.text).join();
    if (text.trim().isEmpty) {
      _runs.clear();
      _pendingSpace = false;
      return;
    }
    blocks.add(BookBlock.text(List<TextRun>.from(_runs)));
    _runs.clear();
    _pendingSpace = false;
  }

  BookChapter build() {
    flush();
    return BookChapter(title: title, blocks: blocks);
  }
}

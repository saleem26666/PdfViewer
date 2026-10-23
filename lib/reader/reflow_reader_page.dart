import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../books/book_content.dart';
import '../books/book_kind.dart';
import '../books/book_loader.dart';
import '../books/urdu_translate.dart';
import 'convert_book.dart';
import 'urdu_book.dart';

class ReflowReaderPage extends StatefulWidget {
  const ReflowReaderPage({super.key, required this.path});

  final String path;

  @override
  State<ReflowReaderPage> createState() => _ReflowReaderPageState();
}

class _ReflowReaderPageState extends State<ReflowReaderPage> {
  final _scroll = ScrollController();
  LoadedBook? _book;
  String? _error;
  int _chapter = 0;
  double _font = 19;
  bool _night = false;
  bool _urdu = false;
  final Map<int, Offset> _pointers = {};
  double _pinchDist = 0;
  double _pinchFont = 19;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _font = prefs.getDouble('ebook_font') ?? 19;
      _night = prefs.getBool('ebook_night') ?? false;
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('ebook_font', _font);
    await prefs.setBool('ebook_night', _night);
  }

  Future<void> _load() async {
    try {
      final bytes = await File(widget.path).readAsBytes();
      final kind = await BookKindDetect.resolve(widget.path);
      final book = await BookLoader.load(widget.path, kind, bytes);
      if (!mounted) return;
      setState(() {
        _book = book;
        _error = null;
        _urdu = isMostlyArabicScript(bookSample(book));
      });
    } on BookOpenException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not open this book.\n$e');
    }
  }

  void _setFont(double value) {
    final next = value.clamp(13.0, 42.0);
    if ((next - _font).abs() < 0.4) return;
    final fraction = !_scroll.hasClients || _scroll.position.maxScrollExtent <= 0
        ? 0.0
        : _scroll.offset / _scroll.position.maxScrollExtent;
    setState(() => _font = next);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      _scroll.jumpTo((fraction * max).clamp(0, max));
    });
  }

  void _pointerDown(PointerDownEvent event) {
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length == 2) {
      final pts = _pointers.values.toList();
      _pinchDist = math.max(8, (pts[0] - pts[1]).distance);
      _pinchFont = _font;
    }
  }

  void _pointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length < 2 || _pinchDist < 8) return;
    final pts = _pointers.values.take(2).toList();
    final dist = math.max(8, (pts[0] - pts[1]).distance);
    _setFont(_pinchFont * dist / _pinchDist);
  }

  void _pointerUp(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.length < 2) _pinchDist = 0;
  }

  Future<void> _translate(BuildContext context) async {
    final saved = await translateBookFile(context, widget.path);
    if (saved == null || !context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReflowReaderPage(path: saved)));
  }

  void _goChapter(int index) {
    final book = _book;
    if (book == null || index < 0 || index >= book.chapters.length) return;
    setState(() => _chapter = index);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final book = _book;
    final bg = _night ? const Color(0xFF121212) : const Color(0xFFF7F3EA);
    final fg = _night ? const Color(0xFFE8E6E3) : const Color(0xFF1D1B19);
    final title = book?.title ?? p.basename(widget.path);
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'To Urdu',
            onPressed: () => _translate(context),
            icon: const Icon(Icons.translate),
          ),
          IconButton(
            tooltip: 'Convert',
            onPressed: () => convertBookFile(context, widget.path),
            icon: const Icon(Icons.swap_horiz),
          ),
          IconButton(
            tooltip: 'Smaller text',
            onPressed: () {
              _setFont(_font - 1);
              _savePrefs();
            },
            icon: const Icon(Icons.text_decrease),
          ),
          IconButton(
            tooltip: 'Larger text',
            onPressed: () {
              _setFont(_font + 1);
              _savePrefs();
            },
            icon: const Icon(Icons.text_increase),
          ),
          IconButton(
            tooltip: _night ? 'Day' : 'Night',
            onPressed: () {
              setState(() => _night = !_night);
              _savePrefs();
            },
            icon: Icon(_night ? Icons.light_mode : Icons.dark_mode_outlined),
          ),
          if (book != null && book.chapters.length > 1)
            IconButton(
              tooltip: 'Chapters',
              onPressed: () => _openChapters(book),
              icon: const Icon(Icons.list),
            ),
        ],
      ),
      body: book == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error!, textAlign: TextAlign.center),
                    ),
            )
          : Column(
              children: [
                Expanded(
                  child: Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: _pointerDown,
                    onPointerMove: _pointerMove,
                    onPointerUp: _pointerUp,
                    onPointerCancel: _pointerUp,
                    child: _chapterView(book.chapters[_chapter], fg),
                  ),
                ),
                if (book.chapters.length > 1)
                  SafeArea(
                    top: false,
                    child: Material(
                      elevation: 6,
                      color: Theme.of(context).colorScheme.surface,
                      child: Row(
                        children: [
                          IconButton(
                            onPressed: _chapter == 0 ? null : () => _goChapter(_chapter - 1),
                            icon: const Icon(Icons.chevron_left),
                          ),
                          Expanded(
                            child: Text(
                              book.chapters[_chapter].title,
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          IconButton(
                            onPressed: _chapter >= book.chapters.length - 1 ? null : () => _goChapter(_chapter + 1),
                            icon: const Icon(Icons.chevron_right),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _chapterView(BookChapter chapter, Color fg) {
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 32),
      itemCount: chapter.blocks.length,
      itemBuilder: (context, index) {
        final block = chapter.blocks[index];
        if (block.isImage) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Image.memory(block.bytes!, fit: BoxFit.contain),
          );
        }
        final runs = block.runs ?? const <TextRun>[];
        final heading = runs.fold<int>(0, (max, run) => math.max(max, run.heading));
        final rtl = _urdu || isMostlyArabicScript(runs.map((run) => run.text).join());
        return Padding(
          padding: EdgeInsets.only(bottom: heading > 0 ? 14 : 12),
          child: Text.rich(
            TextSpan(
              children: [
                for (final run in runs)
                  TextSpan(
                    text: run.text,
                    style: TextStyle(
                      color: fg,
                      fontFamily: rtl ? 'Nastaliq' : null,
                      fontSize: heading > 0 ? _font + 4 : _font,
                      height: rtl ? 2.15 : 1.5,
                      fontWeight: run.bold || run.heading > 0 ? FontWeight.w700 : FontWeight.w400,
                      fontStyle: run.italic ? FontStyle.italic : FontStyle.normal,
                    ),
                  ),
              ],
            ),
            textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
            textAlign: rtl ? (heading > 0 ? TextAlign.right : TextAlign.justify) : TextAlign.start,
          ),
        );
      },
    );
  }

  Future<void> _openChapters(LoadedBook book) async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => ListView.builder(
        itemCount: book.chapters.length,
        itemBuilder: (context, index) => ListTile(
          selected: index == _chapter,
          title: Text(book.chapters[index].title, maxLines: 2, overflow: TextOverflow.ellipsis),
          onTap: () => Navigator.pop(context, index),
        ),
      ),
    );
    if (picked != null) _goChapter(picked);
  }
}

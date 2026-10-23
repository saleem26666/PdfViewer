import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../books/book_content.dart';
import '../books/book_kind.dart';
import 'convert_book.dart';
import 'reflow_reader_page.dart';
import 'stable_zoom.dart';
import 'urdu_book.dart';

class ComicReaderPage extends StatefulWidget {
  const ComicReaderPage({super.key, required this.path});

  final String path;

  @override
  State<ComicReaderPage> createState() => _ComicReaderPageState();
}

class _ComicReaderPageState extends State<ComicReaderPage> {
  final _page = PageController();
  List<_ComicPage> _pages = const [];
  String? _error;
  int _index = 0;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final bytes = await File(widget.path).readAsBytes();
      final pages = _readPages(bytes, widget.path);
      if (pages.isEmpty) {
        throw BookOpenException('No pictures were found in this file.');
      }
      if (!mounted) return;
      setState(() => _pages = pages);
    } on BookOpenException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not open this comic.\n$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(p.basename(widget.path), maxLines: 1, overflow: TextOverflow.ellipsis),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'To Urdu',
            onPressed: () async {
              final saved = await translateBookFile(context, widget.path);
              if (saved == null || !context.mounted) return;
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReflowReaderPage(path: saved)));
            },
            icon: const Icon(Icons.translate),
          ),
          IconButton(
            tooltip: 'Convert',
            onPressed: () => convertBookFile(context, widget.path),
            icon: const Icon(Icons.swap_horiz),
          ),
        ],
      ),
      body: _pages.isEmpty
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
                    ),
            )
          : Column(
              children: [
                Expanded(
                  child: PageView.builder(
                    controller: _page,
                    physics: _zoomed ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
                    itemCount: _pages.length,
                    onPageChanged: (index) => setState(() => _index = index),
                    itemBuilder: (context, index) {
                      return StableZoom(
                        onScaleChanged: (scale) {
                          final zoomed = scale > 1.05;
                          if (zoomed != _zoomed && index == _index) {
                            setState(() => _zoomed = zoomed);
                          }
                        },
                        child: Image.memory(
                          _pages[index].bytes,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                        ),
                      );
                    },
                  ),
                ),
                SafeArea(
                  top: false,
                  child: ColoredBox(
                    color: const Color(0xFF1A1A1A),
                    child: Row(
                      children: [
                        IconButton(
                          color: Colors.white,
                          onPressed: _index == 0
                              ? null
                              : () => _page.previousPage(
                                    duration: const Duration(milliseconds: 200),
                                    curve: Curves.easeOut,
                                  ),
                          icon: const Icon(Icons.chevron_left),
                        ),
                        Expanded(
                          child: Text(
                            '${_index + 1} / ${_pages.length}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                          ),
                        ),
                        IconButton(
                          color: Colors.white,
                          onPressed: _index >= _pages.length - 1
                              ? null
                              : () => _page.nextPage(
                                    duration: const Duration(milliseconds: 200),
                                    curve: Curves.easeOut,
                                  ),
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
}

class _ComicPage {
  _ComicPage(this.bytes);
  final Uint8List bytes;
}

List<_ComicPage> _readPages(Uint8List bytes, String path) {
  final Archive archive;
  final lower = path.toLowerCase();
  try {
    if (lower.endsWith('.cbt') || lower.endsWith('.tar')) {
      archive = TarDecoder().decodeBytes(bytes);
    } else {
      archive = ZipDecoder().decodeBytes(bytes);
    }
  } catch (_) {
    throw BookOpenException('This comic archive could not be read.');
  }
  final files = archive.files.where((f) => f.isFile && BookKindDetect.isImageName(f.name)).toList();
  files.sort((a, b) => _natural(a.name, b.name));
  return [for (final file in files) _ComicPage(file.content)];
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

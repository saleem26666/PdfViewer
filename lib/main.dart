import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'books/book_kind.dart';
import 'reader/comic_reader_page.dart';
import 'reader/convert_book.dart';
import 'reader/pdf_reader_page.dart';
import 'reader/reflow_reader_page.dart';
import 'reader/urdu_book.dart';

const _openChannel = MethodChannel('pdf_reader/open');

const _bookExtensions = [
  'pdf',
  'epub',
  'mobi',
  'azw',
  'azw3',
  'azw4',
  'prc',
  'kf8',
  'fb2',
  'txt',
  'text',
  'md',
  'markdown',
  'html',
  'htm',
  'xhtml',
  'rtf',
  'docx',
  'cbz',
  'cbt',
  'zip',
];

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PdfReaderApp());
}

class PdfReaderApp extends StatelessWidget {
  const PdfReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ebook Reader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFB71C1C),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(centerTitle: false),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFEF9A9A),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _recentsKey = 'recent_book_paths';
  static const _legacyRecentsKey = 'recent_pdf_paths';
  final List<String> _recents = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadRecents();
    _listenOpenIntents();
  }

  Future<void> _listenOpenIntents() async {
    _openChannel.setMethodCallHandler((call) async {
      if (call.method == 'onOpenPath') {
        final path = call.arguments as String?;
        if (path != null && path.isNotEmpty) {
          await _openPath(path);
        }
      }
      return null;
    });
    try {
      final path = await _openChannel.invokeMethod<String>('getInitialPath');
      if (path != null && path.isNotEmpty) {
        await _openPath(path);
      }
    } catch (_) {}
  }

  Future<void> _loadRecents() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_recentsKey);
    final legacy = prefs.getStringList(_legacyRecentsKey) ?? [];
    final list = stored ?? legacy;
    final existing = list.where((path) => File(path).existsSync()).toList();
    if (stored == null || existing.length != list.length) {
      await prefs.setStringList(_recentsKey, existing);
    }
    if (mounted) {
      setState(() {
        _recents
          ..clear()
          ..addAll(existing);
      });
    }
  }

  Future<void> _remember(String path) async {
    final prefs = await SharedPreferences.getInstance();
    final next = [path, ..._recents.where((e) => e != path)].take(20).toList();
    await prefs.setStringList(_recentsKey, next);
    if (mounted) {
      setState(() {
        _recents
          ..clear()
          ..addAll(next);
      });
    }
  }

  Future<String?> _pickPath() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: _bookExtensions,
      withData: false,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.single;
    final path = file.path;
    if (path != null && path.isNotEmpty) return path;
    if (file.bytes == null) {
      _toast('Could not read this file');
      return null;
    }
    return _writeTempBytes(file.name, file.bytes!);
  }

  Future<void> _pickBook() async {
    setState(() => _busy = true);
    try {
      final path = await _pickPath();
      if (path != null) await _openPath(path);
    } catch (e) {
      _toast('Open failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _translatePath(String path) async {
    final saved = await translateBookFile(context, path);
    if (saved == null || !mounted) return;
    await _remember(saved);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReflowReaderPage(path: saved)));
  }

  Future<void> _pickAndTranslate() async {
    setState(() => _busy = true);
    try {
      final path = await _pickPath();
      if (!mounted) return;
      setState(() => _busy = false);
      if (path != null) await _translatePath(path);
    } catch (e) {
      _toast('Translate failed: $e');
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickAndConvert() async {
    setState(() => _busy = true);
    try {
      final path = await _pickPath();
      if (!mounted) return;
      setState(() => _busy = false);
      if (path != null) await convertBookFile(context, path);
    } catch (e) {
      _toast('Convert failed: $e');
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String> _writeTempBytes(String name, List<int> bytes) async {
    final dir = await getTemporaryDirectory();
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final out = File(
      p.join(dir.path, 'open_${DateTime.now().millisecondsSinceEpoch}_$safe'),
    );
    await out.writeAsBytes(bytes, flush: true);
    return out.path;
  }

  Future<void> _openPath(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      _toast('File not found');
      return;
    }
    final kind = await BookKindDetect.resolve(path);
    if (kind == BookKind.unsupported) {
      _toast('Can’t open this file. Try PDF, EPUB, MOBI, AZW, FB2, TXT, HTML, RTF, DOCX, or CBZ.');
      return;
    }
    await _remember(path);
    if (!mounted) return;
    final page = switch (kind) {
      BookKind.pdf => PdfReaderPage(path: path),
      BookKind.comic => ComicReaderPage(path: path),
      _ => ReflowReaderPage(path: path),
    };
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _clearRecents() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_recentsKey);
    if (mounted) setState(_recents.clear);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ebook Reader'),
        actions: [
          IconButton(
            tooltip: 'Gemini key',
            onPressed: () => ensureGeminiKey(context, force: true),
            icon: const Icon(Icons.key),
          ),
          if (_recents.isNotEmpty)
            IconButton(
              tooltip: 'Clear recent',
              onPressed: _clearRecents,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [
          Card(
            elevation: 0,
            color: cs.primaryContainer.withValues(alpha: 0.45),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Personal ebook reader',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Opens PDF, EPUB, Kindle (MOBI, AZW, AZW3), FB2, TXT, HTML, RTF, DOCX, and CBZ comics.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                          height: 1.35,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Convert a book to EPUB, MOBI, AZW, FB2, PDF, HTML, TXT, Markdown, RTF, DOCX, or CBZ. To Urdu uses Gemini to rewrite it as fluent Pakistani Urdu.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                          height: 1.35,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Pinch with two fingers to zoom a PDF. Drag with one finger to move left, right, up, or down — the zoom stays. Pinch again to zoom out. Double-tap to zoom in, and double-tap again to fit the page.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                          height: 1.35,
                        ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: _busy ? null : _pickBook,
                        icon: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.folder_open),
                        label: Text(_busy ? 'Please wait…' : 'Open book'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _pickAndConvert,
                        icon: const Icon(Icons.swap_horiz),
                        label: const Text('Convert'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _pickAndTranslate,
                        icon: const Icon(Icons.translate),
                        label: const Text('To Urdu'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Recent',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 8),
          if (_recents.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'No recent books yet.\nOpen a file, or share / Open with from Files.',
                textAlign: TextAlign.center,
                style: TextStyle(color: cs.onSurfaceVariant, height: 1.4),
              ),
            )
          else
            ..._recents.map((path) {
              final name = p.basename(path);
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Icon(_iconFor(path), color: cs.primary),
                  title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                  onTap: () => _openPath(path),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'To Urdu',
                        onPressed: () => _translatePath(path),
                        icon: const Icon(Icons.translate),
                      ),
                      IconButton(
                        tooltip: 'Convert',
                        onPressed: () => convertBookFile(context, path),
                        icon: const Icon(Icons.swap_horiz),
                      ),
                    ],
                  ),
                ),
              );
            }),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _pickBook,
        icon: const Icon(Icons.add),
        label: const Text('Open book'),
      ),
    );
  }

  IconData _iconFor(String path) {
    switch (BookKindDetect.fromPath(path)) {
      case BookKind.pdf:
        return Icons.picture_as_pdf;
      case BookKind.epub:
      case BookKind.mobi:
      case BookKind.fb2:
        return Icons.menu_book;
      case BookKind.comic:
        return Icons.photo_library_outlined;
      case BookKind.text:
      case BookKind.html:
      case BookKind.rtf:
      case BookKind.docx:
        return Icons.article_outlined;
      case BookKind.unsupported:
        return Icons.insert_drive_file_outlined;
    }
  }
}

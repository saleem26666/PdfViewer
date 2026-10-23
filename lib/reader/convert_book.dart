import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../books/book_content.dart';
import '../books/book_export.dart';

Future<void> convertBookFile(BuildContext context, String sourcePath) async {
  final format = await showModalBottomSheet<ExportFormat>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text('Convert to', style: Theme.of(context).textTheme.titleLarge),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final format in ExportFormat.values)
                    ListTile(
                      title: Text(format.label),
                      subtitle: Text(_hint(format)),
                      onTap: () => Navigator.pop(context, format),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
  if (format == null || !context.mounted) return;

  final status = ValueNotifier<String>('Reading the book…');
  final dialog = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) {
      return PopScope(
        canPop: false,
        child: AlertDialog(
          content: ValueListenableBuilder<String>(
            valueListenable: status,
            builder: (context, value, _) {
              return Row(
                children: [
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                  const SizedBox(width: 16),
                  Expanded(child: Text(value)),
                ],
              );
            },
          ),
        ),
      );
    },
  );
  await Future<void>.delayed(Duration.zero);

  var closed = false;
  void closeDialog() {
    if (closed || !context.mounted) return;
    closed = true;
    Navigator.of(context, rootNavigator: true).pop();
  }

  try {
    final book = await loadBookForExport(
      sourcePath,
      onStatus: (value) => status.value = value,
    );
    if (!context.mounted) return;
    status.value = 'Writing ${format.label}…';
    await Future<void>.delayed(Duration.zero);
    final bytes = await exportBook(book, format);
    closeDialog();
    await dialog;
    if (!context.mounted) return;

    final base = p.basenameWithoutExtension(sourcePath).trim();
    final fileName = '${base.isEmpty ? 'book' : base}.${format.extension}';
    final saved = await _saveConvertedFile(fileName, bytes, format);
    if (!context.mounted || saved == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(saved)),
    );
  } on BookOpenException catch (e) {
    closeDialog();
    await dialog;
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
  } catch (_) {
    closeDialog();
    await dialog;
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not convert this book.')),
    );
  } finally {
    status.dispose();
  }
}

Future<String?> _saveConvertedFile(String fileName, Uint8List bytes, ExportFormat format) async {
  try {
    final picked = await FilePicker.platform.saveFile(
      dialogTitle: 'Save ${format.label}',
      fileName: fileName,
      type: FileType.any,
      bytes: bytes,
    );
    if (picked == null) return null;
    return 'Saved $fileName';
  } catch (_) {
    final path = await _writeConvertedFile(fileName, bytes);
    return 'Saved $fileName\n$path';
  }
}

Future<String> _writeConvertedFile(String fileName, Uint8List bytes) async {
  final safe = fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  final folders = <Directory?>[
    await _directory(getDownloadsDirectory),
    await _directory(getExternalStorageDirectory),
    await _directory(getApplicationDocumentsDirectory),
  ];
  Object? lastError;
  for (final folder in folders) {
    if (folder == null) continue;
    try {
      final out = File(p.join(folder.path, safe));
      await out.parent.create(recursive: true);
      await out.writeAsBytes(bytes, flush: true);
      return out.path;
    } catch (e) {
      lastError = e;
    }
  }
  throw lastError ?? Exception('Could not save the file.');
}

Future<Directory?> _directory(Future<Directory?> Function() load) async {
  try {
    return await load();
  } catch (_) {
    return null;
  }
}

String _hint(ExportFormat format) {
  switch (format) {
    case ExportFormat.mobi:
    case ExportFormat.azw:
    case ExportFormat.azw3:
      return 'Kindle MOBI-compatible';
    case ExportFormat.cbz:
      return 'Pictures only';
    case ExportFormat.epub:
      return 'Reflowable book';
    case ExportFormat.pdf:
      return 'Fixed pages';
    case ExportFormat.txt:
    case ExportFormat.markdown:
    case ExportFormat.rtf:
    case ExportFormat.docx:
      return 'Text, pictures marked as [Picture]';
    case ExportFormat.fb2:
    case ExportFormat.html:
      return 'Text and pictures';
  }
}

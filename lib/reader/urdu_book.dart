import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../books/book_content.dart';
import '../books/book_export.dart';
import '../books/urdu_translate.dart';

const geminiKeyPref = 'gemini_api_key';

/// Asks for the Gemini key when it has not been saved yet.
Future<String?> ensureGeminiKey(BuildContext context, {bool force = false}) async {
  final prefs = await SharedPreferences.getInstance();
  final existing = prefs.getString(geminiKeyPref)?.trim() ?? '';
  if (existing.isNotEmpty && !force) return existing;
  if (!context.mounted) return null;

  final controller = TextEditingController(text: existing);
  final key = await showDialog<String>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('Gemini API key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Paste the same Gemini key you use for YouTube translation. The book is rewritten as fluent Pakistani Urdu.',
            ),
            const SizedBox(height: 8),
            const Text('Get a key at aistudio.google.com/apikey'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'API key',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      );
    },
  );
  controller.dispose();
  if (key == null) return existing.isEmpty ? null : existing;
  if (key.isEmpty) {
    await prefs.remove(geminiKeyPref);
    return null;
  }
  await prefs.setString(geminiKeyPref, key);
  return key;
}

/// Translates [sourcePath] into fluent Urdu with Gemini and saves an EPUB.
Future<String?> translateBookFile(BuildContext context, String sourcePath) async {
  final apiKey = await ensureGeminiKey(context);
  if (apiKey == null || apiKey.isEmpty || !context.mounted) return null;

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
    final book = await loadBookForExport(sourcePath, onStatus: (value) => status.value = value);
    if (!context.mounted) {
      closeDialog();
      return null;
    }
    final translated = await translateBookToUrdu(
      book,
      (prompt) => geminiGenerate(apiKey, prompt, onStatus: (value) => status.value = value),
      onStatus: (value) => status.value = value,
    );
    status.value = 'Saving the Urdu book…';
    final bytes = await exportBook(translated, ExportFormat.epub);
    final path = await _writeUrduEpub(translated.title, bytes);
    closeDialog();
    await dialog;
    return path;
  } on BookOpenException catch (e) {
    closeDialog();
    await dialog;
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
    return null;
  } catch (e) {
    closeDialog();
    await dialog;
    if (context.mounted) {
      final detail = e.toString().split('\n').first;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(detail.isEmpty ? 'Could not translate this book.' : detail)),
      );
    }
    return null;
  } finally {
    status.dispose();
  }
}

Future<String> geminiGenerate(
  String apiKey,
  String prompt, {
  void Function(String status)? onStatus,
}) async {
  const models = [
    'gemini-3.8-flash',
    'gemini-3.5-flash',
    'gemini-2.5-flash',
    'gemini-2.0-flash',
  ];
  Object? lastError;
  for (final model in models) {
    for (var attempt = 1; attempt <= 4; attempt++) {
      try {
        return await _geminiOnce(apiKey, model, prompt);
      } on BookOpenException catch (e) {
        final low = e.message.toLowerCase();
        if (_isBusy(low) || _isMissingModel(low)) {
          lastError = e;
          if (_isBusy(low) && attempt < 4) {
            onStatus?.call('Gemini is busy. Waiting ${attempt * 8} seconds…');
            await Future<void>.delayed(Duration(seconds: attempt * 8));
            continue;
          }
          if (_isMissingModel(low) || _isBusy(low)) break;
        }
        rethrow;
      } catch (e) {
        lastError = e;
        final msg = e.toString().toLowerCase();
        if (_isMissingModel(msg) || _isBusy(msg)) {
          if (_isBusy(msg) && attempt < 4) {
            onStatus?.call('Gemini is busy. Waiting ${attempt * 8} seconds…');
            await Future<void>.delayed(Duration(seconds: attempt * 8));
            continue;
          }
          break;
        }
        rethrow;
      }
    }
  }
  final detail = lastError?.toString() ?? '';
  if (_isBusy(detail.toLowerCase())) {
    throw BookOpenException(
      'Gemini is busy right now. Wait one or two minutes, then tap To Urdu again.',
    );
  }
  throw BookOpenException('Gemini could not translate this section. $lastError');
}

bool _isBusy(String message) {
  return message.contains('high demand') ||
      message.contains('try again later') ||
      message.contains('resource exhausted') ||
      message.contains('rate limit') ||
      message.contains('quota') ||
      message.contains('too many requests') ||
      message.contains('429') ||
      message.contains('503') ||
      message.contains('unavailable');
}

bool _isMissingModel(String message) {
  return message.contains('not found') ||
      message.contains('unsupported') ||
      message.contains('no longer available') ||
      message.contains('404');
}

Future<String> _geminiOnce(String apiKey, String model, String prompt) async {
  final client = HttpClient();
  try {
    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent',
    ).replace(queryParameters: {'key': apiKey.trim()});
    final request = await client.postUrl(uri);
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': prompt},
            ],
          },
        ],
        'generationConfig': {'temperature': 0.4},
      }),
    );
    final response = await request.close().timeout(const Duration(minutes: 3));
    final body = await response.transform(utf8.decoder).join();
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      decoded = null;
    }
    if (response.statusCode >= 400) {
      final message = _geminiError(decoded) ?? 'Gemini request failed (${response.statusCode}).';
      final low = message.toLowerCase();
      if (response.statusCode == 401 || response.statusCode == 403 || low.contains('api key')) {
        throw BookOpenException('Gemini API key looks invalid. Open Gemini key and paste it again.');
      }
      if (response.statusCode == 429 ||
          response.statusCode == 503 ||
          _isBusy(low) ||
          _isMissingModel(low)) {
        throw Exception(message);
      }
      throw BookOpenException(message);
    }
    final data = decoded;
    if (data is! Map) {
      throw BookOpenException('Gemini returned an unexpected response.');
    }
    final candidates = data['candidates'];
    if (candidates is! List || candidates.isEmpty) {
      throw BookOpenException('Gemini did not return a translation. Try again.');
    }
    final content = candidates.first;
    if (content is! Map) throw BookOpenException('Gemini returned an unexpected response.');
    final parts = content['content'];
    if (parts is! Map) throw BookOpenException('Gemini returned an empty translation.');
    final textParts = parts['parts'];
    if (textParts is! List || textParts.isEmpty) {
      throw BookOpenException('Gemini returned an empty translation.');
    }
    final first = textParts.first;
    if (first is! Map || first['text'] is! String) {
      throw BookOpenException('Gemini returned an empty translation.');
    }
    return (first['text'] as String).trim();
  } on BookOpenException {
    rethrow;
  } on SocketException {
    throw BookOpenException('No internet connection. Gemini needs the internet to translate.');
  } finally {
    client.close(force: true);
  }
}

String? _geminiError(Object? decoded) {
  if (decoded is! Map) return null;
  final error = decoded['error'];
  if (error is! Map) return null;
  final message = error['message'];
  if (message is String && message.trim().isNotEmpty) return message.trim();
  return null;
}

Future<String> _writeUrduEpub(String title, List<int> bytes) async {
  final dir = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'Urdu'));
  await dir.create(recursive: true);
  final cleaned = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  final base = cleaned.isEmpty ? 'Urdu book' : cleaned;
  var file = File(p.join(dir.path, '$base.epub'));
  if (await file.exists()) {
    file = File(p.join(dir.path, '$base ${DateTime.now().millisecondsSinceEpoch}.epub'));
  }
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

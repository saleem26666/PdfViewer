import 'book_content.dart';

const urduLiteraryRules = '''
You are an expert Pakistani Urdu literary translator and editor.

Rules:
1. Write natural, fluent Pakistani Urdu with correct grammar. It must read like a published Urdu book.
2. Do not translate word for word. Do not leave English sentence structure in the Urdu.
3. Keep the meaning accurate.
4. Put the section title on its own line as a Markdown heading: ## title
5. Write the body as normal paragraphs, with a blank line between paragraphs.
6. Keep names of people and places in the form Urdu readers already use.
7. Output only the Urdu translation. No English preface, no notes, no apology.
''';

/// True when most of the letters are in the Arabic/Urdu script.
bool isMostlyArabicScript(String text) {
  var letters = 0;
  var arabic = 0;
  for (final rune in text.runes) {
    if (rune <= 32) continue;
    final isArabic = (rune >= 0x0600 && rune <= 0x06FF) ||
        (rune >= 0x0750 && rune <= 0x077F) ||
        (rune >= 0x08A0 && rune <= 0x08FF) ||
        (rune >= 0xFB50 && rune <= 0xFDFF) ||
        (rune >= 0xFE70 && rune <= 0xFEFF);
    final isLatin = (rune >= 0x41 && rune <= 0x5A) || (rune >= 0x61 && rune <= 0x7A);
    if (!isArabic && !isLatin && rune < 0x80) continue;
    if (isArabic || isLatin || rune > 0x7F) {
      letters++;
      if (isArabic) arabic++;
    }
  }
  return letters >= 12 && arabic / letters >= 0.45;
}

String bookSample(LoadedBook book, {int maxChars = 4000}) {
  final buffer = StringBuffer();
  for (final chapter in book.chapters) {
    for (final block in chapter.blocks) {
      if (block.isImage) continue;
      buffer.writeln((block.runs ?? const <TextRun>[]).map((run) => run.text).join());
      if (buffer.length >= maxChars) return buffer.toString();
    }
  }
  return buffer.toString();
}

int _words(String text) => text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

/// Packs paragraphs into sections small enough for one Gemini request.
List<String> packParagraphs(String text, {int maxWords = 1100}) {
  final paragraphs = text.split(RegExp(r'\n+')).map((part) => part.trim()).where((part) => part.isNotEmpty).toList();
  final chunks = <String>[];
  final current = <String>[];
  var words = 0;

  void flush() {
    if (current.isEmpty) return;
    chunks.add(current.join('\n\n'));
    current.clear();
    words = 0;
  }

  for (final paragraph in paragraphs) {
    final count = _words(paragraph);
    if (count > maxWords) {
      flush();
      final sentences = paragraph.split(RegExp(r'(?<=[\.!\?۔؟])\s+'));
      final bucket = <String>[];
      var bucketWords = 0;
      for (final sentence in sentences) {
        final sentenceWords = _words(sentence);
        if (bucket.isNotEmpty && bucketWords + sentenceWords > maxWords) {
          chunks.add(bucket.join(' '));
          bucket.clear();
          bucketWords = 0;
        }
        bucket.add(sentence);
        bucketWords += sentenceWords;
      }
      if (bucket.isNotEmpty) chunks.add(bucket.join(' '));
      continue;
    }
    if (current.isNotEmpty && words + count > maxWords) flush();
    current.add(paragraph);
    words += count;
  }
  flush();
  return chunks;
}

String sectionPrompt({
  required String chunk,
  required int index,
  required int total,
  String? title,
}) {
  final heading = title == null || title.trim().isEmpty ? '' : 'Section title: ${title.trim()}\n\n';
  return '''
$urduLiteraryRules
This is section $index of $total. Translate only this section.

$heading---
$chunk
---
''';
}

List<BookBlock> blocksFromTranslation(String raw) {
  var text = raw.trim();
  if (text.startsWith('```')) {
    text = text.replaceFirst(RegExp(r'^```[a-zA-Z]*\s*'), '').replaceFirst(RegExp(r'\s*```$'), '').trim();
  }
  final blocks = <BookBlock>[];
  for (final part in text.split(RegExp(r'\n\s*\n'))) {
    final lines = part.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty).toList();
    if (lines.isEmpty) continue;
    final heading = lines.length == 1 ? RegExp(r'^#{1,3}\s+(.+)$').firstMatch(lines.first) : null;
    if (heading != null) {
      final title = heading.group(1)!.trim();
      if (title.isNotEmpty) {
        blocks.add(BookBlock.text([TextRun(title, heading: 1, bold: true)]));
      }
      continue;
    }
    final body = lines.map((line) => line.replaceFirst(RegExp(r'^#{1,3}\s+'), '')).join('\n').trim();
    if (body.isEmpty) continue;
    blocks.add(BookBlock.text([TextRun(body)]));
  }
  return blocks;
}

Future<LoadedBook> translateBookToUrdu(
  LoadedBook book,
  Future<String> Function(String prompt) generate, {
  void Function(String status)? onStatus,
}) async {
  final sample = bookSample(book);
  if (sample.trim().isEmpty) {
    throw BookOpenException('This book has no text to translate.');
  }
  if (isMostlyArabicScript(sample)) {
    throw BookOpenException('This book is already in Urdu.');
  }

  final jobs = <({String title, List<String> chunks, List<BookBlock> images})>[];
  for (final chapter in book.chapters) {
    final text = chapter.blocks
        .where((block) => !block.isImage)
        .map((block) => (block.runs ?? const <TextRun>[]).map((run) => run.text).join().trim())
        .where((part) => part.isNotEmpty)
        .join('\n\n');
    final images = [for (final block in chapter.blocks) if (block.isImage && block.bytes != null) block];
    if (text.isEmpty && images.isEmpty) continue;
    jobs.add((title: chapter.title, chunks: packParagraphs(text), images: images));
  }
  final total = jobs.fold<int>(0, (sum, job) => sum + job.chunks.length);
  if (total == 0) {
    throw BookOpenException('This book has no text to translate.');
  }

  onStatus?.call('Translating the title…');
  final titleUrdu = await _plainLine(
    generate,
    'Translate this book title into natural Pakistani Urdu. Output only the Urdu title.\n\n${book.title}',
  );

  final chapters = <BookChapter>[];
  var done = 0;
  for (final job in jobs) {
    final translated = <BookBlock>[];
    var chapterTitle = job.title;
    for (final chunk in job.chunks) {
      done++;
      onStatus?.call('Writing fluent Urdu… $done of $total');
      await Future<void>.delayed(Duration.zero);
      final prompt = sectionPrompt(
        chunk: chunk,
        index: done,
        total: total,
        title: translated.isEmpty ? job.title : null,
      );
      final raw = (await generate(prompt)).trim();
      if (raw.isEmpty) {
        throw BookOpenException('Gemini returned an empty translation.');
      }
      final blocks = blocksFromTranslation(raw);
      if (blocks.isEmpty) {
        throw BookOpenException('Gemini returned a translation that could not be read.');
      }
      if (translated.isEmpty && blocks.first.runs?.first.heading == 1) {
        chapterTitle = blocks.first.runs!.first.text;
      }
      translated.addAll(blocks);
    }
    translated.addAll(job.images);
    if (translated.isEmpty) continue;
    chapters.add(BookChapter(title: chapterTitle.trim().isEmpty ? job.title : chapterTitle.trim(), blocks: translated));
  }

  if (chapters.isEmpty) {
    throw BookOpenException('This book has no text to translate.');
  }
  return LoadedBook(title: titleUrdu.isEmpty ? book.title : titleUrdu, chapters: chapters);
}

Future<String> _plainLine(Future<String> Function(String prompt) generate, String prompt) async {
  final raw = (await generate(prompt)).trim();
  final line = raw.split('\n').map((part) => part.trim()).firstWhere((part) => part.isNotEmpty, orElse: () => '');
  return line.replaceFirst(RegExp(r'^#{1,3}\s+'), '').replaceAll('*', '').trim();
}

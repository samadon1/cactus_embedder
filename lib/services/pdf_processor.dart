import 'dart:io';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:path/path.dart' as p;

/// Handles PDF text extraction and chunking
class PdfProcessor {
  final int chunkSize;
  final int chunkOverlap;

  PdfProcessor({this.chunkSize = 500, this.chunkOverlap = 50});

  /// Extract text chunks from a PDF file
  Future<List<Map<String, dynamic>>> extractChunks(String pdfPath) async {
    final file = File(pdfPath);
    if (!await file.exists()) {
      throw Exception('PDF file not found: $pdfPath');
    }

    final bytes = await file.readAsBytes();
    final document = PdfDocument(inputBytes: bytes);
    final chunks = <Map<String, dynamic>>[];
    final fileName = p.basename(pdfPath);

    print('📄 Processing PDF: $fileName (${document.pages.count} pages)');

    for (int pageIndex = 0; pageIndex < document.pages.count; pageIndex++) {
      final text = PdfTextExtractor(document)
          .extractText(startPageIndex: pageIndex, endPageIndex: pageIndex);

      if (text.trim().isEmpty) continue;

      final pageChunks = _chunkText(text);

      for (int chunkIndex = 0; chunkIndex < pageChunks.length; chunkIndex++) {
        final chunkText = pageChunks[chunkIndex];
        if (chunkText.trim().isEmpty) continue;

        chunks.add({
          'id': '${p.basenameWithoutExtension(pdfPath)}_p${pageIndex + 1}_c$chunkIndex',
          'text': chunkText,
          'metadata': {
            'source': fileName,
            'source_path': pdfPath,
            'page': pageIndex + 1,
            'total_pages': document.pages.count,
            'chunk_index': chunkIndex,
            'chunks_in_page': pageChunks.length,
          },
        });
      }
    }

    document.dispose();
    print('   → Extracted ${chunks.length} chunks from $fileName');
    return chunks;
  }

  /// Extract chunks from all PDFs in a directory
  Future<List<Map<String, dynamic>>> extractFromDirectory(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      throw Exception('Directory not found: $dirPath');
    }

    final chunks = <Map<String, dynamic>>[];
    final pdfFiles = await dir
        .list()
        .where((f) => f is File && f.path.toLowerCase().endsWith('.pdf'))
        .toList();

    print('📁 Found ${pdfFiles.length} PDF files in directory');

    for (final file in pdfFiles) {
      final fileChunks = await extractChunks(file.path);
      chunks.addAll(fileChunks);
    }

    return chunks;
  }

  /// Chunk text into overlapping segments
  List<String> _chunkText(String text) {
    final chunks = <String>[];
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();

    if (text.length <= chunkSize) {
      chunks.add(text);
      return chunks;
    }

    int start = 0;
    while (start < text.length) {
      int end = start + chunkSize;

      if (end >= text.length) {
        chunks.add(text.substring(start).trim());
        break;
      }

      String chunk = text.substring(start, end);
      
      // Try to break at sentence boundary
      int lastPeriod = chunk.lastIndexOf('. ');
      int lastQuestion = chunk.lastIndexOf('? ');
      int lastExclaim = chunk.lastIndexOf('! ');
      int breakPoint = [lastPeriod, lastQuestion, lastExclaim]
          .where((i) => i > chunkSize * 0.5)
          .fold(-1, (a, b) => a > b ? a : b);

      if (breakPoint > 0) {
        chunk = chunk.substring(0, breakPoint + 1);
        end = start + breakPoint + 1;
      } else {
        int lastSpace = chunk.lastIndexOf(' ');
        if (lastSpace > chunkSize * 0.7) {
          chunk = chunk.substring(0, lastSpace);
          end = start + lastSpace;
        }
      }

      chunks.add(chunk.trim());
      start = end - chunkOverlap;
      if (start < 0) start = 0;
    }

    return chunks;
  }
}

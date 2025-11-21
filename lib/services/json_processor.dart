import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

/// Result of loading a JSON file
class JsonLoadResult {
  final List<Map<String, dynamic>> items;
  final String itemsKey;
  final Map<String, dynamic> metadata;

  JsonLoadResult({
    required this.items,
    required this.itemsKey,
    required this.metadata,
  });
}

/// Handles JSON file loading and processing
class JsonProcessor {
  /// Load items from a JSON file
  Future<JsonLoadResult> loadFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('Input file not found: $filePath');
    }

    final content = await file.readAsString();
    final data = json.decode(content) as Map<String, dynamic>;

    List<Map<String, dynamic>> items;
    String itemsKey;

    if (data.containsKey('qa_pairs')) {
      items = (data['qa_pairs'] as List).cast<Map<String, dynamic>>();
      itemsKey = 'qa_pairs';
    } else if (data.containsKey('items')) {
      items = (data['items'] as List).cast<Map<String, dynamic>>();
      itemsKey = 'items';
    } else if (data.containsKey('chunks')) {
      items = (data['chunks'] as List).cast<Map<String, dynamic>>();
      itemsKey = 'chunks';
    } else {
      throw Exception('Input must contain "items", "qa_pairs", or "chunks" array');
    }

    final metadata = Map<String, dynamic>.from(data)..remove(itemsKey);
    metadata['input_type'] = 'json';
    metadata['source_file'] = filePath;

    return JsonLoadResult(items: items, itemsKey: itemsKey, metadata: metadata);
  }

  /// Get list of JSON files in a directory
  Future<List<File>> getFilesInDirectory(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      throw Exception('Directory not found: $dirPath');
    }

    final files = await dir
        .list()
        .where((f) => f is File && f.path.toLowerCase().endsWith('.json'))
        .map((f) => f as File)
        .toList();

    files.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    return files;
  }

  /// Get output path for a batch file
  String getBatchOutputPath(String inputFilePath, String outputDir) {
    final baseName = p.basenameWithoutExtension(inputFilePath);
    return p.join(outputDir, '${baseName}_with_embeddings.json');
  }

  /// Check if a batch file is already fully processed
  Future<bool> isFileComplete(String outputPath) async {
    final file = File(outputPath);
    if (!await file.exists()) return false;

    try {
      final content = await file.readAsString();
      final data = json.decode(content) as Map<String, dynamic>;
      final metadata = data['_embedder_metadata'] as Map<String, dynamic>?;
      if (metadata == null) return false;

      final totalItems = metadata['total_items'] as int? ?? 0;
      final embeddedCount = metadata['embedded_count'] as int? ?? 0;
      return totalItems > 0 && totalItems == embeddedCount;
    } catch (e) {
      return false;
    }
  }

  /// Load existing embeddings from output file
  Future<Map<String, dynamic>> loadExistingEmbeddings(
    String outputPath,
    String itemsKey,
  ) async {
    final file = File(outputPath);
    final embeddings = <String, dynamic>{};

    if (!await file.exists()) return embeddings;

    try {
      final content = await file.readAsString();
      final data = json.decode(content) as Map<String, dynamic>;
      final items = (data[itemsKey] as List?) ?? [];

      for (final item in items) {
        if (item['embeddings'] != null) {
          embeddings[item['id'].toString()] = item;
        }
      }
    } catch (e) {
      // Ignore errors, start fresh
    }

    return embeddings;
  }

  /// Save output to file
  Future<void> saveOutput(
    String outputPath,
    Map<String, dynamic> metadata,
    String itemsKey,
    List<Map<String, dynamic>> items,
    String model,
    String inputType,
    String textField, {
    int? chunkSize,
    int? chunkOverlap,
  }) async {
    final output = Map<String, dynamic>.from(metadata);
    output[itemsKey] = items;
    output['_embedder_metadata'] = {
      'model': model,
      'text_field': inputType == 'json' ? textField : 'text',
      'input_type': inputType,
      'total_items': items.length,
      'embedded_count': items.where((i) => i['embeddings'] != null).length,
      'generated_at': DateTime.now().toIso8601String(),
      'tool': 'cactus_embedder v1.1.0',
      if (chunkSize != null) 'chunk_size': chunkSize,
      if (chunkOverlap != null) 'chunk_overlap': chunkOverlap,
    };

    final file = File(outputPath);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(output));
  }
}

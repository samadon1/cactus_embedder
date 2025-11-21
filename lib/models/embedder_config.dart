import 'package:args/args.dart';

/// Configuration for the embedder parsed from CLI arguments
class EmbedderConfig {
  final String? inputPath;
  final String? outputPath;
  final String model;
  final String textField;
  final int batchSize;
  final bool resume;
  final String inputType;
  final int chunkSize;
  final int chunkOverlap;
  final bool showHelp;

  const EmbedderConfig({
    this.inputPath,
    this.outputPath,
    this.model = 'qwen3-0.6-embed',
    this.textField = 'question',
    this.batchSize = 100,
    this.resume = true,
    this.inputType = 'json',
    this.chunkSize = 500,
    this.chunkOverlap = 50,
    this.showHelp = false,
  });

  bool get isValid => !showHelp && inputPath != null && outputPath != null;
  bool get isBatchMode => inputType == 'json-dir';

  /// Parse CLI arguments into config
  static EmbedderConfig parse(List<String> args) {
    final parser = ArgParser()
      ..addOption('input', abbr: 'i', help: 'Input file or directory path')
      ..addOption('output', abbr: 'o', help: 'Output JSON file path')
      ..addOption('input-type', defaultsTo: 'json',
          help: 'Input type: json, json-dir, pdf, or pdf-dir')
      ..addOption('model', abbr: 'm', defaultsTo: 'qwen3-0.6-embed',
          help: 'Embedding model (qwen3-0.6-embed or nomic-embed-text-v2)')
      ..addOption('text-field', abbr: 't', defaultsTo: 'question',
          help: 'Field name containing text to embed (for JSON input)')
      ..addOption('batch-size', abbr: 'b', defaultsTo: '100',
          help: 'Save progress every N embeddings')
      ..addOption('chunk-size', abbr: 'c', defaultsTo: '500',
          help: 'Chunk size in characters for PDF text')
      ..addOption('chunk-overlap', defaultsTo: '50',
          help: 'Overlap between chunks in characters')
      ..addFlag('resume', abbr: 'r', defaultsTo: true,
          help: 'Resume from existing output file if present')
      ..addFlag('help', abbr: 'h', negatable: false, help: 'Show help');

    try {
      final results = parser.parse(args);
      final showHelp = results['help'] as bool;
      final inputPath = results['input'] as String?;
      final outputPath = results['output'] as String?;

      if (showHelp || inputPath == null || outputPath == null) {
        _printHelp(parser);
        return EmbedderConfig(showHelp: true);
      }

      return EmbedderConfig(
        inputPath: inputPath,
        outputPath: outputPath,
        model: results['model'] as String,
        textField: results['text-field'] as String,
        batchSize: int.tryParse(results['batch-size'] as String) ?? 100,
        resume: results['resume'] as bool,
        inputType: results['input-type'] as String,
        chunkSize: int.tryParse(results['chunk-size'] as String) ?? 500,
        chunkOverlap: int.tryParse(results['chunk-overlap'] as String) ?? 50,
        showHelp: false,
      );
    } catch (e) {
      _printHelp(parser);
      return EmbedderConfig(showHelp: true);
    }
  }

  static void _printHelp(ArgParser parser) {
    print('''
╔═══════════════════════════════════════════════════════════════════╗
║                     CACTUS EMBEDDER v1.1.0                        ║
║         Pre-compute embeddings for RAG applications               ║
╚═══════════════════════════════════════════════════════════════════╝

USAGE:
  flutter run -- --input <file> --output <file> [options]

OPTIONS:
${parser.usage}

EXAMPLES:
  flutter run -- -i qa_pairs.json -o embeddings.json
  flutter run -- -i document.pdf -o embeddings.json --input-type pdf
  flutter run -- -i ./documents/ -o embeddings.json --input-type pdf-dir
''');
  }
}

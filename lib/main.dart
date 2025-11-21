import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:cactus/cactus.dart';
import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:path/path.dart' as p;

/// Cactus Embedder - CLI tool for pre-computing embeddings
///
/// Usage:
///   flutter run -- --input data.json --output embeddings.json
///   flutter run -- --input document.pdf --output embeddings.json --input-type pdf
///   flutter run -- --input ./pdfs/ --output embeddings.json --input-type pdf-dir
///   flutter run -- --help
///
/// Input JSON format:
/// {
///   "items": [
///     {"id": "1", "text": "Hello world", ...other fields preserved...},
///     {"id": "2", "text": "Another text", ...}
///   ]
/// }
///
/// Or for Q&A pairs:
/// {
///   "qa_pairs": [
///     {"id": "1", "question": "What is X?", "answer": "X is...", ...},
///   ]
/// }

// For testing: Set these paths, then run `flutter run -d macos`
// For production: Use command line args
const bool kTestMode = true;
// Process all MamaWise batch files (batch_02 onwards, batch_01 already done)
const String kTestInputPath = '/Users/mac/Downloads/adhere/mama_wise/assets/data';
const String kTestOutputPath = '/Users/mac/Downloads/adhere/mama_wise/assets/data/embeddings';
const String kTestInputType = 'json-dir';

void main(List<String> args) {
  final effectiveArgs = kTestMode && args.isEmpty
      ? ['-i', kTestInputPath, '-o', kTestOutputPath, '--input-type', kTestInputType]
      : args;
  runApp(CactusEmbedderApp(args: effectiveArgs));
}

class CactusEmbedderApp extends StatelessWidget {
  final List<String> args;

  const CactusEmbedderApp({super.key, required this.args});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: EmbedderScreen(args: args),
    );
  }
}

class EmbedderScreen extends StatefulWidget {
  final List<String> args;

  const EmbedderScreen({super.key, required this.args});

  @override
  State<EmbedderScreen> createState() => _EmbedderScreenState();
}

class _EmbedderScreenState extends State<EmbedderScreen> {
  final CactusLM _lm = CactusLM();

  String _status = 'Initializing...';
  double _progress = 0;
  int _processed = 0;
  int _total = 0;
  bool _isRunning = false;
  bool _isComplete = false;
  String? _error;

  // CLI arguments
  late String? _inputPath;
  late String? _outputPath;
  late String _model;
  late String _textField;
  late int _batchSize;
  late bool _resume;
  late bool _showHelp;
  late String _inputType; // json, pdf, pdf-dir
  late int _chunkSize;
  late int _chunkOverlap;

  @override
  void initState() {
    super.initState();
    _parseArgs();
    if (!_showHelp && _inputPath != null && _outputPath != null) {
      _startEmbedding();
    }
  }

  void _parseArgs() {
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
          help: 'Chunk size in characters for PDF text (default: 500)')
      ..addOption('chunk-overlap', defaultsTo: '50',
          help: 'Overlap between chunks in characters (default: 50)')
      ..addFlag('resume', abbr: 'r', defaultsTo: true,
          help: 'Resume from existing output file if present')
      ..addFlag('help', abbr: 'h', negatable: false, help: 'Show help');

    try {
      final results = parser.parse(widget.args);
      _showHelp = results['help'] as bool;
      _inputPath = results['input'] as String?;
      _outputPath = results['output'] as String?;
      _model = results['model'] as String;
      _textField = results['text-field'] as String;
      _batchSize = int.tryParse(results['batch-size'] as String) ?? 100;
      _resume = results['resume'] as bool;
      _inputType = results['input-type'] as String;
      _chunkSize = int.tryParse(results['chunk-size'] as String) ?? 500;
      _chunkOverlap = int.tryParse(results['chunk-overlap'] as String) ?? 50;

      if (_showHelp || _inputPath == null || _outputPath == null) {
        _printHelp(parser);
        _showHelp = true;
      }
    } catch (e) {
      _printHelp(parser);
      _showHelp = true;
    }
  }

  void _printHelp(ArgParser parser) {
    print('''
╔═══════════════════════════════════════════════════════════════════╗
║                     CACTUS EMBEDDER v1.1.0                        ║
║         Pre-compute embeddings for RAG applications               ║
║                  Now with PDF support!                            ║
╚═══════════════════════════════════════════════════════════════════╝

USAGE:
  flutter run -- --input <file> --output <file> [options]

OPTIONS:
${parser.usage}

EXAMPLES:
  # JSON input (default)
  flutter run -- -i qa_pairs.json -o embeddings.json

  # Single PDF file
  flutter run -- -i document.pdf -o embeddings.json --input-type pdf

  # Directory of PDFs
  flutter run -- -i ./documents/ -o embeddings.json --input-type pdf-dir

  # PDF with custom chunk settings
  flutter run -- -i doc.pdf -o out.json --input-type pdf --chunk-size 1000 --chunk-overlap 100

  # Custom text field for JSON
  flutter run -- -i data.json -o out.json --text-field content

  # Different embedding model
  flutter run -- -i data.json -o out.json -m nomic-embed-text-v2

INPUT FORMATS:
  1. JSON (--input-type json):
     { "items": [{"id": "1", "question": "...", ...}] }
     { "qa_pairs": [{"id": "1", "question": "...", "answer": "..."}] }

  2. PDF (--input-type pdf):
     Single PDF file - extracted and chunked automatically

  3. PDF Directory (--input-type pdf-dir):
     Directory of PDF files - all processed together

OUTPUT FORMAT:
  JSON with embeddings:
  {
    "chunks": [
      {
        "id": "doc_chunk_0",
        "text": "...",
        "embeddings": [...],
        "metadata": { "source": "file.pdf", "page": 1, "chunk_index": 0 }
      }
    ]
  }

SUPPORTED MODELS:
  - qwen3-0.6-embed (default, 1024 dimensions)
  - nomic-embed-text-v2 (768 dimensions)

RESUME CAPABILITY:
  If the output file exists and --resume is enabled (default),
  the tool will skip already processed items.
''');
  }

  /// Extract text from a PDF file
  Future<List<Map<String, dynamic>>> _extractPdfChunks(String pdfPath) async {
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
      final text = PdfTextExtractor(document).extractText(startPageIndex: pageIndex, endPageIndex: pageIndex);

      if (text.trim().isEmpty) continue;

      // Chunk the page text
      final pageChunks = _chunkText(text, _chunkSize, _chunkOverlap);

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

  /// Chunk text into overlapping segments
  List<String> _chunkText(String text, int chunkSize, int overlap) {
    final chunks = <String>[];

    // Clean up text - normalize whitespace
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

      // Try to break at a sentence boundary
      String chunk = text.substring(start, end);
      int lastPeriod = chunk.lastIndexOf('. ');
      int lastQuestion = chunk.lastIndexOf('? ');
      int lastExclaim = chunk.lastIndexOf('! ');
      int breakPoint = [lastPeriod, lastQuestion, lastExclaim]
          .where((i) => i > chunkSize * 0.5) // Only break if past halfway
          .fold(-1, (a, b) => a > b ? a : b);

      if (breakPoint > 0) {
        chunk = chunk.substring(0, breakPoint + 1);
        end = start + breakPoint + 1;
      } else {
        // Try to break at a space
        int lastSpace = chunk.lastIndexOf(' ');
        if (lastSpace > chunkSize * 0.7) {
          chunk = chunk.substring(0, lastSpace);
          end = start + lastSpace;
        }
      }

      chunks.add(chunk.trim());
      start = end - overlap;
      if (start < 0) start = 0;
    }

    return chunks;
  }

  /// Check if this is a batch (json-dir) mode
  bool get _isBatchMode => _inputType == 'json-dir';

  /// Get list of JSON files to process in batch mode
  Future<List<File>> _getJsonFilesToProcess() async {
    final dir = Directory(_inputPath!);
    if (!await dir.exists()) {
      throw Exception('Directory not found: $_inputPath');
    }

    final files = await dir
        .list()
        .where((f) => f is File && f.path.toLowerCase().endsWith('.json'))
        .map((f) => f as File)
        .toList();

    // Sort by filename
    files.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    return files;
  }

  /// Get output path for a batch file
  String _getBatchOutputPath(String inputFilePath) {
    final baseName = p.basenameWithoutExtension(inputFilePath);
    return p.join(_outputPath!, '${baseName}_with_embeddings.json');
  }

  /// Check if a batch file is already processed
  Future<bool> _isBatchFileComplete(String outputPath) async {
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

  /// Load items from a single JSON file
  Future<(List<Map<String, dynamic>>, String, Map<String, dynamic>)> _loadJsonFile(String filePath) async {
    final inputFile = File(filePath);
    if (!await inputFile.exists()) {
      throw Exception('Input file not found: $filePath');
    }

    final inputContent = await inputFile.readAsString();
    final inputData = json.decode(inputContent) as Map<String, dynamic>;

    List<Map<String, dynamic>> items;
    String itemsKey;

    if (inputData.containsKey('qa_pairs')) {
      items = (inputData['qa_pairs'] as List).cast<Map<String, dynamic>>();
      itemsKey = 'qa_pairs';
    } else if (inputData.containsKey('items')) {
      items = (inputData['items'] as List).cast<Map<String, dynamic>>();
      itemsKey = 'items';
    } else if (inputData.containsKey('chunks')) {
      items = (inputData['chunks'] as List).cast<Map<String, dynamic>>();
      itemsKey = 'chunks';
    } else {
      throw Exception('Input must contain "items", "qa_pairs", or "chunks" array');
    }

    // Preserve other metadata from input
    final metadata = Map<String, dynamic>.from(inputData)..remove(itemsKey);
    metadata['input_type'] = 'json';
    metadata['source_file'] = filePath;

    return (items, itemsKey, metadata);
  }

  /// Load items from various input types
  Future<(List<Map<String, dynamic>>, String, Map<String, dynamic>)> _loadInput() async {
    List<Map<String, dynamic>> items;
    String itemsKey;
    Map<String, dynamic> metadata = {};

    if (_inputType == 'pdf') {
      // Single PDF file
      items = await _extractPdfChunks(_inputPath!);
      itemsKey = 'chunks';
      metadata = {
        'input_type': 'pdf',
        'source_file': _inputPath,
        'chunk_size': _chunkSize,
        'chunk_overlap': _chunkOverlap,
      };
    } else if (_inputType == 'pdf-dir') {
      // Directory of PDFs
      final dir = Directory(_inputPath!);
      if (!await dir.exists()) {
        throw Exception('Directory not found: $_inputPath');
      }

      items = [];
      final pdfFiles = await dir
          .list()
          .where((f) => f is File && f.path.toLowerCase().endsWith('.pdf'))
          .toList();

      print('📁 Found ${pdfFiles.length} PDF files in directory');

      for (final file in pdfFiles) {
        final chunks = await _extractPdfChunks(file.path);
        items.addAll(chunks);
      }

      itemsKey = 'chunks';
      metadata = {
        'input_type': 'pdf-dir',
        'source_directory': _inputPath,
        'pdf_count': pdfFiles.length,
        'chunk_size': _chunkSize,
        'chunk_overlap': _chunkOverlap,
      };
    } else if (_inputType == 'json-dir') {
      // This shouldn't be called for json-dir mode
      throw Exception('json-dir mode uses batch processing');
    } else {
      // JSON input (default)
      return _loadJsonFile(_inputPath!);
    }

    return (items, itemsKey, metadata);
  }

  Future<void> _startEmbedding() async {
    if (_isRunning) return;

    setState(() {
      _isRunning = true;
      _status = 'Loading input...';
    });

    try {
      // Handle batch mode (json-dir) differently
      if (_isBatchMode) {
        await _startBatchEmbedding();
        return;
      }

      // Step 1: Load input (JSON or PDF)
      print('📂 Loading input from $_inputPath (type: $_inputType)...');
      final (items, itemsKey, inputMetadata) = await _loadInput();

      setState(() {
        _total = items.length;
        _status = 'Found $_total items to process';
      });
      print('📂 Loaded $_total items to embed');

      // Step 2: Check for existing progress
      Map<String, dynamic> existingEmbeddings = {};
      final outputFile = File(_outputPath!);

      if (_resume && await outputFile.exists()) {
        try {
          final existingContent = await outputFile.readAsString();
          final existingData = json.decode(existingContent) as Map<String, dynamic>;
          final existingItems = (existingData[itemsKey] as List?) ?? [];

          for (final item in existingItems) {
            if (item['embeddings'] != null) {
              existingEmbeddings[item['id'].toString()] = item;
            }
          }

          print('📥 Found ${existingEmbeddings.length} existing embeddings, resuming...');
          setState(() {
            _processed = existingEmbeddings.length;
            _progress = _processed / _total;
            _status = 'Resuming from ${existingEmbeddings.length}/$_total';
          });
        } catch (e) {
          print('⚠️  Could not read existing output, starting fresh');
        }
      }

      // Step 3: Download and initialize model
      setState(() => _status = 'Downloading model $_model...');
      print('📦 Downloading model $_model...');

      await _lm.downloadModel(
        model: _model,
        downloadProcessCallback: (progress, status, isError) {
          if (isError) {
            print('❌ Model error: $status');
          } else {
            setState(() => _status = 'Model: $status');
          }
        },
      );

      setState(() => _status = 'Initializing model...');
      print('🔧 Initializing model...');

      await _lm.initializeModel(
        params: CactusInitParams(model: _model),
      );

      setState(() => _status = 'Model ready. Generating embeddings...');
      print('✅ Model initialized. Starting embedding generation...\n');

      // Step 4: Generate embeddings
      final outputItems = <Map<String, dynamic>>[];
      final startTime = DateTime.now();
      int newlyProcessed = 0;

      // Determine text field based on input type
      final textFieldToUse = _inputType == 'json' ? _textField : 'text';

      for (int i = 0; i < items.length; i++) {
        final item = Map<String, dynamic>.from(items[i]);
        final itemId = item['id']?.toString() ?? i.toString();

        // Skip if already processed
        if (existingEmbeddings.containsKey(itemId)) {
          outputItems.add(existingEmbeddings[itemId]!);
          continue;
        }

        // Get text to embed
        final text = item[textFieldToUse]?.toString();
        if (text == null || text.isEmpty) {
          print('⚠️  Skipping item $itemId: no "$textFieldToUse" field');
          outputItems.add(item);
          continue;
        }

        // Generate embedding
        try {
          final result = await _lm.generateEmbedding(text: text);
          item['embeddings'] = result.embeddings;
          outputItems.add(item);
          newlyProcessed++;

          setState(() {
            _processed = existingEmbeddings.length + newlyProcessed;
            _progress = (_processed) / _total;
            if (_processed % 10 == 0) {
              final elapsed = DateTime.now().difference(startTime);
              final rate = newlyProcessed / elapsed.inSeconds;
              final remaining = (_total - _processed) / rate;
              _status = 'Progress: $_processed/$_total (${rate.toStringAsFixed(1)}/sec, ~${_formatDuration(remaining.toInt())} remaining)';
            }
          });

          // Progress output
          if (_processed % 100 == 0) {
            final elapsed = DateTime.now().difference(startTime);
            final rate = newlyProcessed / elapsed.inSeconds;
            print('📊 Progress: $_processed/$_total (${(100 * _progress).toStringAsFixed(1)}%) - ${rate.toStringAsFixed(1)} items/sec');
          }
        } catch (e) {
          print('❌ Error embedding item $itemId: $e');
          outputItems.add(item); // Add without embedding
        }

        // Save checkpoint
        if (newlyProcessed > 0 && newlyProcessed % _batchSize == 0) {
          await _saveOutput(outputFile, inputMetadata, itemsKey, outputItems);
          print('💾 Checkpoint saved at $_processed/$_total');
        }
      }

      // Step 5: Save final output
      await _saveOutput(outputFile, inputMetadata, itemsKey, outputItems);

      final totalTime = DateTime.now().difference(startTime);
      setState(() {
        _isComplete = true;
        _status = 'Complete! Processed $_total items in ${_formatDuration(totalTime.inSeconds)}';
      });

      print('\n╔═══════════════════════════════════════════════════════════════════╗');
      print('║                        COMPLETE! ✅                                ║');
      print('╠═══════════════════════════════════════════════════════════════════╣');
      print('║  Input type:      $_inputType');
      print('║  Total items:     $_total');
      print('║  New embeddings:  $newlyProcessed');
      print('║  Time elapsed:    ${_formatDuration(totalTime.inSeconds)}');
      print('║  Output saved:    $_outputPath');
      print('╚═══════════════════════════════════════════════════════════════════╝');

    } catch (e, stack) {
      setState(() {
        _error = e.toString();
        _status = 'Error: $e';
      });
      print('❌ Error: $e');
      print(stack);
    } finally {
      setState(() => _isRunning = false);
      _lm.unload();

      // Exit after completion
      if (_isComplete) {
        Future.delayed(const Duration(seconds: 2), () => exit(0));
      }
    }
  }

  /// Batch processing for json-dir mode - processes each JSON file separately
  Future<void> _startBatchEmbedding() async {
    final overallStartTime = DateTime.now();

    try {
      // Get all JSON files to process
      final jsonFiles = await _getJsonFilesToProcess();
      print('📁 Found ${jsonFiles.length} JSON files in $_inputPath');

      // Ensure output directory exists
      final outputDir = Directory(_outputPath!);
      if (!await outputDir.exists()) {
        await outputDir.create(recursive: true);
      }

      // Filter to only files that need processing (skip already completed)
      final filesToProcess = <File>[];
      final skippedFiles = <String>[];

      for (final file in jsonFiles) {
        final outputPath = _getBatchOutputPath(file.path);
        if (await _isBatchFileComplete(outputPath)) {
          skippedFiles.add(p.basename(file.path));
        } else {
          filesToProcess.add(file);
        }
      }

      if (skippedFiles.isNotEmpty) {
        print('⏭️  Skipping ${skippedFiles.length} already completed files');
      }

      if (filesToProcess.isEmpty) {
        print('✅ All files already processed!');
        setState(() {
          _isComplete = true;
          _status = 'All ${jsonFiles.length} files already processed!';
        });
        return;
      }

      print('📝 Will process ${filesToProcess.length} files\n');

      // Download and initialize model once
      setState(() => _status = 'Downloading model $_model...');
      print('📦 Downloading model $_model...');

      await _lm.downloadModel(
        model: _model,
        downloadProcessCallback: (progress, status, isError) {
          if (isError) {
            print('❌ Model error: $status');
          } else {
            setState(() => _status = 'Model: $status');
          }
        },
      );

      setState(() => _status = 'Initializing model...');
      print('🔧 Initializing model...');

      await _lm.initializeModel(
        params: CactusInitParams(model: _model),
      );

      print('✅ Model initialized. Starting batch embedding...\n');

      // Process each file
      int totalItemsProcessed = 0;
      int totalFilesProcessed = 0;

      for (int fileIndex = 0; fileIndex < filesToProcess.length; fileIndex++) {
        final file = filesToProcess[fileIndex];
        final fileName = p.basename(file.path);
        final outputPath = _getBatchOutputPath(file.path);
        final outputFile = File(outputPath);

        print('═══════════════════════════════════════════════════════════════════');
        print('📄 Processing file ${fileIndex + 1}/${filesToProcess.length}: $fileName');

        setState(() {
          _status = 'File ${fileIndex + 1}/${filesToProcess.length}: $fileName';
        });

        // Load items from this file
        final (items, itemsKey, inputMetadata) = await _loadJsonFile(file.path);
        print('   → Loaded ${items.length} items');

        // Check for existing progress in output file
        Map<String, dynamic> existingEmbeddings = {};
        if (_resume && await outputFile.exists()) {
          try {
            final existingContent = await outputFile.readAsString();
            final existingData = json.decode(existingContent) as Map<String, dynamic>;
            final existingItems = (existingData[itemsKey] as List?) ?? [];
            for (final item in existingItems) {
              if (item['embeddings'] != null) {
                existingEmbeddings[item['id'].toString()] = item;
              }
            }
            if (existingEmbeddings.isNotEmpty) {
              print('   → Found ${existingEmbeddings.length} existing embeddings');
            }
          } catch (e) {
            // Ignore errors, start fresh
          }
        }

        // Process items
        final outputItems = <Map<String, dynamic>>[];
        int newlyProcessed = 0;
        final fileStartTime = DateTime.now();

        for (int i = 0; i < items.length; i++) {
          final item = Map<String, dynamic>.from(items[i]);
          final itemId = item['id']?.toString() ?? i.toString();

          // Skip if already processed
          if (existingEmbeddings.containsKey(itemId)) {
            outputItems.add(existingEmbeddings[itemId]!);
            continue;
          }

          // Get text to embed
          final text = item[_textField]?.toString();
          if (text == null || text.isEmpty) {
            outputItems.add(item);
            continue;
          }

          // Generate embedding
          try {
            final result = await _lm.generateEmbedding(text: text);
            item['embeddings'] = result.embeddings;
            outputItems.add(item);
            newlyProcessed++;
            totalItemsProcessed++;

            // Update progress
            final itemProgress = (i + 1) / items.length;
            final overallProgress = (fileIndex + itemProgress) / filesToProcess.length;

            setState(() {
              _processed = totalItemsProcessed;
              _progress = overallProgress;
              _total = filesToProcess.length * 500; // Estimate
              if (newlyProcessed % 50 == 0) {
                _status = 'File ${fileIndex + 1}/${filesToProcess.length}: ${i + 1}/${items.length} items';
              }
            });

            // Save checkpoint every batch_size items
            if (newlyProcessed > 0 && newlyProcessed % _batchSize == 0) {
              await _saveOutput(outputFile, inputMetadata, itemsKey, outputItems);
            }
          } catch (e) {
            print('   ❌ Error embedding item $itemId: $e');
            outputItems.add(item);
          }
        }

        // Save final output for this file
        await _saveOutput(outputFile, inputMetadata, itemsKey, outputItems);
        totalFilesProcessed++;

        final fileTime = DateTime.now().difference(fileStartTime);
        print('   ✅ Completed: $newlyProcessed new embeddings in ${_formatDuration(fileTime.inSeconds)}');
        print('   → Saved to: ${p.basename(outputPath)}');
      }

      final totalTime = DateTime.now().difference(overallStartTime);
      setState(() {
        _isComplete = true;
        _progress = 1.0;
        _status = 'Complete! $totalFilesProcessed files, $totalItemsProcessed embeddings';
      });

      print('\n╔═══════════════════════════════════════════════════════════════════╗');
      print('║                   BATCH COMPLETE! ✅                               ║');
      print('╠═══════════════════════════════════════════════════════════════════╣');
      print('║  Files processed: $totalFilesProcessed');
      print('║  Items embedded:  $totalItemsProcessed');
      print('║  Files skipped:   ${skippedFiles.length}');
      print('║  Time elapsed:    ${_formatDuration(totalTime.inSeconds)}');
      print('║  Output dir:      $_outputPath');
      print('╚═══════════════════════════════════════════════════════════════════╝');

    } catch (e, stack) {
      setState(() {
        _error = e.toString();
        _status = 'Error: $e';
      });
      print('❌ Error: $e');
      print(stack);
    } finally {
      setState(() => _isRunning = false);
      _lm.unload();

      if (_isComplete) {
        Future.delayed(const Duration(seconds: 2), () => exit(0));
      }
    }
  }

  Future<void> _saveOutput(
    File outputFile,
    Map<String, dynamic> metadata,
    String itemsKey,
    List<Map<String, dynamic>> items,
  ) async {
    final output = Map<String, dynamic>.from(metadata);
    output[itemsKey] = items;
    output['_embedder_metadata'] = {
      'model': _model,
      'text_field': _inputType == 'json' ? _textField : 'text',
      'input_type': _inputType,
      'total_items': items.length,
      'embedded_count': items.where((i) => i['embeddings'] != null).length,
      'generated_at': DateTime.now().toIso8601String(),
      'tool': 'cactus_embedder v1.1.0',
      if (_inputType != 'json') ...{
        'chunk_size': _chunkSize,
        'chunk_overlap': _chunkOverlap,
      },
    };

    await outputFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(output),
    );
  }

  String _formatDuration(int seconds) {
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) return '${seconds ~/ 60}m ${seconds % 60}s';
    return '${seconds ~/ 3600}h ${(seconds % 3600) ~/ 60}m';
  }

  @override
  Widget build(BuildContext context) {
    if (_showHelp) {
      return Scaffold(
        backgroundColor: const Color(0xFF1E1E1E),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.help_outline, size: 64, color: Colors.white54),
              const SizedBox(height: 16),
              const Text(
                'See terminal for usage instructions',
                style: TextStyle(color: Colors.white54, fontSize: 18),
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: () => exit(0),
                child: const Text('Exit'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      body: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.memory, color: Colors.green, size: 32),
                ),
                const SizedBox(width: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Cactus Embedder',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      'Processing $_inputType input...',
                      style: const TextStyle(color: Colors.white54),
                    ),
                  ],
                ),
              ],
            ),

            const SizedBox(height: 32),

            // Progress
            if (_total > 0) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '$_processed / $_total',
                    style: const TextStyle(color: Colors.white, fontSize: 18),
                  ),
                  Text(
                    '${(_progress * 100).toStringAsFixed(1)}%',
                    style: const TextStyle(color: Colors.green, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: _progress,
                  minHeight: 12,
                  backgroundColor: Colors.white12,
                  valueColor: AlwaysStoppedAnimation(
                    _isComplete ? Colors.green : Colors.blue,
                  ),
                ),
              ),
            ],

            const SizedBox(height: 24),

            // Status
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _error != null ? Icons.error :
                        _isComplete ? Icons.check_circle :
                        Icons.info_outline,
                        color: _error != null ? Colors.red :
                               _isComplete ? Colors.green : Colors.blue,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Status',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _status,
                    style: const TextStyle(
                      color: Colors.white,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),

            const Spacer(),

            // Footer info
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.03),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  _infoChip('Type', _inputType),
                  _infoChip('Model', _model),
                  if (_inputType == 'json') _infoChip('Field', _textField),
                  if (_inputType != 'json') ...[
                    _infoChip('Chunk', '$_chunkSize'),
                    _infoChip('Overlap', '$_chunkOverlap'),
                  ],
                  _infoChip('Batch', _batchSize.toString()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoChip(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label: ',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          Text(
            value,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

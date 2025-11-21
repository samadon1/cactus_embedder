import 'dart:io';
import 'package:flutter/material.dart';
import '../models/embedder_config.dart';
import '../services/embedding_service.dart';
import '../services/json_processor.dart';
import '../services/pdf_processor.dart';
import '../utils/helpers.dart';

class EmbedderScreen extends StatefulWidget {
  final EmbedderConfig config;

  const EmbedderScreen({super.key, required this.config});

  @override
  State<EmbedderScreen> createState() => _EmbedderScreenState();
}

class _EmbedderScreenState extends State<EmbedderScreen> {
  final EmbeddingService _embedder = EmbeddingService();
  final JsonProcessor _jsonProcessor = JsonProcessor();

  String _status = 'Initializing...';
  double _progress = 0;
  int _processed = 0;
  int _total = 0;
  bool _isRunning = false;
  bool _isComplete = false;
  String? _error;

  EmbedderConfig get config => widget.config;

  @override
  void initState() {
    super.initState();
    if (config.isValid) {
      _startEmbedding();
    }
  }

  @override
  void dispose() {
    _embedder.dispose();
    super.dispose();
  }

  Future<void> _startEmbedding() async {
    if (_isRunning) return;
    setState(() {
      _isRunning = true;
      _status = 'Loading input...';
    });

    try {
      if (config.isBatchMode) {
        await _runBatchMode();
      } else {
        await _runSingleMode();
      }
    } catch (e, stack) {
      setState(() {
        _error = e.toString();
        _status = 'Error: $e';
      });
      print('❌ Error: $e');
      print(stack);
    } finally {
      setState(() => _isRunning = false);
      _embedder.dispose();
      if (_isComplete) {
        Future.delayed(const Duration(seconds: 2), () => exit(0));
      }
    }
  }

  Future<void> _runSingleMode() async {
    final startTime = DateTime.now();
    
    // Load input
    List<Map<String, dynamic>> items;
    String itemsKey;
    Map<String, dynamic> metadata;

    if (config.inputType == 'pdf') {
      final pdfProcessor = PdfProcessor(
        chunkSize: config.chunkSize,
        chunkOverlap: config.chunkOverlap,
      );
      items = await pdfProcessor.extractChunks(config.inputPath!);
      itemsKey = 'chunks';
      metadata = {
        'input_type': 'pdf',
        'source_file': config.inputPath,
        'chunk_size': config.chunkSize,
        'chunk_overlap': config.chunkOverlap,
      };
    } else if (config.inputType == 'pdf-dir') {
      final pdfProcessor = PdfProcessor(
        chunkSize: config.chunkSize,
        chunkOverlap: config.chunkOverlap,
      );
      items = await pdfProcessor.extractFromDirectory(config.inputPath!);
      itemsKey = 'chunks';
      metadata = {
        'input_type': 'pdf-dir',
        'source_directory': config.inputPath,
        'chunk_size': config.chunkSize,
        'chunk_overlap': config.chunkOverlap,
      };
    } else {
      final result = await _jsonProcessor.loadFile(config.inputPath!);
      items = result.items;
      itemsKey = result.itemsKey;
      metadata = result.metadata;
    }

    setState(() {
      _total = items.length;
      _status = 'Found $_total items';
    });

    // Load existing progress
    final existingEmbeddings = config.resume
        ? await _jsonProcessor.loadExistingEmbeddings(config.outputPath!, itemsKey)
        : <String, dynamic>{};

    if (existingEmbeddings.isNotEmpty) {
      setState(() {
        _processed = existingEmbeddings.length;
        _progress = _processed / _total;
        _status = 'Resuming from $_processed/$_total';
      });
    }

    // Initialize model
    await _embedder.initialize(config.model, onStatus: (s, {isError = false}) {
      setState(() => _status = s);
    });

    // Generate embeddings
    final outputItems = <Map<String, dynamic>>[];
    int newlyProcessed = 0;
    final textField = config.inputType == 'json' ? config.textField : 'text';

    for (int i = 0; i < items.length; i++) {
      final item = Map<String, dynamic>.from(items[i]);
      final itemId = item['id']?.toString() ?? i.toString();

      if (existingEmbeddings.containsKey(itemId)) {
        outputItems.add(existingEmbeddings[itemId]!);
        continue;
      }

      final text = item[textField]?.toString();
      if (text == null || text.isEmpty) {
        outputItems.add(item);
        continue;
      }

      try {
        item['embeddings'] = await _embedder.embed(text);
        outputItems.add(item);
        newlyProcessed++;

        setState(() {
          _processed = existingEmbeddings.length + newlyProcessed;
          _progress = _processed / _total;
          if (_processed % 10 == 0) {
            final elapsed = DateTime.now().difference(startTime).inSeconds;
            final rate = elapsed > 0 ? newlyProcessed / elapsed : 0;
            final remaining = rate > 0 ? (_total - _processed) / rate : 0;
            _status = 'Progress: $_processed/$_total (${rate.toStringAsFixed(1)}/sec, ~${formatDuration(remaining.toInt())} remaining)';
          }
        });

        // Checkpoint
        if (newlyProcessed > 0 && newlyProcessed % config.batchSize == 0) {
          await _jsonProcessor.saveOutput(
            config.outputPath!, metadata, itemsKey, outputItems,
            config.model, config.inputType, config.textField,
            chunkSize: config.inputType != 'json' ? config.chunkSize : null,
            chunkOverlap: config.inputType != 'json' ? config.chunkOverlap : null,
          );
          print('💾 Checkpoint saved at $_processed/$_total');
        }
      } catch (e) {
        print('❌ Error embedding item $itemId: $e');
        outputItems.add(item);
      }
    }

    // Save final
    await _jsonProcessor.saveOutput(
      config.outputPath!, metadata, itemsKey, outputItems,
      config.model, config.inputType, config.textField,
      chunkSize: config.inputType != 'json' ? config.chunkSize : null,
      chunkOverlap: config.inputType != 'json' ? config.chunkOverlap : null,
    );

    final elapsed = DateTime.now().difference(startTime).inSeconds;
    setState(() {
      _isComplete = true;
      _status = 'Complete! $_total items in ${formatDuration(elapsed)}';
    });

    printCompletionBanner(
      inputType: config.inputType,
      totalItems: _total,
      newEmbeddings: newlyProcessed,
      elapsedSeconds: elapsed,
      outputPath: config.outputPath!,
    );
  }

  Future<void> _runBatchMode() async {
    final startTime = DateTime.now();
    
    final jsonFiles = await _jsonProcessor.getFilesInDirectory(config.inputPath!);
    print('📁 Found ${jsonFiles.length} JSON files');

    final outputDir = Directory(config.outputPath!);
    if (!await outputDir.exists()) {
      await outputDir.create(recursive: true);
    }

    // Filter files
    final filesToProcess = <File>[];
    final skippedFiles = <String>[];

    for (final file in jsonFiles) {
      final outputPath = _jsonProcessor.getBatchOutputPath(file.path, config.outputPath!);
      if (await _jsonProcessor.isFileComplete(outputPath)) {
        skippedFiles.add(file.path);
      } else {
        filesToProcess.add(file);
      }
    }

    if (skippedFiles.isNotEmpty) {
      print('⏭️  Skipping ${skippedFiles.length} completed files');
    }

    if (filesToProcess.isEmpty) {
      setState(() {
        _isComplete = true;
        _status = 'All ${jsonFiles.length} files already processed!';
      });
      return;
    }

    // Initialize model once
    await _embedder.initialize(config.model, onStatus: (s, {isError = false}) {
      setState(() => _status = s);
    });

    int totalItemsProcessed = 0;
    int totalFilesProcessed = 0;

    for (int fileIndex = 0; fileIndex < filesToProcess.length; fileIndex++) {
      final file = filesToProcess[fileIndex];
      final outputPath = _jsonProcessor.getBatchOutputPath(file.path, config.outputPath!);

      print('═══════════════════════════════════════════════════════════════════');
      print('📄 File ${fileIndex + 1}/${filesToProcess.length}: ${file.path}');

      final result = await _jsonProcessor.loadFile(file.path);
      final existingEmbeddings = config.resume
          ? await _jsonProcessor.loadExistingEmbeddings(outputPath, result.itemsKey)
          : <String, dynamic>{};

      final outputItems = <Map<String, dynamic>>[];
      int newlyProcessed = 0;

      for (int i = 0; i < result.items.length; i++) {
        final item = Map<String, dynamic>.from(result.items[i]);
        final itemId = item['id']?.toString() ?? i.toString();

        if (existingEmbeddings.containsKey(itemId)) {
          outputItems.add(existingEmbeddings[itemId]!);
          continue;
        }

        final text = item[config.textField]?.toString();
        if (text == null || text.isEmpty) {
          outputItems.add(item);
          continue;
        }

        try {
          item['embeddings'] = await _embedder.embed(text);
          outputItems.add(item);
          newlyProcessed++;
          totalItemsProcessed++;

          final itemProgress = (i + 1) / result.items.length;
          final overallProgress = (fileIndex + itemProgress) / filesToProcess.length;

          setState(() {
            _processed = totalItemsProcessed;
            _progress = overallProgress;
            _total = filesToProcess.length * 500;
            if (newlyProcessed % 50 == 0) {
              _status = 'File ${fileIndex + 1}/${filesToProcess.length}: ${i + 1}/${result.items.length}';
            }
          });

          if (newlyProcessed > 0 && newlyProcessed % config.batchSize == 0) {
            await _jsonProcessor.saveOutput(
              outputPath, result.metadata, result.itemsKey, outputItems,
              config.model, config.inputType, config.textField,
            );
          }
        } catch (e) {
          print('   ❌ Error: $e');
          outputItems.add(item);
        }
      }

      await _jsonProcessor.saveOutput(
        outputPath, result.metadata, result.itemsKey, outputItems,
        config.model, config.inputType, config.textField,
      );
      totalFilesProcessed++;
      print('   ✅ Completed: $newlyProcessed new embeddings');
    }

    final elapsed = DateTime.now().difference(startTime).inSeconds;
    setState(() {
      _isComplete = true;
      _progress = 1.0;
      _status = 'Complete! $totalFilesProcessed files, $totalItemsProcessed embeddings';
    });

    printCompletionBanner(
      inputType: config.inputType,
      totalItems: totalItemsProcessed,
      newEmbeddings: totalItemsProcessed,
      elapsedSeconds: elapsed,
      outputPath: config.outputPath!,
      filesProcessed: totalFilesProcessed,
      filesSkipped: skippedFiles.length,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!config.isValid) {
      return _buildHelpScreen();
    }
    return _buildProgressScreen();
  }

  Widget _buildHelpScreen() {
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

  Widget _buildProgressScreen() {
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
                      style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      'Processing ${config.inputType} input...',
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
                  Text('$_processed / $_total', style: const TextStyle(color: Colors.white, fontSize: 18)),
                  Text('${(_progress * 100).toStringAsFixed(1)}%',
                      style: const TextStyle(color: Colors.green, fontSize: 18, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: _progress,
                  minHeight: 12,
                  backgroundColor: Colors.white12,
                  valueColor: AlwaysStoppedAnimation(_isComplete ? Colors.green : Colors.blue),
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
                        _error != null ? Icons.error : _isComplete ? Icons.check_circle : Icons.info_outline,
                        color: _error != null ? Colors.red : _isComplete ? Colors.green : Colors.blue,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      const Text('Status', style: TextStyle(color: Colors.white54, fontSize: 12)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(_status, style: const TextStyle(color: Colors.white, fontFamily: 'monospace')),
                ],
              ),
            ),
            const Spacer(),

            // Footer
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _infoChip('Model', config.model),
                _infoChip('Field', config.textField),
                _infoChip('Batch', config.batchSize.toString()),
              ],
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
          Text('$label: ', style: const TextStyle(color: Colors.white54, fontSize: 12)),
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 12)),
        ],
      ),
    );
  }
}

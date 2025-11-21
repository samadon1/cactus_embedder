import 'package:cactus/cactus.dart';

/// Callback for status updates
typedef StatusCallback = void Function(String status, {bool isError});

/// Wraps CactusLM for embedding generation
class EmbeddingService {
  final CactusLM _lm = CactusLM();
  bool _isInitialized = false;

  bool get isInitialized => _isInitialized;

  /// Download and initialize the model
  Future<void> initialize(String model, {StatusCallback? onStatus}) async {
    onStatus?.call('Downloading model $model...');
    print('📦 Downloading model $model...');

    await _lm.downloadModel(
      model: model,
      downloadProcessCallback: (progress, status, isError) {
        if (isError) {
          print('❌ Model error: $status');
          onStatus?.call('Model error: $status', isError: true);
        } else {
          onStatus?.call('Model: $status');
        }
      },
    );

    onStatus?.call('Initializing model...');
    print('🔧 Initializing model...');

    await _lm.initializeModel(params: CactusInitParams(model: model));
    _isInitialized = true;

    onStatus?.call('Model ready');
    print('✅ Model initialized');
  }

  /// Generate embedding for text
  Future<List<double>> embed(String text) async {
    if (!_isInitialized) {
      throw Exception('EmbeddingService not initialized');
    }
    final result = await _lm.generateEmbedding(text: text);
    return result.embeddings;
  }

  /// Cleanup resources
  void dispose() {
    _lm.unload();
    _isInitialized = false;
  }
}

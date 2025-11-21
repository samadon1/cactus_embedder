import 'package:flutter/material.dart';
import 'models/embedder_config.dart';
import 'screens/embedder_screen.dart';

// For testing: Set to true and configure paths below
const bool kTestMode = false;
const String kTestInputPath = '/path/to/input';
const String kTestOutputPath = '/path/to/output';
const String kTestInputType = 'json';

void main(List<String> args) {
  final effectiveArgs = kTestMode && args.isEmpty
      ? ['-i', kTestInputPath, '-o', kTestOutputPath, '--input-type', kTestInputType]
      : args;

  final config = EmbedderConfig.parse(effectiveArgs);
  runApp(CactusEmbedderApp(config: config));
}

class CactusEmbedderApp extends StatelessWidget {
  final EmbedderConfig config;

  const CactusEmbedderApp({super.key, required this.config});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: EmbedderScreen(config: config),
    );
  }
}

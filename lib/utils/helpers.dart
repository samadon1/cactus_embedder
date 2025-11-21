/// Format seconds into human readable duration
String formatDuration(int seconds) {
  if (seconds < 60) return '${seconds}s';
  if (seconds < 3600) return '${seconds ~/ 60}m ${seconds % 60}s';
  return '${seconds ~/ 3600}h ${(seconds % 3600) ~/ 60}m';
}

/// Print completion banner
void printCompletionBanner({
  required String inputType,
  required int totalItems,
  required int newEmbeddings,
  required int elapsedSeconds,
  required String outputPath,
  int? filesProcessed,
  int? filesSkipped,
}) {
  print('\n╔═══════════════════════════════════════════════════════════════════╗');
  print('║                        COMPLETE! ✅                                ║');
  print('╠═══════════════════════════════════════════════════════════════════╣');
  if (filesProcessed != null) {
    print('║  Files processed: $filesProcessed');
    if (filesSkipped != null) print('║  Files skipped:   $filesSkipped');
  }
  print('║  Input type:      $inputType');
  print('║  Total items:     $totalItems');
  print('║  New embeddings:  $newEmbeddings');
  print('║  Time elapsed:    ${formatDuration(elapsedSeconds)}');
  print('║  Output saved:    $outputPath');
  print('╚═══════════════════════════════════════════════════════════════════╝');
}

// ignore_for_file: avoid_print
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// One recognised line of text with its position in image pixels.
class OcrLine {
  final String text;
  final double left, top, width, height;
  const OcrLine(this.text, this.left, this.top, this.width, this.height);
}

/// OCR result for one page.
class OcrPage {
  final String text;              // full text (reading order from ML Kit)
  final List<String> paragraphs;  // one entry per text block
  final List<OcrLine> lines;      // for the invisible text layer in PDFs
  const OcrPage(this.text, this.paragraphs, this.lines);

  static const empty = OcrPage('', [], []);

  /// Returns a copy with every box multiplied by [s] (used when the exported
  /// image was downscaled after OCR ran on the full-size image).
  OcrPage scaled(double s) {
    if ((s - 1.0).abs() < 1e-6) return this;
    return OcrPage(
      text,
      paragraphs,
      lines.map((l) => OcrLine(l.text, l.left * s, l.top * s, l.width * s, l.height * s)).toList(),
    );
  }
}

/// Offline text recognition (Google ML Kit, Latin script — bundled in the APK,
/// no internet required).
class OcrService {
  static Future<OcrPage> recognizeFile(String filePath) async {
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final result = await recognizer.processImage(InputImage.fromFilePath(filePath));
      final paragraphs = <String>[];
      final lines = <OcrLine>[];
      for (final block in result.blocks) {
        paragraphs.add(block.lines.map((l) => l.text).join('\n'));
        for (final line in block.lines) {
          final r = line.boundingBox;
          lines.add(OcrLine(line.text, r.left, r.top, r.width, r.height));
        }
      }
      return OcrPage(result.text, paragraphs, lines);
    } catch (e) {
      print('[OcrService] error: $e');
      return OcrPage.empty;
    } finally {
      await recognizer.close();
    }
  }

  static Future<List<OcrPage>> recognizeFiles(
    List<String> paths, {
    void Function(int done, int total)? onProgress,
  }) async {
    final out = <OcrPage>[];
    for (int i = 0; i < paths.length; i++) {
      out.add(await recognizeFile(paths[i]));
      onProgress?.call(i + 1, paths.length);
    }
    return out;
  }
}

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

  /// Finds which clockwise rotation (0, 90, 180, 270) makes the text upright,
  /// by reading the 4 probe images and keeping the one with the most real words.
  /// Returns 0 when there is not enough text to decide.
  static Future<int> detectUprightAngle(List<String> probes) async {
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    final word = RegExp(r'^[A-Za-z0-9][A-Za-z0-9.,:;()/\-]*$');
    final scores = <int>[];
    try {
      for (final p in probes) {
        int score = 0;
        try {
          final r = await recognizer.processImage(InputImage.fromFilePath(p));
          for (final block in r.blocks) {
            for (final line in block.lines) {
              for (final el in line.elements) {
                final t = el.text.trim();
                if (t.length >= 3 && word.hasMatch(t)) score += t.length;
              }
            }
          }
        } catch (e) {
          print('[OcrService] probe error: $e');
        }
        scores.add(score);
      }
    } finally {
      await recognizer.close();
    }
    if (scores.length != 4) return 0;
    int best = 0;
    for (int i = 1; i < 4; i++) {
      if (scores[i] > scores[best]) best = i;
    }
    print('[OcrService] orientation scores: $scores');
    if (best == 0) return 0;
    // Only rotate when the evidence is clear
    if (scores[best] < 25 || scores[best] < scores[0] * 1.6) return 0;
    return best * 90;
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

// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:opencv_dart/opencv_dart.dart' as cv;

/// Document enhancement filters (OpenCV via dart:ffi, 100% offline).
///
/// Every "scan" style filter starts from the same building block: an estimate
/// of the paper's illumination (text removed with a morphological close at a
/// reduced resolution). Dividing the photo by that map makes the paper evenly
/// white and removes shadows/vignetting, then each filter applies its own
/// tone curve.
class ImageFilterService {
  /// Filter ids (stored in project data — do not rename) and Indonesian labels.
  static const List<String> filterIds = [
    'Original', 'Enhance', 'No Shadow', 'Magic Color', 'Lighten', 'B&W', 'Grayscale',
  ];

  static const Map<String, String> filterLabels = {
    'Original': 'Asli',
    'Enhance': 'Tingkatkan',
    'No Shadow': 'Tanpa Bayang',
    'Magic Color': 'Warna Ajaib',
    'Lighten': 'Pencerah',
    'B&W': 'Hitam Putih',
    'Grayscale': 'Abu-Abu',
  };

  static String labelOf(String id) => filterLabels[id] ?? id;

  /// Applies a filter to JPEG/PNG bytes. Call inside compute().
  static Uint8List applyFilter(Map<String, dynamic> params) {
    final Uint8List bytes = params['bytes'] as Uint8List;
    final String filterType = params['filter'] as String;
    final int quality = params['quality'] as int? ?? 92;
    if (filterType == 'Original') return bytes;
    try {
      return _applyFilterOcv(bytes, filterType, quality) ?? bytes;
    } catch (e) {
      print('[ImageFilterService] OpenCV error ($filterType): $e — returning original');
      return bytes;
    }
  }

  /// File-to-file variant (avoids copying large byte arrays between isolates).
  /// params: {'input', 'output', 'filter', 'quality'}; returns true on success.
  static bool applyFilterToFile(Map<String, dynamic> params) {
    final input = params['input'] as String;
    final output = params['output'] as String;
    final filter = params['filter'] as String;
    final quality = params['quality'] as int? ?? 92;
    try {
      final bytes = File(input).readAsBytesSync();
      final out = filter == 'Original' ? bytes : (_applyFilterOcv(bytes, filter, quality) ?? bytes);
      File(output).writeAsBytesSync(out);
      return true;
    } catch (e) {
      print('[ImageFilterService] applyFilterToFile error: $e');
      return false;
    }
  }

  /// Re-encodes any image bytes (e.g. PNG from the Flutter canvas) as JPEG.
  static Uint8List reencodeJpeg(Map<String, dynamic> params) {
    final bytes = params['bytes'] as Uint8List;
    final quality = params['quality'] as int? ?? 90;
    final maxDim = params['maxDim'] as int? ?? 0;
    cv.Mat? mat, resized;
    try {
      mat = cv.imdecode(bytes, cv.IMREAD_COLOR);
      cv.Mat out = mat;
      if (maxDim > 0 && max(mat.cols, mat.rows) > maxDim) {
        final s = maxDim / max(mat.cols, mat.rows);
        resized = cv.resize(mat, ((mat.cols * s).round(), (mat.rows * s).round()), interpolation: cv.INTER_AREA);
        out = resized;
      }
      final p = cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, quality]);
      final (_, enc) = cv.imencode('.jpg', out, params: p);
      p.dispose();
      return enc;
    } catch (e) {
      print('[ImageFilterService] reencodeJpeg error: $e');
      return bytes;
    } finally {
      mat?.dispose();
      resized?.dispose();
    }
  }

  static Uint8List? _applyFilterOcv(Uint8List bytes, String filterType, int quality) {
    cv.Mat? mat;
    cv.Mat? result;
    try {
      mat = cv.imdecode(bytes, cv.IMREAD_COLOR);
      if (mat.isEmpty) return null;
      result = _applyMat(mat, filterType);
      if (result == null) return null;
      final params = cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, quality]);
      final (_, encoded) = cv.imencode('.jpg', result, params: params);
      params.dispose();
      return encoded;
    } finally {
      mat?.dispose();
      result?.dispose();
    }
  }

  static cv.Mat? _applyMat(cv.Mat mat, String filterType) {
    return switch (filterType) {
      'Enhance' => _enhanceMat(mat),
      'No Shadow' => _noShadowMat(mat),
      'Lighten' => _lightenMat(mat),
      'Magic Color' => _magicColorMat(mat),
      'B&W' => _bandWMat(mat),
      'Grayscale' => _grayscaleMat(mat),
      'Original' => mat.clone(),
      _ => null,
    };
  }

  // ══════════════════════════════════════════════════════════════════════════
  // BUILDING BLOCKS
  // ══════════════════════════════════════════════════════════════════════════

  /// Estimates paper illumination (same channel count as [mat]).
  static cv.Mat _background(cv.Mat mat) {
    final w = mat.cols, h = mat.rows;
    final bw = min(400, w);
    final bh = max(1, (h * bw / w).round());
    final small = cv.resize(mat, (bw, bh), interpolation: cv.INTER_AREA);
    final k = max(3, (bw ~/ 40) | 1);
    final kernel = cv.getStructuringElement(cv.MORPH_ELLIPSE, (k, k));
    final closed = cv.morphologyEx(small, cv.MORPH_CLOSE, kernel);
    final med = cv.medianBlur(closed, 5);
    final blurred = cv.gaussianBlur(med, (0, 0), max(1.0, bw / 80));
    final bg = cv.resize(blurred, (w, h), interpolation: cv.INTER_LINEAR);
    small.dispose(); kernel.dispose(); closed.dispose(); med.dispose(); blurred.dispose();
    return bg;
  }

  /// photo / illumination * 255 → evenly lit, white paper.
  static cv.Mat _flatten(cv.Mat mat) {
    final bg = _background(mat);
    final out = cv.divide(mat, bg, scale: 255.0);
    bg.dispose();
    return out;
  }

  /// Photoshop-style "levels": maps [black..white] to [0..255] with gamma.
  static cv.Mat _levels(cv.Mat src, double black, double white, {double gamma = 1.0}) {
    final range = max(1.0, white - black);
    final lut = List<num>.generate(256, (i) {
      final t = ((i - black) / range).clamp(0.0, 1.0);
      return (pow(t, gamma) * 255).round().clamp(0, 255);
    });
    final lutMat = cv.Mat.fromList(1, 256, cv.MatType.CV_8UC1, lut);
    final out = cv.LUT(src, lutMat);
    lutMat.dispose();
    return out;
  }

  /// Paper (white) and ink (black) levels of a flattened image, from its
  /// histogram: most pixels are paper, the darkest 1% are ink.
  static (double, double) _autoLevels(cv.Mat flat) {
    final gray = flat.channels == 3 ? cv.cvtColor(flat, cv.COLOR_BGR2GRAY) : flat.clone();
    final s = 400 / max(gray.cols, gray.rows);
    final small = s < 1
        ? cv.resize(gray, (max(1, (gray.cols * s).round()), max(1, (gray.rows * s).round())), interpolation: cv.INTER_AREA)
        : gray.clone();
    final data = Uint8List.fromList(small.data);
    gray.dispose();
    small.dispose();
    final hist = List<int>.filled(256, 0);
    for (final v in data) {
      hist[v]++;
    }
    int pct(double p) {
      final target = data.length * p;
      int acc = 0;
      for (int i = 0; i < 256; i++) {
        acc += hist[i];
        if (acc >= target) return i;
      }
      return 255;
    }

    final white = (pct(0.55) - 8).clamp(200, 250).toDouble();
    final black = pct(0.01).clamp(20, 120).toDouble();
    return (black, white);
  }

  static cv.Mat _unsharp(cv.Mat mat, {double amount = 0.6, double sigma = 1.5}) {
    final blurred = cv.gaussianBlur(mat, (0, 0), sigma);
    final result = cv.addWeighted(mat, 1.0 + amount, blurred, -amount, 0);
    blurred.dispose();
    return result;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // FILTERS
  // ══════════════════════════════════════════════════════════════════════════

  /// Tingkatkan — natural colours, mild local contrast (CLAHE on L) + sharpen.
  static cv.Mat _enhanceMat(cv.Mat mat) {
    final lab = cv.cvtColor(mat, cv.COLOR_BGR2Lab);
    final lCh = cv.extractChannel(lab, 0);
    final aCh = cv.extractChannel(lab, 1);
    final bCh = cv.extractChannel(lab, 2);
    final clahe = cv.CLAHE(1.6, (8, 8));
    final lEnh = clahe.apply(lCh);
    clahe.dispose();
    final vm = cv.VecMat.fromList([lEnh, aCh, bCh]);
    final merged = cv.merge(vm);
    vm.dispose();
    final bgr = cv.cvtColor(merged, cv.COLOR_Lab2BGR);
    final out = _unsharp(bgr, amount: 0.5, sigma: 1.5);
    lab.dispose(); lCh.dispose(); aCh.dispose(); bCh.dispose(); lEnh.dispose();
    merged.dispose(); bgr.dispose();
    return out;
  }

  /// Tanpa Bayang — keeps colours, removes shadows and makes paper white.
  static cv.Mat _noShadowMat(cv.Mat mat) {
    final flat = _flatten(mat);
    final (black, white) = _autoLevels(flat);
    final lv = _levels(flat, black * 0.6, white, gamma: 1.25);
    final out = _unsharp(lv, amount: 0.5, sigma: 1.2);
    flat.dispose(); lv.dispose();
    return out;
  }

  /// Warna Ajaib — white paper, deeper ink, more vivid colour stamps/logos.
  static cv.Mat _magicColorMat(cv.Mat mat) {
    final flat = _flatten(mat);
    final (black, white) = _autoLevels(flat);
    // Strong curve: paper pure white, ink deep & bold (CamScanner-like)
    final lv = _levels(flat, black, white, gamma: 1.45);
    final hsv = cv.cvtColor(lv, cv.COLOR_BGR2HSV);
    final hCh = cv.extractChannel(hsv, 0);
    final sCh = cv.extractChannel(hsv, 1);
    final vCh = cv.extractChannel(hsv, 2);
    final sEnh = sCh.convertTo(cv.MatType.CV_8UC1, alpha: 1.5);
    final vm = cv.VecMat.fromList([hCh, sEnh, vCh]);
    final merged = cv.merge(vm);
    vm.dispose();
    final bgr = cv.cvtColor(merged, cv.COLOR_HSV2BGR);
    final out = _unsharp(bgr, amount: 0.8, sigma: 1.0);
    flat.dispose(); lv.dispose(); hsv.dispose(); hCh.dispose(); sCh.dispose();
    vCh.dispose(); sEnh.dispose(); merged.dispose(); bgr.dispose();
    return out;
  }

  /// Pencerah — brightens dark photos without clipping colours.
  static cv.Mat _lightenMat(cv.Mat mat) {
    final lab = cv.cvtColor(mat, cv.COLOR_BGR2Lab);
    final lCh = cv.extractChannel(lab, 0);
    final aCh = cv.extractChannel(lab, 1);
    final bCh = cv.extractChannel(lab, 2);

    // Percentiles of L from a small copy
    final s = 200 / max(lCh.cols, lCh.rows);
    final small = s < 1
        ? cv.resize(lCh, (max(1, (lCh.cols * s).round()), max(1, (lCh.rows * s).round())), interpolation: cv.INTER_AREA)
        : lCh.clone();
    final data = Uint8List.fromList(small.data);
    small.dispose();
    final hist = List<int>.filled(256, 0);
    for (final v in data) {
      hist[v]++;
    }
    int pct(double p) {
      final target = data.length * p;
      int acc = 0;
      for (int i = 0; i < 256; i++) {
        acc += hist[i];
        if (acc >= target) return i;
      }
      return 255;
    }

    final lo = pct(0.01).toDouble();
    final hi = pct(0.97).toDouble();
    final lNew = _levels(lCh, lo * 0.5, max(hi, lo + 40), gamma: 0.85);
    final vm = cv.VecMat.fromList([lNew, aCh, bCh]);
    final merged = cv.merge(vm);
    vm.dispose();
    final out = cv.cvtColor(merged, cv.COLOR_Lab2BGR);
    lab.dispose(); lCh.dispose(); aCh.dispose(); bCh.dispose(); lNew.dispose(); merged.dispose();
    return out;
  }

  /// Hitam Putih — photocopy look with smooth (anti-aliased) text edges.
  static cv.Mat _bandWMat(cv.Mat mat) {
    final gray = cv.cvtColor(mat, cv.COLOR_BGR2GRAY);
    final flat = _flatten(gray);
    final (black, white) = _autoLevels(flat);
    // Threshold sits between ink and paper; faint pencil/pen still turns black
    final t = white - 0.35 * (white - black);
    final soft = cv.gaussianBlur(flat, (0, 0), 0.7);
    final lut = List<num>.generate(256, (i) {
      final v = ((i - (t - 25)) / 40.0).clamp(0.0, 1.0);
      return (pow(v, 1.5) * 255).round();
    });
    final lutMat = cv.Mat.fromList(1, 256, cv.MatType.CV_8UC1, lut);
    final mapped = cv.LUT(soft, lutMat);
    final out = cv.cvtColor(mapped, cv.COLOR_GRAY2BGR);
    gray.dispose(); flat.dispose(); soft.dispose(); lutMat.dispose(); mapped.dispose();
    return out;
  }

  /// Abu-Abu — clean grayscale scan with white paper.
  static cv.Mat _grayscaleMat(cv.Mat mat) {
    final gray = cv.cvtColor(mat, cv.COLOR_BGR2GRAY);
    final flat = _flatten(gray);
    final (black, white) = _autoLevels(flat);
    final lv = _levels(flat, black * 0.7, white, gamma: 1.3);
    final sharp = _unsharp(lv, amount: 0.5, sigma: 1.2);
    final out = cv.cvtColor(sharp, cv.COLOR_GRAY2BGR);
    gray.dispose(); flat.dispose(); lv.dispose(); sharp.dispose();
    return out;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // THUMBNAILS — all filters from one tiny RGBA frame
  // ══════════════════════════════════════════════════════════════════════════
  static Map<String, Uint8List> generateAllThumbnails(Map<String, dynamic> params) {
    final int w = params['width'] as int;
    final int h = params['height'] as int;
    final Uint8List rgbaBytes = params['rgbaBytes'] as Uint8List;
    final List<String> filters = List<String>.from(params['filters'] as List);

    final img.Image tinyImage = img.Image.fromBytes(
      width: w, height: h, bytes: rgbaBytes.buffer, numChannels: 4,
    );
    final Uint8List tinyJpeg = Uint8List.fromList(img.encodeJpg(tinyImage, quality: 85));

    final Map<String, Uint8List> results = {};
    for (final filter in filters) {
      try {
        results[filter] = filter == 'Original'
            ? tinyJpeg
            : (_applyFilterOcv(tinyJpeg, filter, 80) ?? tinyJpeg);
      } catch (e) {
        print('[generateAllThumbnails] Error for $filter: $e');
        results[filter] = tinyJpeg;
      }
    }
    return results;
  }

  /// Downscales an image for preview display.
  static Uint8List resizeForPreview(Uint8List imageBytes, {int maxDimension = 600}) {
    try {
      final mat = cv.imdecode(imageBytes, cv.IMREAD_COLOR);
      try {
        final w = mat.cols, h = mat.rows;
        if (w <= maxDimension && h <= maxDimension) return imageBytes;
        final scale = maxDimension / max(w, h);
        final resized = cv.resize(mat, ((w * scale).round(), (h * scale).round()), interpolation: cv.INTER_AREA);
        final p = cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 88]);
        final (_, encoded) = cv.imencode('.jpg', resized, params: p);
        p.dispose(); resized.dispose();
        return encoded;
      } finally {
        mat.dispose();
      }
    } catch (e) {
      final decoded = img.decodeImage(imageBytes);
      if (decoded == null) return imageBytes;
      int w = decoded.width, h = decoded.height;
      if (w > maxDimension || h > maxDimension) {
        if (w > h) {
          h = (h * (maxDimension / w)).round();
          w = maxDimension;
        } else {
          w = (w * (maxDimension / h)).round();
          h = maxDimension;
        }
        final resized = img.copyResize(decoded, width: w, height: h);
        return Uint8List.fromList(img.encodeJpg(resized, quality: 88));
      }
      return imageBytes;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Diagonal security watermark (Flutter canvas).
  // ══════════════════════════════════════════════════════════════════════════
  static Future<Uint8List> applyWatermark(Uint8List imgBytes, String text) async {
    final ui.Codec codec = await ui.instantiateImageCodec(imgBytes);
    final ui.FrameInfo fi = await codec.getNextFrame();
    final ui.Image image = fi.image;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImage(image, Offset.zero, Paint());

    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.grey.withValues(alpha: 0.24),
          fontSize: (image.width * 0.045).clamp(18.0, 110.0),
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();

    final double stepX = image.width / 3;
    final double stepY = image.height / 4;
    for (int i = 1; i <= 2; i++) {
      for (int j = 1; j <= 3; j++) {
        canvas.save();
        canvas.translate(i * stepX, j * stepY);
        canvas.rotate(-pi / 6);
        textPainter.paint(canvas, Offset(-textPainter.width / 2, -textPainter.height / 2));
        canvas.restore();
      }
    }

    final picture = recorder.endRecording();
    final ui.Image wImg = await picture.toImage(image.width, image.height);
    final ByteData? byteData = await wImg.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Composites a signature onto the document at layout coordinates.
  // ══════════════════════════════════════════════════════════════════════════
  static Future<Uint8List> blendSignature(
    Uint8List imgBytes, Uint8List sigBytes,
    double sigLeft, double sigTop, double sigWidth, double sigHeight,
  ) async {
    final ui.Codec docCodec = await ui.instantiateImageCodec(imgBytes);
    final ui.FrameInfo docFi = await docCodec.getNextFrame();
    final ui.Image docImage = docFi.image;

    final ui.Codec sigCodec = await ui.instantiateImageCodec(sigBytes);
    final ui.FrameInfo sigFi = await sigCodec.getNextFrame();
    final ui.Image sigImage = sigFi.image;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImage(docImage, Offset.zero, Paint());
    canvas.drawImageRect(
      sigImage,
      Rect.fromLTWH(0, 0, sigImage.width.toDouble(), sigImage.height.toDouble()),
      Rect.fromLTWH(sigLeft, sigTop, sigWidth, sigHeight),
      Paint()..filterQuality = ui.FilterQuality.high,
    );

    final picture = recorder.endRecording();
    final ui.Image blended = await picture.toImage(docImage.width, docImage.height);
    final ByteData? byteData = await blended.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }
}

// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:opencv_dart/opencv_dart.dart' as cv;

/// Geometry helpers: image normalisation, automatic document edge detection,
/// perspective correction, rotation and ID-card composition. 100% offline.
class HomographyService {
  // ══════════════════════════════════════════════════════════════════════════
  // IMAGE NORMALISATION
  // Applies EXIF orientation (OpenCV imdecode does this), caps the resolution
  // and re-encodes as plain JPEG without EXIF. After this step every part of
  // the app (Flutter preview, OpenCV, ML Kit) sees exactly the same pixels, so
  // crop corners can never be rotated or mirrored by accident.
  // ══════════════════════════════════════════════════════════════════════════

  /// params: {'input': String path, 'output': String path, 'maxDim': int}
  /// returns [width, height] of the written image, or null on failure.
  static List<int>? normalizeImageFile(Map<String, dynamic> params) {
    final String input = params['input'] as String;
    final String output = params['output'] as String;
    final int maxDim = params['maxDim'] as int? ?? 4000;
    cv.Mat? mat, resized;
    try {
      final bytes = File(input).readAsBytesSync();
      mat = cv.imdecode(bytes, cv.IMREAD_COLOR);
      if (mat.isEmpty) return null;
      cv.Mat out = mat;
      final w = mat.cols, h = mat.rows;
      if (max(w, h) > maxDim) {
        final s = maxDim / max(w, h);
        resized = cv.resize(mat, ((w * s).round(), (h * s).round()), interpolation: cv.INTER_AREA);
        out = resized;
      }
      final p = cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 95]);
      final (_, enc) = cv.imencode('.jpg', out, params: p);
      p.dispose();
      File(output).writeAsBytesSync(enc);
      return [out.cols, out.rows];
    } catch (e) {
      print('[HomographyService] normalizeImageFile error: $e');
      return null;
    } finally {
      mat?.dispose();
      resized?.dispose();
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // PERSPECTIVE WARP via OpenCV
  // ══════════════════════════════════════════════════════════════════════════

  static Uint8List? warpPerspectiveOcv({
    required Uint8List sourceBytes,
    required Point<double> tl,
    required Point<double> tr,
    required Point<double> br,
    required Point<double> bl,
    required int destWidth,
    required int destHeight,
    int quality = 95,
  }) {
    cv.Mat? mat, M, warped;
    try {
      mat = cv.imdecode(sourceBytes, cv.IMREAD_COLOR);

      final srcPoints = cv.VecPoint2f.fromList([
        cv.Point2f(tl.x, tl.y),
        cv.Point2f(tr.x, tr.y),
        cv.Point2f(br.x, br.y),
        cv.Point2f(bl.x, bl.y),
      ]);
      final dstPoints = cv.VecPoint2f.fromList([
        cv.Point2f(0.0, 0.0),
        cv.Point2f(destWidth.toDouble(), 0.0),
        cv.Point2f(destWidth.toDouble(), destHeight.toDouble()),
        cv.Point2f(0.0, destHeight.toDouble()),
      ]);

      M = cv.getPerspectiveTransform2f(srcPoints, dstPoints);
      srcPoints.dispose();
      dstPoints.dispose();

      // INTER_CUBIC keeps small text sharper than INTER_LINEAR.
      warped = cv.warpPerspective(
        mat, M, (destWidth, destHeight),
        flags: cv.INTER_CUBIC,
        borderMode: cv.BORDER_REPLICATE,
      );

      final params = cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, quality]);
      final (_, encoded) = cv.imencode('.jpg', warped, params: params);
      params.dispose();
      return encoded;
    } catch (e) {
      print('[HomographyService] warpPerspectiveOcv error: $e');
      return null;
    } finally {
      mat?.dispose(); M?.dispose(); warped?.dispose();
    }
  }

  /// Rotates a JPEG image clockwise by 0, 90, 180 or 270 degrees.
  static Uint8List? rotateJpegOcv(Uint8List bytes, int angleDegrees, {int quality = 95}) {
    if (angleDegrees % 360 == 0) return bytes;
    cv.Mat? mat, rotated;
    try {
      mat = cv.imdecode(bytes, cv.IMREAD_COLOR);
      final a = angleDegrees % 360;
      if (a == 90) {
        final t = cv.transpose(mat);
        rotated = cv.flip(t, 1);
        t.dispose();
      } else if (a == 180) {
        rotated = cv.flip(mat, -1);
      } else if (a == 270) {
        final t = cv.transpose(mat);
        rotated = cv.flip(t, 0);
        t.dispose();
      } else {
        return bytes;
      }
      final p = cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, quality]);
      final (_, encoded) = cv.imencode('.jpg', rotated, params: p);
      p.dispose();
      return encoded;
    } catch (e) {
      print('[HomographyService] rotateJpegOcv error: $e');
      return null;
    } finally {
      mat?.dispose(); rotated?.dispose();
    }
  }

  /// Isolate entry: rotates the files in params['paths'] in place by params['angle'].
  static bool rotateFilesInPlace(Map<String, dynamic> params) {
    final paths = List<String>.from(params['paths'] as List);
    final angle = params['angle'] as int;
    var ok = true;
    for (final p in paths) {
      try {
        final f = File(p);
        if (!f.existsSync()) continue;
        final rotated = rotateJpegOcv(f.readAsBytesSync(), angle);
        if (rotated == null) {
          ok = false;
          continue;
        }
        f.writeAsBytesSync(rotated);
      } catch (e) {
        print('[HomographyService] rotateFilesInPlace error: $e');
        ok = false;
      }
    }
    return ok;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // AUTOMATIC PAPER SIZE
  //
  // A photo taken at an angle makes the paper look shorter/wider than it is,
  // so measuring the corner distances gives the wrong proportions. We recover
  // the real width/height ratio from the perspective of the 4 corners
  // (Zhang & He, "Whiteboard scanning", 2002), assuming a typical phone focal
  // length, then snap to a standard paper size (A4, F4, Letter, Legal, ID card)
  // when the result is within 5%.
  // ══════════════════════════════════════════════════════════════════════════

  /// Height/width ratios of standard papers (portrait).
  static const Map<String, double> paperRatios = {
    'A4': 297 / 210,
    'F4': 330 / 215,
    'Letter': 279.4 / 215.9,
    'Legal': 355.6 / 215.9,
    'Kartu ID': 85.6 / 54,
    'A5': 210 / 148,
  };

  /// [quad] = tl, tr, br, bl in pixels of an image of size [imgW]x[imgH].
  /// Returns (width, height, paperName or null).
  static (int, int, String?) estimateDocumentSize({
    required List<Point<double>> quad,
    required double imgW,
    required double imgH,
    bool autoPaper = true,
    int maxDim = 4000,
  }) {
    double d(Point<double> a, Point<double> b) => a.distanceTo(b);
    final measuredW = max(d(quad[0], quad[1]), d(quad[3], quad[2]));
    final measuredH = max(d(quad[0], quad[3]), d(quad[1], quad[2]));
    double ratio = measuredW / max(1.0, measuredH); // width / height
    String? paper;

    if (autoPaper) {
      final r = _perspectiveRatio(quad, imgW, imgH);
      if (r != null && r > 0.2 && r < 5) ratio = r;
      // Snap to a standard paper size (portrait or landscape)
      double bestErr = 0.05;
      paperRatios.forEach((name, hw) {
        for (final cand in [1 / hw, hw]) {
          final err = (ratio / cand - 1).abs();
          if (err < bestErr) {
            bestErr = err;
            paper = name;
            ratio = cand;
          }
        }
      });
    }

    // Keep roughly the measured resolution, never enlarge beyond it much
    double w = measuredW, h = w / ratio;
    if (h < measuredH) {
      final s = measuredH / h;
      w *= s;
      h *= s;
    }
    final over = max(w, h) / maxDim;
    if (over > 1) {
      w /= over;
      h /= over;
    }
    return (max(50, w.round()), max(50, h.round()), paper);
  }

  /// Real width/height of the rectangle seen through the camera, or null.
  static double? _perspectiveRatio(List<Point<double>> q, double imgW, double imgH) {
    final u0 = imgW / 2, v0 = imgH / 2;
    List<double> v(Point<double> p) => [p.x - u0, p.y - v0, 1.0];
    List<double> cross(List<double> a, List<double> b) => [
          a[1] * b[2] - a[2] * b[1],
          a[2] * b[0] - a[0] * b[2],
          a[0] * b[1] - a[1] * b[0],
        ];
    double dot(List<double> a, List<double> b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];

    final m1 = v(q[0]), m2 = v(q[1]), m3 = v(q[3]), m4 = v(q[2]); // tl, tr, bl, br
    final den2 = dot(cross(m2, m4), m3);
    final den3 = dot(cross(m3, m4), m2);
    if (den2.abs() < 1e-9 || den3.abs() < 1e-9) return null;
    final k2 = dot(cross(m1, m4), m3) / den2;
    final k3 = dot(cross(m1, m4), m2) / den3;
    final n2 = [k2 * m2[0] - m1[0], k2 * m2[1] - m1[1], k2 * m2[2] - m1[2]];
    final n3 = [k3 * m3[0] - m1[0], k3 * m3[1] - m1[1], k3 * m3[2] - m1[2]];

    // Typical phone main camera: focal length ≈ 0.8 × longest image side
    final f = 0.8 * max(imgW, imgH);
    final f2 = f * f;
    final a = n2[0] * n2[0] / f2 + n2[1] * n2[1] / f2 + n2[2] * n2[2];
    final b = n3[0] * n3[0] / f2 + n3[1] * n3[1] / f2 + n3[2] * n3[2];
    if (a <= 0 || b <= 0) return null;
    final r = sqrt(a / b);
    return r.isFinite ? r : null;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // AUTO ORIENTATION — small copies rotated 0/90/180/270 for the OCR test
  // ══════════════════════════════════════════════════════════════════════════

  /// params: {'input': path, 'outPrefix': path prefix}. Returns 4 file paths
  /// (rotated 0, 90, 180, 270 degrees clockwise) or null.
  static List<String>? makeOrientationProbes(Map<String, dynamic> params) {
    cv.Mat? mat, small;
    try {
      mat = cv.imdecode(File(params['input'] as String).readAsBytesSync(), cv.IMREAD_COLOR);
      if (mat.isEmpty) return null;
      final s = 1100 / max(mat.cols, mat.rows);
      small = s < 1
          ? cv.resize(mat, ((mat.cols * s).round(), (mat.rows * s).round()), interpolation: cv.INTER_AREA)
          : mat.clone();
      final p = cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 90]);
      final (_, base) = cv.imencode('.jpg', small, params: p);
      p.dispose();
      final prefix = params['outPrefix'] as String;
      final out = <String>[];
      for (final angle in [0, 90, 180, 270]) {
        final bytes = angle == 0 ? base : (rotateJpegOcv(base, angle, quality: 90) ?? base);
        final path = '${prefix}_rot$angle.jpg';
        File(path).writeAsBytesSync(bytes);
        out.add(path);
      }
      return out;
    } catch (e) {
      print('[HomographyService] makeOrientationProbes error: $e');
      return null;
    } finally {
      mat?.dispose();
      small?.dispose();
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // AUTOMATIC DOCUMENT EDGE DETECTION
  //
  // Strategy (works even for white paper on a light background):
  //  1. Work on a ~480px copy.
  //  2. Build an edge map from three sources: luminance after a morphological
  //     CLOSE (erases printed text so it does not create false edges), the
  //     Lab "b" channel and the HSV saturation channel (paper vs. table colour).
  //  3. HoughLinesP finds long straight segments; near-duplicates are merged.
  //  4. Every combination of two roughly-parallel pairs of lines forms a
  //     candidate quadrilateral. Each candidate is scored by how much of its
  //     perimeter lies on real edges and by its area.
  //  5. If nothing convincing is found, fall back to the contour method.
  // ══════════════════════════════════════════════════════════════════════════

  /// params: {'path': String} — the (normalised) JPEG file.
  /// Returns [tlX, tlY, trX, trY, brX, brY, blX, blY] normalised to [0,1].
  static List<double>? detectDocumentCornersFromFile(Map<String, dynamic> params) {
    cv.Mat? full, small;
    try {
      final bytes = File(params['path'] as String).readAsBytesSync();
      full = cv.imdecode(bytes, cv.IMREAD_REDUCED_COLOR_4);
      if (full.isEmpty) return null;
      final w = full.cols, h = full.rows;
      final s = 480 / max(w, h);
      small = s < 1
          ? cv.resize(full, ((w * s).round(), (h * s).round()), interpolation: cv.INTER_AREA)
          : full.clone();

      // Normal sensitivity first, then a more sensitive pass for low-contrast
      // photos (white paper on a light table).
      final hough = _detectByLines(small, lumaLow: 20, lumaHigh: 50, chromaLow: 8, chromaHigh: 24) ??
          _detectByLines(small, lumaLow: 8, lumaHigh: 24, chromaLow: 5, chromaHigh: 15);
      if (hough != null) return hough;
      return _detectByContours(small);
    } catch (e) {
      print('[HomographyService] detectDocumentCorners error: $e');
      return null;
    } finally {
      full?.dispose();
      small?.dispose();
    }
  }

  static List<double>? _detectByLines(
    cv.Mat small, {
    required double lumaLow,
    required double lumaHigh,
    required double chromaLow,
    required double chromaHigh,
  }) {
    final sw = small.cols, sh = small.rows;
    final List<cv.Mat> trash = [];
    T keep<T extends cv.Mat>(T m) {
      trash.add(m);
      return m;
    }

    try {
      final lab = keep(cv.cvtColor(small, cv.COLOR_BGR2Lab));
      final hsv = keep(cv.cvtColor(small, cv.COLOR_BGR2HSV));
      final lCh = keep(cv.extractChannel(lab, 0));
      final bCh = keep(cv.extractChannel(lab, 2));
      final sCh = keep(cv.extractChannel(hsv, 1));

      final kernel = keep(cv.getStructuringElement(cv.MORPH_RECT, (11, 11)));
      final lBlur = keep(cv.gaussianBlur(lCh, (5, 5), 0));
      final lClosed = keep(cv.morphologyEx(lBlur, cv.MORPH_CLOSE, kernel));
      final bMed = keep(cv.medianBlur(bCh, 7));
      final sMed = keep(cv.medianBlur(sCh, 7));

      final e1 = keep(cv.canny(lClosed, lumaLow, lumaHigh));
      final e2 = keep(cv.canny(bMed, chromaLow, chromaHigh));
      final e3 = keep(cv.canny(sMed, chromaLow, chromaHigh));
      final e12 = keep(cv.bitwiseOR(e1, e2));
      final edges = keep(cv.bitwiseOR(e12, e3));

      final k3 = keep(cv.getStructuringElement(cv.MORPH_RECT, (3, 3)));
      final support = keep(cv.dilate(edges, k3));
      final Uint8List supp = Uint8List.fromList(support.data);

      final minDim = min(sw, sh).toDouble();
      final linesMat = keep(cv.HoughLinesP(
        edges, 1, pi / 180, 50,
        minLineLength: minDim * 0.25,
        maxLineGap: 15,
      ));
      if (linesMat.isEmpty || linesMat.rows == 0) return null;
      final raw = Uint8List.fromList(linesMat.data);
      final ints = raw.buffer.asInt32List(0, raw.lengthInBytes ~/ 4);
      final List<_Line> all = [];
      for (int i = 0; i + 3 < ints.length; i += 4) {
        all.add(_Line(ints[i].toDouble(), ints[i + 1].toDouble(),
            ints[i + 2].toDouble(), ints[i + 3].toDouble()));
      }
      final real = _mergeLines(all, 12);
      if (real.length < 3) return null;
      // The image borders act as a 4th side when the paper runs off the photo.
      final borders = [
        _Line(0, 0, sw - 1.0, 0, isBorder: true),
        _Line(sw - 1.0, 0, sw - 1.0, sh - 1.0, isBorder: true),
        _Line(0, sh - 1.0, sw - 1.0, sh - 1.0, isBorder: true),
        _Line(0, 0, 0, sh - 1.0, isBorder: true),
      ];
      final lines = [...real, ...borders];

      // Pairs of roughly parallel, well separated lines
      final List<List<_Line>> pairs = [];
      for (int i = 0; i < lines.length; i++) {
        for (int j = i + 1; j < lines.length; j++) {
          if (_angleDiff(lines[i].angle, lines[j].angle) < 0.6 &&
              lines[i].distanceTo(lines[j].midX, lines[j].midY) > 0.2 * minDim) {
            pairs.add([lines[i], lines[j]]);
          }
        }
      }

      final double area = (sw * sh).toDouble();
      double bestScore = -1, bestSupport = 0;
      List<Point<double>>? best;
      for (int i = 0; i < pairs.length; i++) {
        for (int j = i + 1; j < pairs.length; j++) {
          final a = pairs[i], b = pairs[j];
          if (identical(a[0], b[0]) || identical(a[0], b[1]) ||
              identical(a[1], b[0]) || identical(a[1], b[1])) {
            continue;
          }
          if (_angleDiff(a[0].angle, b[0].angle) < 0.9) continue;
          final nBorder = [a[0], a[1], b[0], b[1]].where((l) => l.isBorder).length;
          if (nBorder > 1) continue;
          final p1 = _intersect(a[0], b[0]);
          final p2 = _intersect(a[0], b[1]);
          final p3 = _intersect(a[1], b[1]);
          final p4 = _intersect(a[1], b[0]);
          if (p1 == null || p2 == null || p3 == null || p4 == null) continue;
          var quad = [p1, p2, p3, p4];
          if (quad.any((p) => p.x < -0.05 * sw || p.x > 1.05 * sw || p.y < -0.05 * sh || p.y > 1.05 * sh)) {
            continue;
          }
          quad = _orderClockwise(quad);
          if (!_isConvex(quad)) continue;
          final ar = _polyArea(quad) / area;
          if (ar < 0.08 || ar > 0.95) continue;
          final s = _perimeterSupport(supp, sw, sh, quad, skipImageBorder: nBorder > 0);
          final score = s * s * s * pow(ar, 0.3);
          if (score > bestScore) {
            bestScore = score;
            bestSupport = s;
            best = quad;
          }
        }
      }
      if (best == null || bestSupport < 0.45) return null;
      return _toNormalized(best, sw, sh);
    } finally {
      for (final m in trash) {
        m.dispose();
      }
    }
  }

  /// Classic contour approach (kept as a fallback).
  static List<double>? _detectByContours(cv.Mat small) {
    final sw = small.cols, sh = small.rows;
    cv.Mat? gray, blurred, closed, edges, dilated, kernel, k2;
    try {
      gray = cv.cvtColor(small, cv.COLOR_BGR2GRAY);
      blurred = cv.gaussianBlur(gray, (5, 5), 0);
      k2 = cv.getStructuringElement(cv.MORPH_RECT, (9, 9));
      closed = cv.morphologyEx(blurred, cv.MORPH_CLOSE, k2);
      edges = cv.canny(closed, 30, 90);
      kernel = cv.getStructuringElement(cv.MORPH_RECT, (5, 5));
      dilated = cv.dilate(edges, kernel);
      final (contours, hierarchy) = cv.findContours(dilated, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);
      hierarchy.dispose();
      if (contours.isEmpty) return null;

      double maxArea = 0;
      int maxIdx = -1;
      for (int i = 0; i < contours.length; i++) {
        final a = cv.contourArea(contours[i]);
        if (a > maxArea) {
          maxArea = a;
          maxIdx = i;
        }
      }
      // A contour covering (almost) the whole photo is background texture, not paper
      if (maxIdx < 0 || maxArea < sw * sh * 0.15 || maxArea > sw * sh * 0.9) return null;

      final hullMat = cv.convexHull(contours[maxIdx]);
      final hull = cv.VecPoint.fromMat(hullMat);
      hullMat.dispose();
      final peri = cv.arcLength(hull, true);
      cv.VecPoint approx = cv.approxPolyDP(hull, 0.02 * peri, true);
      if (approx.length != 4) {
        approx = cv.approxPolyN(hull, 4);
      }
      if (approx.length != 4) return null;
      var quad = List.generate(4, (i) => Point<double>(approx[i].x.toDouble(), approx[i].y.toDouble()));
      quad = _orderClockwise(quad);
      if (!_isConvex(quad)) return null;
      return _toNormalized(quad, sw, sh);
    } catch (e) {
      print('[HomographyService] contour fallback error: $e');
      return null;
    } finally {
      gray?.dispose(); blurred?.dispose(); closed?.dispose(); edges?.dispose();
      dilated?.dispose(); kernel?.dispose(); k2?.dispose();
    }
  }

  // ── geometry helpers ──────────────────────────────────────────────────────

  static List<_Line> _mergeLines(List<_Line> input, int maxCount) {
    final sorted = List<_Line>.from(input)..sort((a, b) => b.length.compareTo(a.length));
    final List<_Line> out = [];
    for (final l in sorted) {
      bool dup = false;
      for (final o in out) {
        if (_angleDiff(l.angle, o.angle) < 0.12 && o.distanceTo(l.midX, l.midY) < 8) {
          dup = true;
          break;
        }
      }
      if (!dup) out.add(l);
      if (out.length >= maxCount) break;
    }
    return out;
  }

  static double _angleDiff(double a, double b) {
    var d = (a - b).abs() % pi;
    return min(d, pi - d);
  }

  static Point<double>? _intersect(_Line l1, _Line l2) {
    final d = (l1.x1 - l1.x2) * (l2.y1 - l2.y2) - (l1.y1 - l1.y2) * (l2.x1 - l2.x2);
    if (d.abs() < 1e-6) return null;
    final a = l1.x1 * l1.y2 - l1.y1 * l1.x2;
    final b = l2.x1 * l2.y2 - l2.y1 * l2.x2;
    final px = (a * (l2.x1 - l2.x2) - (l1.x1 - l1.x2) * b) / d;
    final py = (a * (l2.y1 - l2.y2) - (l1.y1 - l1.y2) * b) / d;
    return Point<double>(px, py);
  }

  /// Orders 4 points clockwise (in screen coordinates) starting at top-left.
  static List<Point<double>> _orderClockwise(List<Point<double>> pts) {
    final cx = pts.fold<double>(0, (s, p) => s + p.x) / pts.length;
    final cy = pts.fold<double>(0, (s, p) => s + p.y) / pts.length;
    final sorted = List<Point<double>>.from(pts)
      ..sort((a, b) => atan2(a.y - cy, a.x - cx).compareTo(atan2(b.y - cy, b.x - cx)));
    int tlIdx = 0;
    double minSum = double.infinity;
    for (int i = 0; i < 4; i++) {
      final s = sorted[i].x + sorted[i].y;
      if (s < minSum) {
        minSum = s;
        tlIdx = i;
      }
    }
    return List.generate(4, (i) => sorted[(tlIdx + i) % 4]);
  }

  static bool _isConvex(List<Point<double>> q) {
    int sign = 0;
    for (int i = 0; i < 4; i++) {
      final a = q[i], b = q[(i + 1) % 4], c = q[(i + 2) % 4];
      final cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
      if (cross.abs() < 1e-9) return false;
      final s = cross > 0 ? 1 : -1;
      if (sign == 0) {
        sign = s;
      } else if (s != sign) {
        return false;
      }
    }
    return true;
  }

  static double _polyArea(List<Point<double>> q) {
    double s = 0;
    for (int i = 0; i < q.length; i++) {
      final a = q[i], b = q[(i + 1) % q.length];
      s += a.x * b.y - b.x * a.y;
    }
    return s.abs() / 2;
  }

  static double _perimeterSupport(Uint8List edge, int w, int h, List<Point<double>> q,
      {bool skipImageBorder = false}) {
    bool onBorder(Point<double> p, Point<double> r) {
      const t = 3.0;
      final vertical = (p.x - r.x).abs() < t && (p.x.abs() < t || (p.x - (w - 1)).abs() < t);
      final horizontal = (p.y - r.y).abs() < t && (p.y.abs() < t || (p.y - (h - 1)).abs() < t);
      return vertical || horizontal;
    }

    int n = 0, hit = 0;
    for (int i = 0; i < 4; i++) {
      final p = q[i], r = q[(i + 1) % 4];
      if (skipImageBorder && onBorder(p, r)) continue;
      final len = sqrt(pow(r.x - p.x, 2) + pow(r.y - p.y, 2));
      final steps = max(2, len ~/ 2);
      for (int k = 0; k <= steps; k++) {
        final t = k / steps;
        final x = (p.x + (r.x - p.x) * t).toInt();
        final y = (p.y + (r.y - p.y) * t).toInt();
        n++;
        if (x >= 0 && x < w && y >= 0 && y < h && edge[y * w + x] != 0) hit++;
      }
    }
    return n == 0 ? 0 : hit / n;
  }

  static List<double> _toNormalized(List<Point<double>> q, int w, int h) {
    double cx(double v) => (v / w).clamp(0.0, 1.0);
    double cy(double v) => (v / h).clamp(0.0, 1.0);
    return [
      cx(q[0].x), cy(q[0].y),
      cx(q[1].x), cy(q[1].y),
      cx(q[2].x), cy(q[2].y),
      cx(q[3].x), cy(q[3].y),
    ];
  }

  // ══════════════════════════════════════════════════════════════════════════
  // ID CARD — front & back placed on an A4 sheet (300 dpi), card aspect kept.
  // ══════════════════════════════════════════════════════════════════════════
  static Uint8List? stitchIdCard(Uint8List frontBytes, Uint8List backBytes) {
    try {
      final front = img.decodeImage(frontBytes);
      final back = img.decodeImage(backBytes);
      if (front == null || back == null) return null;

      // A4 @ 150 dpi = 1240 x 1754. ID-1 card = 85.6 x 54 mm -> ~506 x 319 px
      // at 150 dpi. We print it 1.4x larger for readability.
      const int pageW = 1240, pageH = 1754;
      final canvas = img.Image(width: pageW, height: pageH, numChannels: 3);
      img.fill(canvas, color: img.ColorRgb8(255, 255, 255));

      img.Image fit(img.Image src) {
        const int boxW = 708, boxH = 640;
        final s = min(boxW / src.width, boxH / src.height);
        return img.copyResize(src,
            width: (src.width * s).round(),
            height: (src.height * s).round(),
            interpolation: img.Interpolation.cubic);
      }

      final f = fit(front);
      final b = fit(back);
      img.compositeImage(canvas, f, dstX: (pageW - f.width) ~/ 2, dstY: 200 + (640 - f.height) ~/ 2);
      img.compositeImage(canvas, b, dstX: (pageW - b.width) ~/ 2, dstY: 960 + (640 - b.height) ~/ 2);

      return Uint8List.fromList(img.encodeJpg(canvas, quality: 95));
    } catch (e) {
      print('Stitch ID Card error: $e');
      return null;
    }
  }
}

class _Line {
  final double x1, y1, x2, y2;
  late final double angle = atan2(y2 - y1, x2 - x1) % pi;
  late final double length = sqrt(pow(x2 - x1, 2) + pow(y2 - y1, 2));
  double get midX => (x1 + x2) / 2;
  double get midY => (y1 + y2) / 2;

  final bool isBorder;

  _Line(this.x1, this.y1, this.x2, this.y2, {this.isBorder = false});

  /// Perpendicular distance from (px, py) to the infinite line.
  double distanceTo(double px, double py) {
    final l = length;
    if (l < 1e-9) return double.infinity;
    return ((y2 - y1) * px - (x2 - x1) * py + x2 * y1 - y2 * x1).abs() / l;
  }
}

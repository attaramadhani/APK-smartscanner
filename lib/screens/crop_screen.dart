// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/homography_service.dart';
import '../services/image_filter_service.dart';
import '../services/ocr_service.dart';

/// Crop screen: automatic edge detection, draggable corners & edges with a
/// magnifier, 90° rotation, "full page" toggle, then perspective correction.
/// Returns the path of the cropped JPEG (a `<path>_preview.jpg` is written next to it).
class CropScreen extends StatefulWidget {
  final String imagePath;
  final String defaultTitle;

  const CropScreen({
    super.key,
    required this.imagePath,
    required this.defaultTitle,
  });

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  static const _fullTl = Offset(0.0, 0.0);
  static const _fullTr = Offset(1.0, 0.0);
  static const _fullBr = Offset(1.0, 1.0);
  static const _fullBl = Offset(0.0, 1.0);

  bool _isInit = false;
  bool _isProcessing = false;
  String _processingText = 'Meluruskan dokumen...';
  String? _paperName;
  String? _initError;

  late String _normPath; // EXIF-corrected, size-capped copy of the photo
  int _imgWidth = 0;
  int _imgHeight = 0;
  int _rotationAngle = 0; // clockwise: 0, 90, 180, 270

  // Corners in relative coordinates of the (rotated) displayed image
  Offset _tl = const Offset(0.06, 0.06);
  Offset _tr = const Offset(0.94, 0.06);
  Offset _br = const Offset(0.94, 0.94);
  Offset _bl = const Offset(0.06, 0.94);

  // Detected corners (in rotation-0 frame), used by the "Auto" button
  List<Offset>? _detected;
  bool _showingFull = false;

  // Smart options (remembered)
  bool _autoPaper = true;   // fix proportions & snap to A4/F4/Letter/...
  bool _autoRotate = true;  // turn the page so the text is upright

  Offset? _dragPosition;
  int _dragged = -1; // 0..3 corners, 4..7 edges (top, right, bottom, left)

  double _displayLeft = 0, _displayTop = 0, _displayWidth = 0, _displayHeight = 0;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _loadImage();
  }

  Future<void> _loadPrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _autoPaper = p.getBool('auto_paper_size') ?? true;
        _autoRotate = p.getBool('auto_rotate_text') ?? true;
      });
    } catch (_) {}
  }

  Future<void> _savePrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('auto_paper_size', _autoPaper);
      await p.setBool('auto_rotate_text', _autoRotate);
    } catch (_) {}
  }

  void _showSmartOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text('Penyesuaian Otomatis', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
              SwitchListTile(
                value: _autoPaper,
                title: const Text('Ukuran kertas otomatis'),
                subtitle: const Text('Memperbaiki proporsi kertas yang difoto miring dan menyesuaikan ke A4, F4, Letter, Legal, A5 atau kartu ID',
                    style: TextStyle(fontSize: 12)),
                onChanged: (v) {
                  setSheet(() {});
                  setState(() => _autoPaper = v);
                  _savePrefs();
                },
              ),
              SwitchListTile(
                value: _autoRotate,
                title: const Text('Putar otomatis (teks tegak)'),
                subtitle: const Text('Membaca arah tulisan lalu memutar halaman agar tidak miring/terbalik',
                    style: TextStyle(fontSize: 12)),
                onChanged: (v) {
                  setSheet(() {});
                  setState(() => _autoRotate = v);
                  _savePrefs();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _loadImage() async {
    try {
      final file = File(widget.imagePath);
      int retries = 0;
      while (retries < 15 && (!await file.exists() || await file.length() == 0)) {
        await Future.delayed(const Duration(milliseconds: 100));
        retries++;
      }
      if (!await file.exists() || await file.length() == 0) {
        throw Exception('Berkas foto tidak ditemukan atau kosong.');
      }

      final tmp = await getTemporaryDirectory();
      _normPath = path.join(tmp.path, 'norm_${DateTime.now().microsecondsSinceEpoch}.jpg');
      final dims = await compute(HomographyService.normalizeImageFile, {
        'input': widget.imagePath,
        'output': _normPath,
        'maxDim': 4000,
      });
      if (dims == null) throw Exception('Gambar tidak dapat dibaca (format tidak didukung).');

      final corners = await compute(HomographyService.detectDocumentCornersFromFile, {'path': _normPath});

      if (!mounted) return;
      setState(() {
        _imgWidth = dims[0];
        _imgHeight = dims[1];
        if (corners != null && corners.length == 8) {
          _detected = [
            Offset(corners[0], corners[1]),
            Offset(corners[2], corners[3]),
            Offset(corners[4], corners[5]),
            Offset(corners[6], corners[7]),
          ];
          _tl = _detected![0];
          _tr = _detected![1];
          _br = _detected![2];
          _bl = _detected![3];
        } else {
          _setFull();
        }
        _isInit = true;
      });

      if (corners == null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Tepi dokumen tidak terdeteksi otomatis — geser sudutnya secara manual.'),
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (e, stack) {
      print('Error loading crop image: $e\n$stack');
      if (mounted) {
        setState(() {
          _initError = '$e';
          _isInit = true;
        });
      }
    }
  }

  // ── corner helpers ───────────────────────────────────────────────────────

  void _setFull() {
    _tl = _fullTl;
    _tr = _fullTr;
    _br = _fullBr;
    _bl = _fullBl;
    _showingFull = true;
  }

  /// Rotates a list of 4 corners [tl,tr,br,bl] by 90° clockwise (relative coords).
  static List<Offset> _rotateCw(List<Offset> c) {
    Offset r(Offset p) => Offset(1 - p.dy, p.dx);
    return [r(c[3]), r(c[0]), r(c[1]), r(c[2])];
  }

  List<Offset> _detectedForCurrentRotation() {
    var c = _detected!;
    for (int i = 0; i < _rotationAngle ~/ 90; i++) {
      c = _rotateCw(c);
    }
    return c;
  }

  void _rotateImage() {
    setState(() {
      final c = _rotateCw([_tl, _tr, _br, _bl]);
      _tl = c[0];
      _tr = c[1];
      _br = c[2];
      _bl = c[3];
      _rotationAngle = (_rotationAngle + 90) % 360;
    });
  }

  void _toggleAutoFull() {
    setState(() {
      if (_showingFull && _detected != null) {
        final c = _detectedForCurrentRotation();
        _tl = c[0];
        _tr = c[1];
        _br = c[2];
        _bl = c[3];
        _showingFull = false;
      } else {
        _setFull();
      }
    });
  }

  bool _isValidQuad() {
    final q = [_tl, _tr, _br, _bl];
    int sign = 0;
    for (int i = 0; i < 4; i++) {
      final a = q[i], b = q[(i + 1) % 4], c = q[(i + 2) % 4];
      final cross = (b.dx - a.dx) * (c.dy - b.dy) - (b.dy - a.dy) * (c.dx - b.dx);
      if (cross.abs() < 1e-6) return false;
      final s = cross > 0 ? 1 : -1;
      if (sign == 0) {
        sign = s;
      } else if (s != sign) {
        return false;
      }
    }
    return true;
  }

  // ── crop ─────────────────────────────────────────────────────────────────

  Future<void> _cropAndFinish() async {
    if (!_isValidQuad()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Bentuk area potong tidak valid. Pastikan keempat sudut tidak saling bersilangan.'),
          backgroundColor: Colors.orangeAccent,
        ),
      );
      return;
    }
    setState(() {
      _isProcessing = true;
      _processingText = 'Meluruskan dokumen...';
    });
    try {
      final rotated = _rotationAngle == 90 || _rotationAngle == 270;
      final w = (rotated ? _imgHeight : _imgWidth).toDouble();
      final h = (rotated ? _imgWidth : _imgHeight).toDouble();

      final tl = Offset(_tl.dx * w, _tl.dy * h);
      final tr = Offset(_tr.dx * w, _tr.dy * h);
      final br = Offset(_br.dx * w, _br.dy * h);
      final bl = Offset(_bl.dx * w, _bl.dy * h);

      // Real proportions of the paper (+ snap to A4/F4/Letter... if enabled)
      final (destW, destH, paper) = HomographyService.estimateDocumentSize(
        quad: [
          Point<double>(tl.dx, tl.dy),
          Point<double>(tr.dx, tr.dy),
          Point<double>(br.dx, br.dy),
          Point<double>(bl.dx, bl.dy),
        ],
        imgW: w,
        imgH: h,
        // Only meaningful when the corners were placed on a real sheet
        autoPaper: _autoPaper && !_showingFull,
      );
      _paperName = paper;

      final croppedPath = await compute(_processPerspectiveCropInBg, {
        'path': _normPath,
        'rotation': _rotationAngle,
        'destW': destW,
        'destH': destH,
        'pts': [tl.dx, tl.dy, tr.dx, tr.dy, br.dx, br.dy, bl.dx, bl.dy],
        'outputPath': '${_normPath}_cropped.jpg',
      });

      if (croppedPath == null) throw Exception('Transformasi perspektif gagal.');

      if (_autoRotate) {
        if (mounted) setState(() => _processingText = 'Menyesuaikan arah tulisan...');
        await _autoOrient(croppedPath);
      }
      if (mounted && _paperName != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Ukuran kertas disesuaikan: $_paperName'),
          duration: const Duration(seconds: 2),
        ));
      }
      if (mounted) Navigator.pop(context, croppedPath);
    } catch (e) {
      print('Error perspective cropping: $e');
      if (mounted) {
        setState(() => _isProcessing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal memotong dokumen: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  /// Rotates the cropped page (and its preview) so the text is upright.
  Future<void> _autoOrient(String croppedPath) async {
    try {
      final previewPath = '${croppedPath}_preview.jpg';
      final source = await File(previewPath).exists() ? previewPath : croppedPath;
      final probes = await compute(HomographyService.makeOrientationProbes, {
        'input': source,
        'outPrefix': croppedPath,
      });
      if (probes == null) return;
      final angle = await OcrService.detectUprightAngle(probes);
      for (final p in probes) {
        try {
          await File(p).delete();
        } catch (_) {}
      }
      if (angle == 0) return;
      await compute(HomographyService.rotateFilesInPlace, {
        'paths': [croppedPath, previewPath],
        'angle': angle,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Halaman diputar otomatis $angle° agar tulisan tegak'),
          duration: const Duration(seconds: 2),
        ));
      }
    } catch (e) {
      print('Auto orient error: $e');
    }
  }

  static String? _processPerspectiveCropInBg(Map<String, dynamic> params) {
    try {
      final bytes = File(params['path'] as String).readAsBytesSync();
      final rotation = params['rotation'] as int;
      final destW = params['destW'] as int;
      final destH = params['destH'] as int;
      final p = List<double>.from(params['pts'] as List);
      final outputPath = params['outputPath'] as String;

      var src = bytes;
      if (rotation != 0) {
        src = HomographyService.rotateJpegOcv(bytes, rotation) ?? bytes;
      }

      final warped = HomographyService.warpPerspectiveOcv(
        sourceBytes: src,
        tl: Point<double>(p[0], p[1]),
        tr: Point<double>(p[2], p[3]),
        br: Point<double>(p[4], p[5]),
        bl: Point<double>(p[6], p[7]),
        destWidth: destW,
        destHeight: destH,
      );
      if (warped == null) return null;

      File(outputPath).writeAsBytesSync(warped);
      try {
        final preview = ImageFilterService.resizeForPreview(warped, maxDimension: 1600);
        File('${outputPath}_preview.jpg').writeAsBytesSync(preview);
      } catch (e) {
        print('Error saving cropped preview: $e');
      }
      return outputPath;
    } catch (e) {
      print('Isolate perspective crop error: $e');
      return null;
    }
  }

  // ── UI ───────────────────────────────────────────────────────────────────

  Widget _imageView() {
    return RotatedBox(
      quarterTurns: _rotationAngle ~/ 90,
      child: Image.file(
        File(_normPath),
        fit: BoxFit.fill,
        cacheWidth: 1400,
        gaplessPlayback: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_initError != null) {
      return Scaffold(
        backgroundColor: const Color(0xFF0F172A),
        appBar: AppBar(title: Text(widget.defaultTitle)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, color: Colors.redAccent, size: 60),
                const SizedBox(height: 16),
                const Text('Gambar gagal dimuat',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                Text(_initError!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Kembali'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        title: Text(widget.defaultTitle, style: const TextStyle(fontSize: 16)),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context, null),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.auto_awesome, color: (_autoPaper || _autoRotate) ? const Color(0xFF2DD4BF) : Colors.white54),
            tooltip: 'Penyesuaian otomatis',
            onPressed: _showSmartOptions,
          ),
        ],
      ),
      body: !_isInit
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Color(0xFF14B8A6)),
                  SizedBox(height: 14),
                  Text('Mendeteksi tepi dokumen...', style: TextStyle(color: Colors.white70)),
                ],
              ),
            )
          : SafeArea(
              child: Column(
                children: [
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 6.0),
                    child: Text(
                      'Geser sudut atau sisi untuk menyesuaikan batas dokumen',
                      style: TextStyle(color: Color(0xFF2DD4BF), fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(14.0),
                      child: LayoutBuilder(builder: _buildCropArea),
                    ),
                  ),
                  _buildBottomBar(),
                ],
              ),
            ),
    );
  }

  Widget _buildCropArea(BuildContext context, BoxConstraints constraints) {
    final boxW = constraints.maxWidth, boxH = constraints.maxHeight;
    final rotated = _rotationAngle == 90 || _rotationAngle == 270;
    final imgW = (rotated ? _imgHeight : _imgWidth).toDouble();
    final imgH = (rotated ? _imgWidth : _imgHeight).toDouble();
    if (imgW <= 0 || imgH <= 0) return const SizedBox.shrink();

    final sc = min(boxW / imgW, boxH / imgH);
    final dW = imgW * sc, dH = imgH * sc;
    final dL = (boxW - dW) / 2, dT = (boxH - dH) / 2;
    _displayWidth = dW;
    _displayHeight = dH;
    _displayLeft = dL;
    _displayTop = dT;

    Offset toPx(Offset rel) => Offset(dL + rel.dx * dW, dT + rel.dy * dH);
    final tlP = toPx(_tl), trP = toPx(_tr), brP = toPx(_br), blP = toPx(_bl);

    // The Stack must be given the full box size explicitly: its only
    // non-positioned child can be a zero-size widget, which would otherwise
    // shrink the Stack to 0 px wide and shift the whole picture sideways.
    return SizedBox(
      width: boxW,
      height: boxH,
      child: Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(left: dL, top: dT, width: dW, height: dH, child: _imageView()),
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(painter: CropMaskPainter(tl: tlP, tr: trP, br: brP, bl: blP)),
          ),
        ),
        // Edge handles (move a whole side)
        _edgeHandle(4, Offset.lerp(tlP, trP, 0.5)!, horizontal: true),
        _edgeHandle(5, Offset.lerp(trP, brP, 0.5)!, horizontal: false),
        _edgeHandle(6, Offset.lerp(blP, brP, 0.5)!, horizontal: true),
        _edgeHandle(7, Offset.lerp(tlP, blP, 0.5)!, horizontal: false),
        // Corner handles
        _cornerHandle(0, tlP),
        _cornerHandle(1, trP),
        _cornerHandle(2, brP),
        _cornerHandle(3, blP),
        if (_dragPosition != null && _dragged >= 0 && _dragged <= 3) _buildMagnifier(),
        if (_isProcessing)
          Positioned.fill(
            child: Container(
              color: Colors.black54,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(color: Color(0xFF14B8A6)),
                    const SizedBox(height: 16),
                    Text(_processingText,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
          ),
      ],
      ),
    );
  }

  Offset _clampRel(Offset rel) => Offset(rel.dx.clamp(0.0, 1.0), rel.dy.clamp(0.0, 1.0));

  void _moveCorner(int index, Offset deltaPx) {
    final d = Offset(deltaPx.dx / _displayWidth, deltaPx.dy / _displayHeight);
    setState(() {
      switch (index) {
        case 0:
          _tl = _clampRel(_tl + d);
        case 1:
          _tr = _clampRel(_tr + d);
        case 2:
          _br = _clampRel(_br + d);
        case 3:
          _bl = _clampRel(_bl + d);
      }
      _showingFull = false;
      final p = [_tl, _tr, _br, _bl][index];
      _dragPosition = Offset(_displayLeft + p.dx * _displayWidth, _displayTop + p.dy * _displayHeight);
    });
  }

  void _moveEdge(int index, Offset deltaPx) {
    final d = Offset(deltaPx.dx / _displayWidth, deltaPx.dy / _displayHeight);
    setState(() {
      switch (index) {
        case 4: // top
          _tl = _clampRel(_tl + Offset(0, d.dy));
          _tr = _clampRel(_tr + Offset(0, d.dy));
        case 5: // right
          _tr = _clampRel(_tr + Offset(d.dx, 0));
          _br = _clampRel(_br + Offset(d.dx, 0));
        case 6: // bottom
          _bl = _clampRel(_bl + Offset(0, d.dy));
          _br = _clampRel(_br + Offset(0, d.dy));
        case 7: // left
          _tl = _clampRel(_tl + Offset(d.dx, 0));
          _bl = _clampRel(_bl + Offset(d.dx, 0));
      }
      _showingFull = false;
      _dragPosition = null;
    });
  }

  Widget _cornerHandle(int index, Offset offset) {
    const double hit = 56.0;
    return Positioned(
      left: offset.dx - hit / 2,
      top: offset.dy - hit / 2,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => setState(() {
          _dragged = index;
          _dragPosition = offset;
        }),
        onPanUpdate: (details) => _moveCorner(index, details.delta),
        onPanEnd: (_) => setState(() {
          _dragged = -1;
          _dragPosition = null;
        }),
        child: SizedBox(
          width: hit,
          height: hit,
          child: Center(
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: const Color(0xFF14B8A6), width: 3.5),
                shape: BoxShape.circle,
                boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 6, offset: Offset(0, 2))],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _edgeHandle(int index, Offset center, {required bool horizontal}) {
    const double hit = 44.0;
    return Positioned(
      left: center.dx - hit / 2,
      top: center.dy - hit / 2,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => setState(() => _dragged = index),
        onPanUpdate: (details) => _moveEdge(index, details.delta),
        onPanEnd: (_) => setState(() => _dragged = -1),
        child: SizedBox(
          width: hit,
          height: hit,
          child: Center(
            child: Container(
              width: horizontal ? 28 : 8,
              height: horizontal ? 8 : 28,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: const Color(0xFF14B8A6), width: 2),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMagnifier() {
    if (_dragPosition == null || _dragged < 0 || _dragged > 3) return const SizedBox.shrink();
    const double size = 110.0;
    const double zoom = 2.5;

    double magLeft = _dragPosition!.dx - size / 2;
    double magTop = _dragPosition!.dy - size - 45;
    if (magTop < 0) magTop = _dragPosition!.dy + 45; // flip below finger near the top
    magLeft = magLeft.clamp(0.0, max(0.0, _displayLeft * 2 + _displayWidth - size));

    final rx = _dragPosition!.dx - _displayLeft;
    final ry = _dragPosition!.dy - _displayTop;

    return Positioned(
      left: magLeft,
      top: magTop,
      child: IgnorePointer(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFF14B8A6), width: 3),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 8, offset: Offset(0, 3))],
            color: Colors.black,
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Positioned(
                left: -(rx * zoom) + size / 2,
                top: -(ry * zoom) + size / 2,
                width: _displayWidth * zoom,
                height: _displayHeight * zoom,
                child: _imageView(),
              ),
              Center(
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.redAccent, width: 1.5),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    final canAuto = _detected != null;
    return Container(
      color: const Color(0xFF0F172A),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 14),
      child: Row(
        children: [
          _toolButton(
            icon: Icons.rotate_right,
            label: 'Putar',
            onTap: _isProcessing ? null : _rotateImage,
          ),
          _toolButton(
            icon: _showingFull ? Icons.auto_fix_high : Icons.fullscreen,
            label: _showingFull ? (canAuto ? 'Otomatis' : 'Semua') : 'Semua',
            onTap: _isProcessing || (_showingFull && !canAuto) ? null : _toggleAutoFull,
          ),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: _isProcessing ? null : _cropAndFinish,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF14B8A6),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            icon: const Icon(Icons.check),
            label: const Text('Lanjut', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
        ],
      ),
    );
  }

  Widget _toolButton({required IconData icon, required String label, VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: onTap == null ? Colors.white24 : Colors.white),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontSize: 11, color: onTap == null ? Colors.white24 : Colors.white70)),
          ],
        ),
      ),
    );
  }
}

class CropMaskPainter extends CustomPainter {
  final Offset tl, tr, br, bl;

  CropMaskPainter({required this.tl, required this.tr, required this.br, required this.bl});

  @override
  void paint(Canvas canvas, Size size) {
    final polyPath = Path()
      ..moveTo(tl.dx, tl.dy)
      ..lineTo(tr.dx, tr.dy)
      ..lineTo(br.dx, br.dy)
      ..lineTo(bl.dx, bl.dy)
      ..close();

    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Rect.fromLTWH(-50, -50, size.width + 100, size.height + 100)),
        polyPath,
      ),
      Paint()..color = Colors.black54,
    );
    canvas.drawPath(
      polyPath,
      Paint()
        ..color = const Color(0xFF14B8A6)
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant CropMaskPainter old) =>
      old.tl != tl || old.tr != tr || old.br != br || old.bl != bl;
}

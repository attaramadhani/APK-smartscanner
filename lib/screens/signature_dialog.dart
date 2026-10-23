import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

class SignatureDialog extends StatefulWidget {
  const SignatureDialog({super.key});

  @override
  State<SignatureDialog> createState() => _SignatureDialogState();
}

class _SignatureDialogState extends State<SignatureDialog> {
  final List<Offset?> _points = [];

  Future<Uint8List?> _exportSignature() async {
    if (_points.isEmpty) return null;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // Hardcode coordinate dimensions for the signature image
    const double width = 450.0;
    const double height = 220.0;

    // Drawing transparent background
    final paintBg = Paint()..color = Colors.transparent;
    canvas.drawRect(const Rect.fromLTWH(0, 0, width, height), paintBg);

    // Draw lines
    final paintLine = Paint()
      ..color = Colors.black // ink color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 5.0;

    for (int i = 0; i < _points.length - 1; i++) {
      if (_points[i] != null && _points[i + 1] != null) {
        canvas.drawLine(_points[i]!, _points[i + 1]!, paintLine);
      }
    }

    final picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(width.toInt(), height.toInt());
    final ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(
              children: [
                Icon(Icons.draw, color: Color(0xFF2DD4BF)),
                SizedBox(width: 8),
                Text(
                  'Buat Tanda Tangan',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'Silakan gambar tanda tangan Anda menggunakan jari pada kotak di bawah ini:',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
            const SizedBox(height: 16),

            // Canvas box
            Container(
              height: 220,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF334155), width: 1),
              ),
              clipBehavior: Clip.antiAlias,
              child: GestureDetector(
                onPanUpdate: (details) {
                  setState(() {
                    _points.add(details.localPosition); 
                  });
                },
                onPanEnd: (details) => _points.add(null),
                child: CustomPaint(
                  painter: CanvasPainter(_points),
                  size: Size.infinite,
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Dialog controls
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context, null),
                  child: const Text('Batal', style: TextStyle(color: Colors.grey)),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () {
                    setState(() {
                      _points.clear();
                    });
                  },
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0xFF334155)),
                    foregroundColor: const Color(0xFF2DD4BF),
                  ),
                  child: const Text('Bersihkan'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () async {
                    final navigator = Navigator.of(context);
                    final messenger = ScaffoldMessenger.of(context);
                    final bytes = await _exportSignature();
                    if (bytes != null) {
                      navigator.pop(bytes);
                    } else {
                      messenger.showSnackBar(
                        const SnackBar(
                          content: Text('Kanvas kosong! Silakan tanda tangan terlebih dahulu.'),
                          backgroundColor: Colors.orangeAccent,
                        ),
                      );
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF14B8A6),
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Selesai'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class CanvasPainter extends CustomPainter {
  final List<Offset?> points;

  CanvasPainter(this.points);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black // ink color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 4.5;

    for (int i = 0; i < points.length - 1; i++) {
      if (points[i] != null && points[i + 1] != null) {
        // Clamp drawings within local container size bounds
        canvas.drawLine(points[i]!, points[i + 1]!, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/scanned_document.dart';
import '../services/document_service.dart';
import '../services/image_filter_service.dart';
import '../services/ocr_service.dart';
import 'crop_screen.dart';
import 'filter_screen.dart';
import 'signature_dialog.dart';

const _teal = Color(0xFF14B8A6);
const _tealLight = Color(0xFF2DD4BF);
const _card = Color(0xFF1E293B);
const _bg = Color(0xFF0F172A);

enum _ExportFormat { pdf, jpg, docx, txt }

class PreviewScreen extends StatefulWidget {
  final ScannedDocument project;

  const PreviewScreen({super.key, required this.project});

  @override
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen> {
  late ScannedDocument _doc;
  int _page = 0;
  bool _busy = false;
  String _busyText = '';
  late PageController _pageController;

  // Real pixel size of each page's display image (for aspect ratio & overlays)
  final Map<String, Size> _sizes = {};

  // Watermark & signature
  String? _watermarkText;
  Uint8List? _signatureBytes;
  int? _sigPage;
  double _sigLeft = 0.35, _sigTop = 0.55, _sigWidth = 0.32;
  static const double _sigAspect = 220 / 450;

  // Export settings (remembered)
  _ExportFormat _format = _ExportFormat.pdf;
  PdfPageSize _pageSize = PdfPageSize.a4;
  ExportQuality _quality = ExportQuality.medium;
  bool _searchable = true;

  @override
  void initState() {
    super.initState();
    _doc = widget.project;
    _pageController = PageController();
    _loadSizes();
    _loadExportPrefs();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _loadExportPrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _pageSize = PdfPageSize.values[(p.getInt('pdf_page_size') ?? 1).clamp(0, PdfPageSize.values.length - 1)];
        _quality = ExportQuality.values[(p.getInt('export_quality') ?? 1).clamp(0, ExportQuality.values.length - 1)];
        _searchable = p.getBool('pdf_searchable') ?? true;
      });
    } catch (_) {}
  }

  Future<void> _saveExportPrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt('pdf_page_size', _pageSize.index);
      await p.setInt('export_quality', _quality.index);
      await p.setBool('pdf_searchable', _searchable);
    } catch (_) {}
  }

  Future<Size?> _imageSize(String filePath) async {
    if (_sizes.containsKey(filePath)) return _sizes[filePath];
    try {
      final bytes = await File(filePath).readAsBytes();
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final desc = await ui.ImageDescriptor.encoded(buffer);
      final s = Size(desc.width.toDouble(), desc.height.toDouble());
      desc.dispose();
      buffer.dispose();
      _sizes[filePath] = s;
      return s;
    } catch (e) {
      return null;
    }
  }

  Future<void> _loadSizes() async {
    for (int i = 0; i < _doc.pageCount; i++) {
      await _imageSize(_doc.displayPathAt(i));
    }
    if (mounted) setState(() {});
  }

  void _setDoc(ScannedDocument d) {
    setState(() {
      _doc = d;
      if (_page >= d.pageCount) _page = max(0, d.pageCount - 1);
    });
    _loadSizes();
  }

  Future<T?> _runBusy<T>(String text, Future<T> Function() task) async {
    setState(() {
      _busy = true;
      _busyText = text;
    });
    try {
      return await task();
    } catch (e) {
      print('Task error: $e');
      _snack('Terjadi kesalahan: $e', error: true);
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.redAccent : _teal,
    ));
  }

  // ══════════════════════════════════════════════════════════════════════════
  // PAGE ACTIONS
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _renameProject() async {
    final c = TextEditingController(text: _doc.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ubah Nama Dokumen'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Nama Dokumen'),
          onSubmitted: (_) => Navigator.pop(context, true),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Simpan')),
        ],
      ),
    );
    if (ok == true && c.text.trim().isNotEmpty) {
      final updated = _doc.copyWith(name: c.text.trim());
      setState(() => _doc = updated);
      await DocumentService.updateProject(updated);
    }
  }

  Future<void> _rotatePage() async {
    final idx = _page;
    final updated = await _runBusy('Memutar halaman...', () {
      return DocumentService.rotatePage(project: _doc, pageIndex: idx);
    });
    if (updated != null) {
      if (_sigPage == idx) {
        _signatureBytes = null;
        _sigPage = null;
      }
      _setDoc(updated);
    }
  }

  Future<void> _editPageFilter() async {
    final idx = _page;
    final raw = _doc.filePaths[idx];
    final previewPath = path.join(path.dirname(raw), path.basename(raw).replaceFirst('raw_', 'preview_'));
    final source = await File(previewPath).exists() ? previewPath : raw;
    if (!mounted) return;

    final selected = await Navigator.push<String?>(
      context,
      MaterialPageRoute(
        builder: (_) => FilterScreen(
          imagePath: source,
          initialFilter: _doc.activeFilters[idx],
          title: 'Filter Halaman ${idx + 1}',
        ),
      ),
    );
    if (selected == null || !mounted) return;

    bool applyAll = false;
    if (_doc.pageCount > 1) {
      applyAll = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Terapkan filter'),
              content: Text('Terapkan filter "${ImageFilterService.labelOf(selected)}" ke halaman ini saja atau ke semua ${_doc.pageCount} halaman?'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Halaman ini')),
                ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Semua halaman')),
              ],
            ),
          ) ??
          false;
    }
    if (!applyAll && selected == _doc.activeFilters[idx]) return;

    final updated = await _runBusy('Menerapkan filter...', () {
      return applyAll
          ? DocumentService.setFilterForAllPages(project: _doc, filterName: selected)
          : DocumentService.setPageFilter(project: _doc, pageIndex: idx, filterName: selected);
    });
    if (updated != null) _setDoc(updated);
  }

  Future<String?> _pickAndCrop(ImageSource source, String title) async {
    final photo = await ImagePicker().pickImage(source: source);
    if (photo == null || !mounted) return null;
    return Navigator.push<String?>(
      context,
      MaterialPageRoute(builder: (_) => CropScreen(imagePath: photo.path, defaultTitle: title)),
    );
  }

  Future<String> _defaultFilter() async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getString('default_filter') ?? 'Magic Color';
    } catch (_) {
      return 'Magic Color';
    }
  }

  Future<void> _addPage(ImageSource source) async {
    try {
      final cropped = await _pickAndCrop(source, 'Potong Halaman Baru');
      if (cropped == null || !mounted) return;
      final selected = await Navigator.push<String?>(
        context,
        MaterialPageRoute(builder: (_) => FilterScreen(imagePath: cropped, initialFilter: _doc.activeFilters.last)),
      );
      if (selected == null || !mounted) return;
      final updated = await _runBusy('Menyimpan halaman...', () {
        return DocumentService.addPageToProject(project: _doc, tempCroppedPath: cropped, filterName: selected);
      });
      if (updated != null) {
        _setDoc(updated);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_pageController.hasClients) _pageController.jumpToPage(updated.pageCount - 1);
        });
      }
    } catch (e) {
      _snack('Gagal menambah halaman: $e', error: true);
    }
  }

  Future<void> _addPagesFromGallery() async {
    try {
      final files = await ImagePicker().pickMultiImage();
      if (files.isEmpty || !mounted) return;
      final filter = await _defaultFilter();
      var doc = _doc;
      for (int i = 0; i < files.length; i++) {
        if (!mounted) return;
        final cropped = await Navigator.push<String?>(
          context,
          MaterialPageRoute(
            builder: (_) => CropScreen(imagePath: files[i].path, defaultTitle: 'Potong ${i + 1} / ${files.length}'),
          ),
        );
        if (cropped == null) continue;
        final d = doc;
        final updated = await _runBusy('Menyimpan halaman ${i + 1}...', () {
          return DocumentService.addPageToProject(project: d, tempCroppedPath: cropped, filterName: filter);
        });
        if (updated != null) doc = updated;
      }
      _setDoc(doc);
    } catch (e) {
      _snack('Gagal mengimpor: $e', error: true);
    }
  }

  Future<void> _retakePage(ImageSource source) async {
    final idx = _page;
    try {
      final cropped = await _pickAndCrop(source, 'Foto Ulang Halaman ${idx + 1}');
      if (cropped == null || !mounted) return;
      final selected = await Navigator.push<String?>(
        context,
        MaterialPageRoute(builder: (_) => FilterScreen(imagePath: cropped, initialFilter: _doc.activeFilters[idx])),
      );
      if (selected == null || !mounted) return;
      final updated = await _runBusy('Menyimpan...', () {
        return DocumentService.replacePageInProject(
            project: _doc, pageIndex: idx, tempCroppedPath: cropped, filterName: selected);
      });
      if (updated != null) _setDoc(updated);
    } catch (e) {
      _snack('Gagal foto ulang: $e', error: true);
    }
  }

  Future<void> _deleteCurrentPage() async {
    final single = _doc.pageCount == 1;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(single ? 'Hapus Dokumen?' : 'Hapus Halaman?'),
        content: Text(single
            ? 'Ini satu-satunya halaman. Menghapusnya akan menghapus seluruh dokumen.'
            : 'Hapus halaman ${_page + 1}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final updated = await DocumentService.deletePageFromProject(project: _doc, pageIndex: _page);
    if (updated == null) {
      if (mounted) Navigator.pop(context);
      return;
    }
    if (_sigPage == _page) {
      _signatureBytes = null;
      _sigPage = null;
    }
    _setDoc(updated);
  }

  void _showPageSourceSheet({required bool retake}) {
    showModalBottomSheet(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(retake ? 'Foto Ulang Halaman Ini' : 'Tambah Halaman',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt, color: _teal),
              title: const Text('Kamera'),
              onTap: () {
                Navigator.pop(context);
                retake ? _retakePage(ImageSource.camera) : _addPage(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library, color: _teal),
              title: Text(retake ? 'Galeri' : 'Galeri (bisa pilih banyak)'),
              onTap: () {
                Navigator.pop(context);
                retake ? _retakePage(ImageSource.gallery) : _addPagesFromGallery();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showReorderDialog() {
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Susun Halaman'),
          content: SizedBox(
            width: double.maxFinite,
            height: 380,
            child: ReorderableListView.builder(
              itemCount: _doc.pageCount,
              onReorder: (oldIndex, newIndex) {
                if (oldIndex < newIndex) newIndex -= 1;
                List<String> move(List<String> l) {
                  final c = List<String>.from(l);
                  final item = c.removeAt(oldIndex);
                  c.insert(newIndex, item);
                  return c;
                }

                final updated = _doc.copyWith(
                  filePaths: move(_doc.filePaths),
                  displayFilePaths: move(_doc.displayFilePaths),
                  activeFilters: move(_doc.activeFilters),
                );
                if (_sigPage == oldIndex) _sigPage = newIndex;
                setDialogState(() {});
                setState(() => _doc = updated);
                DocumentService.updateProject(updated);
              },
              itemBuilder: (context, idx) => Card(
                key: ValueKey(_doc.filePaths[idx]),
                color: _bg,
                child: ListTile(
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.file(File(_doc.displayPathAt(idx)),
                        width: 40, height: 52, fit: BoxFit.cover, cacheWidth: 80),
                  ),
                  title: Text('Halaman ${idx + 1}'),
                  trailing: const Icon(Icons.drag_handle, color: _teal),
                ),
              ),
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Selesai'))],
        ),
      ),
    ).then((_) {
      if (!mounted) return;
      if (_pageController.hasClients) _pageController.jumpToPage(0);
      setState(() => _page = 0);
    });
  }

  // ══════════════════════════════════════════════════════════════════════════
  // OCR, SIGNATURE, WATERMARK
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _ocrCurrentPage() async {
    final result = await _runBusy('Membaca teks (OCR offline)...', () {
      return OcrService.recognizeFile(_doc.displayPathAt(_page));
    });
    if (result == null || !mounted) return;
    final text = result.text;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(children: [
          Icon(Icons.text_fields, color: _tealLight),
          SizedBox(width: 8),
          Expanded(child: Text('Teks Halaman (OCR)')),
        ]),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          child: SingleChildScrollView(
            child: text.trim().isEmpty
                ? const Text('Tidak ada teks yang terdeteksi. Coba filter "Hitam Putih" atau foto lebih dekat.')
                : SelectableText(text, style: const TextStyle(fontSize: 13, height: 1.4)),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Tutup')),
          if (text.trim().isNotEmpty)
            TextButton.icon(
              onPressed: () => DocumentService.shareText(text),
              icon: const Icon(Icons.share, size: 16),
              label: const Text('Bagikan'),
            ),
          if (text.trim().isNotEmpty)
            ElevatedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: text));
                Navigator.pop(context);
                _snack('Teks disalin ke papan klip');
              },
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Salin'),
            ),
        ],
      ),
    );
  }

  Future<void> _addSignature() async {
    final sig = await showDialog<Uint8List?>(context: context, builder: (_) => const SignatureDialog());
    if (sig != null) {
      setState(() {
        _signatureBytes = sig;
        _sigPage = _page;
        _sigLeft = 0.35;
        _sigTop = 0.55;
        _sigWidth = 0.32;
      });
      _snack('Geser tanda tangan ke posisi yang diinginkan. Tarik ikon sudut untuk mengubah ukuran.');
    }
  }

  void _showWatermarkDialog() {
    final c = TextEditingController(text: _watermarkText);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Tanda Air (Watermark)'),
        content: TextField(
          controller: c,
          decoration: const InputDecoration(
            labelText: 'Teks tanda air',
            hintText: 'Contoh: Hanya untuk verifikasi',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              setState(() => _watermarkText = null);
              Navigator.pop(context);
            },
            child: const Text('Hapus', style: TextStyle(color: Colors.redAccent)),
          ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
          ElevatedButton(
            onPressed: () {
              setState(() => _watermarkText = c.text.trim().isEmpty ? null : c.text.trim());
              Navigator.pop(context);
            },
            child: const Text('Terapkan'),
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // EXPORT
  // ══════════════════════════════════════════════════════════════════════════

  void _showExportSheet({bool share = false}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          Widget chip<T>(T value, T group, String label, void Function(T) onSel) => Padding(
                padding: const EdgeInsets.only(right: 8, bottom: 8),
                child: ChoiceChip(
                  label: Text(label),
                  selected: value == group,
                  onSelected: (_) => setSheet(() => onSel(value)),
                  selectedColor: _teal,
                ),
              );

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(share ? 'Bagikan Dokumen' : 'Simpan Dokumen',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text('${_doc.name} • ${_doc.pageCount} halaman • 100% offline',
                      style: const TextStyle(color: Colors.white60, fontSize: 12)),
                  const SizedBox(height: 16),
                  const Text('Format', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Wrap(children: [
                    chip(_ExportFormat.pdf, _format, 'PDF', (v) => _format = v),
                    chip(_ExportFormat.jpg, _format, 'Gambar JPG', (v) => _format = v),
                    chip(_ExportFormat.docx, _format, 'Word (OCR)', (v) => _format = v),
                    chip(_ExportFormat.txt, _format, 'Teks TXT (OCR)', (v) => _format = v),
                  ]),
                  if (_format == _ExportFormat.pdf) ...[
                    const SizedBox(height: 8),
                    const Text('Ukuran kertas', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Wrap(
                      children: PdfPageSize.values
                          .map((s) => chip(s, _pageSize, s.label, (v) => _pageSize = v))
                          .toList(),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _searchable,
                      onChanged: (v) => setSheet(() => _searchable = v),
                      title: const Text('PDF bisa dicari & disalin teksnya (OCR)'),
                      subtitle: const Text('Sedikit lebih lama diproses', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                  if (_format == _ExportFormat.pdf || _format == _ExportFormat.jpg) ...[
                    const SizedBox(height: 4),
                    const Text('Kualitas / ukuran file', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Wrap(
                      children: ExportQuality.values
                          .map((q) => chip(q, _quality, q.label, (v) => _quality = v))
                          .toList(),
                    ),
                  ],
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _teal,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: () {
                        Navigator.pop(context);
                        _saveExportPrefs();
                        _export(share: share);
                      },
                      icon: Icon(share ? Icons.share : Icons.download),
                      label: Text(share ? 'Bagikan' : 'Simpan ke HP',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Renders every page (filter already applied) + signature + watermark,
  /// compressed as JPEG. Returns bytes and the downscale factor per page.
  Future<(List<Uint8List>, List<double>)> _renderPages(ExportQuality q) async {
    final pages = <Uint8List>[];
    final scales = <double>[];
    for (int i = 0; i < _doc.pageCount; i++) {
      if (mounted) setState(() => _busyText = 'Memproses halaman ${i + 1} dari ${_doc.pageCount}...');
      final displayPath = _doc.displayPathAt(i);
      Uint8List bytes = await File(displayPath).readAsBytes();
      final size = await _imageSize(displayPath);

      if (_signatureBytes != null && _sigPage == i && size != null) {
        final w = size.width, h = size.height;
        final sw = _sigWidth * w;
        bytes = await ImageFilterService.blendSignature(
          bytes, _signatureBytes!, _sigLeft * w, _sigTop * h, sw, sw * _sigAspect,
        );
      }
      if (_watermarkText != null) {
        bytes = await ImageFilterService.applyWatermark(bytes, _watermarkText!);
      }
      final out = await compute(ImageFilterService.reencodeJpeg, {
        'bytes': bytes,
        'quality': q.jpegQuality,
        'maxDim': q.maxDim,
      });
      pages.add(out);
      final longest = size == null ? 0.0 : max(size.width, size.height);
      scales.add(longest > q.maxDim ? q.maxDim / longest : 1.0);
    }
    return (pages, scales);
  }

  Future<List<OcrPage>> _ocrAll() async {
    final paths = List.generate(_doc.pageCount, (i) => _doc.displayPathAt(i));
    return OcrService.recognizeFiles(paths, onProgress: (done, total) {
      if (mounted) setState(() => _busyText = 'Membaca teks (OCR) $done dari $total...');
    });
  }

  Future<void> _export({required bool share}) async {
    final result = await _runBusy<List<String>>('Menyiapkan ekspor...', () async {
      switch (_format) {
        case _ExportFormat.pdf:
          final (pages, scales) = await _renderPages(_quality);
          List<OcrPage>? ocr;
          if (_searchable) {
            final raw = await _ocrAll();
            ocr = List.generate(raw.length, (i) => raw[i].scaled(scales[i]));
          }
          if (mounted) setState(() => _busyText = 'Menyusun PDF...');
          final p = await DocumentService.exportPdf(
            pagesBytes: pages,
            name: _doc.name,
            pageSize: _pageSize,
            ocrPages: ocr,
          );
          return [p];
        case _ExportFormat.jpg:
          final (pages, _) = await _renderPages(_quality);
          return DocumentService.exportImages(pagesBytes: pages, name: _doc.name);
        case _ExportFormat.docx:
          final ocr = await _ocrAll();
          return [await DocumentService.exportDocx(pages: ocr, name: _doc.name)];
        case _ExportFormat.txt:
          final ocr = await _ocrAll();
          return [await DocumentService.exportTxt(pages: ocr, name: _doc.name)];
      }
    });
    if (result == null || result.isEmpty || !mounted) return;

    if (share) {
      await DocumentService.shareFiles(result);
      return;
    }
    _showExportDone(result);
  }

  void _showExportDone(List<String> paths) {
    final first = paths.first;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(children: [
          Icon(Icons.check_circle, color: _tealLight),
          SizedBox(width: 8),
          Text('Berhasil disimpan'),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_format == _ExportFormat.jpg)
              const Text('Gambar juga tersimpan di Galeri.', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 8),
            const Text('Lokasi:', style: TextStyle(color: Colors.white60, fontSize: 12)),
            Text(DocumentService.getPublicDirectoryDescription(),
                style: const TextStyle(color: _tealLight, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(paths.length == 1 ? path.basename(first) : '${paths.length} file',
                style: const TextStyle(fontSize: 12, color: Colors.white70)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Tutup')),
          TextButton.icon(
            onPressed: () {
              Navigator.pop(context);
              DocumentService.shareFiles(paths);
            },
            icon: const Icon(Icons.share, size: 16),
            label: const Text('Bagikan'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              final err = await DocumentService.openDocument(first);
              if (err != null) _snack('Tidak ada aplikasi untuk membuka file ini ($err)', error: true);
            },
            child: const Text('Buka'),
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // UI
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final count = _doc.pageCount;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: GestureDetector(
            onTap: _renameProject,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(child: Text(_doc.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15))),
              const SizedBox(width: 4),
              const Icon(Icons.edit, size: 14, color: _tealLight),
            ]),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.share),
              tooltip: 'Bagikan',
              onPressed: _busy ? null : () => _showExportSheet(share: true),
            ),
            PopupMenuButton<String>(
              enabled: !_busy,
              onSelected: (v) {
                switch (v) {
                  case 'ocr':
                    _ocrCurrentPage();
                  case 'sign':
                    _addSignature();
                  case 'wm':
                    _showWatermarkDialog();
                  case 'order':
                    _showReorderDialog();
                  case 'retake':
                    _showPageSourceSheet(retake: true);
                  case 'delete':
                    _deleteCurrentPage();
                }
              },
              itemBuilder: (_) => [
                _menuItem('ocr', Icons.text_fields, 'Ambil teks (OCR)'),
                _menuItem('sign', Icons.draw, 'Tanda tangan'),
                _menuItem('wm', Icons.branding_watermark, 'Tanda air'),
                if (count > 1) _menuItem('order', Icons.swap_vert, 'Susun halaman'),
                _menuItem('retake', Icons.replay, 'Foto ulang halaman ini'),
                _menuItem('delete', Icons.delete_outline, 'Hapus halaman ini', color: Colors.redAccent),
              ],
            ),
          ],
        ),
        body: SafeArea(
          child: Stack(
            children: [
              Column(
                children: [
                  Expanded(
                    child: PageView.builder(
                      controller: _pageController,
                      itemCount: count,
                      onPageChanged: (i) => setState(() => _page = i),
                      itemBuilder: (context, i) => _buildPage(i),
                    ),
                  ),
                  if (count > 1) _buildThumbStrip(),
                  _buildToolbar(),
                ],
              ),
              if (_busy)
                Positioned.fill(
                  child: Container(
                    color: Colors.black54,
                    child: Center(
                      child: Card(
                        color: _card,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            const CircularProgressIndicator(color: _teal),
                            const SizedBox(height: 16),
                            Text(_busyText, textAlign: TextAlign.center),
                          ]),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  PopupMenuItem<String> _menuItem(String value, IconData icon, String label, {Color color = _teal}) {
    return PopupMenuItem(
      value: value,
      child: Row(children: [Icon(icon, size: 18, color: color), const SizedBox(width: 10), Text(label)]),
    );
  }

  Widget _buildPage(int i) {
    final displayPath = _doc.displayPathAt(i);
    final size = _sizes[displayPath];
    final aspect = (size != null && size.height > 0) ? size.width / size.height : 0.707;

    return Padding(
      padding: const EdgeInsets.all(14),
      child: LayoutBuilder(builder: (context, c) {
        double w = c.maxWidth, h = c.maxWidth / aspect;
        if (h > c.maxHeight) {
          h = c.maxHeight;
          w = h * aspect;
        }
        return InteractiveViewer(
          maxScale: 4,
          child: Center(
            child: Container(
              width: w,
              height: h,
              decoration: const BoxDecoration(
                boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 12, offset: Offset(0, 4))],
              ),
              child: Stack(children: [
                Positioned.fill(
                  child: Image.file(
                    File(displayPath),
                    fit: BoxFit.fill,
                    cacheWidth: 1200,
                    gaplessPlayback: true,
                    errorBuilder: (context, error, stack) => const Center(child: Icon(Icons.broken_image, size: 48)),
                  ),
                ),
                if (_watermarkText != null)
                  Positioned.fill(child: CustomPaint(painter: PreviewWatermarkPainter(_watermarkText!))),
                if (_signatureBytes != null && _sigPage == i) _buildSignatureOverlay(w, h),
              ]),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildSignatureOverlay(double w, double h) {
    final sw = _sigWidth * w;
    final sh = sw * _sigAspect;
    return Positioned(
      left: _sigLeft * w,
      top: _sigTop * h,
      width: sw,
      height: sh,
      child: GestureDetector(
        onPanUpdate: (d) => setState(() {
          _sigLeft = (_sigLeft + d.delta.dx / w).clamp(0.0, max(0.0, 1.0 - _sigWidth));
          _sigTop = (_sigTop + d.delta.dy / h).clamp(0.0, max(0.0, 1.0 - sh / h));
        }),
        child: Container(
          decoration: BoxDecoration(border: Border.all(color: _teal, width: 1.5)),
          child: Stack(children: [
            Positioned.fill(child: Image.memory(_signatureBytes!, fit: BoxFit.fill)),
            Positioned(
              right: 0,
              top: 0,
              child: GestureDetector(
                onTap: () => setState(() {
                  _signatureBytes = null;
                  _sigPage = null;
                }),
                child: Container(
                  color: Colors.redAccent,
                  padding: const EdgeInsets.all(2),
                  child: const Icon(Icons.close, size: 14, color: Colors.white),
                ),
              ),
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: GestureDetector(
                onPanUpdate: (d) => setState(() {
                  _sigWidth = (_sigWidth + d.delta.dx / w).clamp(0.12, 0.8);
                }),
                child: Container(
                  color: _teal,
                  padding: const EdgeInsets.all(3),
                  child: const Icon(Icons.open_in_full, size: 14, color: Colors.white),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildThumbStrip() {
    return SizedBox(
      height: 76,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: _doc.pageCount,
        itemBuilder: (context, i) {
          final sel = i == _page;
          return GestureDetector(
            onTap: () => _pageController.animateToPage(i,
                duration: const Duration(milliseconds: 250), curve: Curves.easeOut),
            child: Container(
              width: 48,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                border: Border.all(color: sel ? _tealLight : Colors.white24, width: sel ? 2.5 : 1),
                borderRadius: BorderRadius.circular(6),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(fit: StackFit.expand, children: [
                Image.file(File(_doc.displayPathAt(i)), fit: BoxFit.cover, cacheWidth: 96, gaplessPlayback: true),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    color: Colors.black54,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text('${i + 1}', style: const TextStyle(fontSize: 10)),
                  ),
                ),
              ]),
            ),
          );
        },
      ),
    );
  }

  Widget _buildToolbar() {
    Widget tool(IconData icon, String label, VoidCallback onTap) => Expanded(
          child: InkWell(
            onTap: _busy ? null : onTap,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, color: Colors.white),
                const SizedBox(height: 4),
                Text(label, style: const TextStyle(fontSize: 11, color: Colors.white70)),
              ]),
            ),
          ),
        );

    return Container(
      color: _bg,
      padding: const EdgeInsets.fromLTRB(6, 6, 10, 10),
      child: Row(children: [
        tool(Icons.rotate_right, 'Putar', _rotatePage),
        tool(Icons.auto_awesome, 'Filter', _editPageFilter),
        tool(Icons.add_photo_alternate_outlined, 'Tambah', () => _showPageSourceSheet(retake: false)),
        tool(Icons.text_fields, 'OCR', _ocrCurrentPage),
        const SizedBox(width: 6),
        ElevatedButton.icon(
          onPressed: _busy ? null : () => _showExportSheet(),
          style: ElevatedButton.styleFrom(
            backgroundColor: _teal,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          icon: const Icon(Icons.download, size: 18),
          label: const Text('Simpan', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ]),
    );
  }
}

class PreviewWatermarkPainter extends CustomPainter {
  final String text;
  PreviewWatermarkPainter(this.text);

  @override
  void paint(Canvas canvas, Size size) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.grey.withValues(alpha: 0.35),
          fontSize: (size.width * 0.045).clamp(11.0, 36.0),
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final stepX = size.width / 3, stepY = size.height / 4;
    for (int i = 1; i <= 2; i++) {
      for (int j = 1; j <= 3; j++) {
        canvas.save();
        canvas.translate(i * stepX, j * stepY);
        canvas.rotate(-pi / 6);
        tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(covariant PreviewWatermarkPainter old) => old.text != text;
}

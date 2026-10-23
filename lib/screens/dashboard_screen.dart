// ignore_for_file: avoid_print
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/scanned_document.dart';
import '../services/document_service.dart';
import '../services/homography_service.dart';
import '../services/image_filter_service.dart';
import 'crop_screen.dart';
import 'filter_screen.dart';
import 'preview_screen.dart';

const _teal = Color(0xFF14B8A6);
const _tealLight = Color(0xFF2DD4BF);
const _card = Color(0xFF1E293B);
const _bg = Color(0xFF0F172A);

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with WidgetsBindingObserver {
  List<ScannedDocument> _all = [];
  List<ScannedDocument> _shown = [];
  bool _loading = true;
  String _loadingText = '';
  final TextEditingController _search = TextEditingController();

  // Multi-select (long press)
  final List<String> _selected = [];
  bool get _selecting => _selected.isNotEmpty;

  // Biometric lock
  final LocalAuthentication _auth = LocalAuthentication();
  bool _lockEnabled = false;
  bool _unlocked = true;
  bool _authInProgress = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _search.addListener(_applySearch);
    _loadHistory();
    _initLock();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _search.dispose();
    super.dispose();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // LOCK
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _initLock() async {
    final prefs = await SharedPreferences.getInstance();
    final locked = prefs.getBool('biometric_lock') ?? false;
    if (!mounted) return;
    setState(() {
      _lockEnabled = locked;
      _unlocked = !locked;
    });
    if (locked) _authenticate();
  }

  Future<void> _authenticate() async {
    if (_authInProgress) return;
    _authInProgress = true;
    try {
      final supported = await _auth.canCheckBiometrics || await _auth.isDeviceSupported();
      if (!supported) {
        if (mounted) setState(() => _unlocked = true);
        return;
      }
      final ok = await _auth.authenticate(
        localizedReason: 'Buka kunci untuk mengakses dokumen SmartScanner',
        options: const AuthenticationOptions(stickyAuth: true, biometricOnly: false),
      );
      if (ok && mounted) setState(() => _unlocked = true);
    } catch (e) {
      print('Biometric error: $e');
      if (mounted) setState(() => _unlocked = true);
    } finally {
      _authInProgress = false;
    }
  }

  Future<void> _toggleLock() async {
    try {
      final supported = await _auth.canCheckBiometrics || await _auth.isDeviceSupported();
      if (!supported) {
        _snack('Perangkat tidak mendukung kunci biometrik / PIN.', error: true);
        return;
      }
      final ok = await _auth.authenticate(
        localizedReason: _lockEnabled ? 'Konfirmasi untuk mematikan kunci aplikasi' : 'Konfirmasi untuk mengaktifkan kunci aplikasi',
        options: const AuthenticationOptions(stickyAuth: true, biometricOnly: false),
      );
      if (!ok) return;
      final prefs = await SharedPreferences.getInstance();
      final v = !_lockEnabled;
      await prefs.setBool('biometric_lock', v);
      if (!mounted) return;
      setState(() {
        _lockEnabled = v;
        _unlocked = true;
      });
      _snack(v ? 'Kunci aplikasi aktif' : 'Kunci aplikasi nonaktif');
    } catch (e) {
      print('Toggle lock error: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Don't lock while the camera / gallery / auth dialog is open
    if (state == AppLifecycleState.paused && _lockEnabled && !_authInProgress && !_externalActivity) {
      setState(() => _unlocked = false);
    } else if (state == AppLifecycleState.resumed && _lockEnabled && !_unlocked) {
      _authenticate();
    }
  }

  bool _externalActivity = false;

  Future<T> _external<T>(Future<T> Function() f) async {
    _externalActivity = true;
    try {
      return await f();
    } finally {
      _externalActivity = false;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // DATA
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _loadHistory() async {
    setState(() => _loading = true);
    try {
      final docs = await DocumentService.loadHistory();
      if (!mounted) return;
      setState(() {
        _all = docs;
        _selected.removeWhere((id) => !docs.any((d) => d.id == id));
      });
      _applySearch();
    } catch (e) {
      print('Error loading history: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _applySearch() {
    final q = _search.text.toLowerCase().trim();
    setState(() {
      _shown = q.isEmpty ? _all : _all.where((d) => d.name.toLowerCase().contains(q)).toList();
    });
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: error ? Colors.redAccent : _teal),
    );
  }

  String _stampName(String prefix) => '${prefix}_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}';

  Future<String> _defaultFilter() async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getString('default_filter') ?? 'Magic Color';
    } catch (_) {
      return 'Magic Color';
    }
  }

  Future<void> _openDoc(ScannedDocument doc) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => PreviewScreen(project: doc)));
    _loadHistory();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // SCAN FLOWS
  // ══════════════════════════════════════════════════════════════════════════

  void _showScanOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        Widget option(IconData icon, String title, String sub, VoidCallback onTap) => ListTile(
              leading: CircleAvatar(backgroundColor: const Color(0xFF0F766E), child: Icon(icon, color: Colors.white)),
              title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(sub, style: const TextStyle(color: Colors.white60, fontSize: 12)),
              onTap: () {
                Navigator.pop(context);
                onTap();
              },
            );
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('Pindai Dokumen', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              option(Icons.camera_alt, 'Kamera — satu halaman', 'Foto, potong otomatis, lalu pilih filter', _scanSingle),
              option(Icons.burst_mode, 'Kamera — banyak halaman', 'Foto beberapa halaman berturut-turut jadi satu dokumen', _scanBatch),
              option(Icons.credit_card, 'KTP / Kartu identitas', 'Depan & belakang digabung dalam satu lembar A4', _scanIdCard),
              option(Icons.photo_library, 'Impor dari galeri', 'Pilih satu atau banyak foto sekaligus', _importGallery),
              const SizedBox(height: 8),
            ]),
          ),
        );
      },
    );
  }

  Future<String?> _crop(String imagePath, String title) {
    return Navigator.push<String?>(
      context,
      MaterialPageRoute(builder: (_) => CropScreen(imagePath: imagePath, defaultTitle: title)),
    );
  }

  Future<String?> _chooseFilter(String croppedPath, {String title = 'Pilih Filter'}) async {
    final def = await _defaultFilter();
    if (!mounted) return null;
    return Navigator.push<String?>(
      context,
      MaterialPageRoute(builder: (_) => FilterScreen(imagePath: croppedPath, initialFilter: def, title: title)),
    );
  }

  /// Crops each image, lets the user choose a filter once (on the first page),
  /// then builds one document from all pages.
  Future<void> _buildDocumentFrom(List<String> imagePaths, String namePrefix) async {
    final cropped = <String>[];
    for (int i = 0; i < imagePaths.length; i++) {
      if (!mounted) return;
      final title = imagePaths.length > 1 ? 'Potong Halaman ${i + 1} / ${imagePaths.length}' : 'Potong Dokumen';
      final c = await _crop(imagePaths[i], title);
      if (c == null) {
        if (!mounted) return;
        if (imagePaths.length == 1) return;
        final choice = await showDialog<String>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: const Text('Lewati halaman ini?'),
            content: const Text('Batalkan semua, atau lewati halaman ini saja?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, 'cancel'), child: const Text('Batalkan semua', style: TextStyle(color: Colors.redAccent))),
              ElevatedButton(onPressed: () => Navigator.pop(context, 'skip'), child: const Text('Lewati')),
            ],
          ),
        );
        if (choice == 'cancel') return;
        continue;
      }
      cropped.add(c);
    }
    if (cropped.isEmpty || !mounted) return;

    final filter = await _chooseFilter(
      cropped.first,
      title: cropped.length > 1 ? 'Filter (untuk ${cropped.length} halaman)' : 'Pilih Filter',
    );
    if (filter == null || !mounted) return;

    setState(() {
      _loading = true;
      _loadingText = 'Menyimpan dokumen...';
    });
    try {
      var doc = await DocumentService.createProject(
        tempCroppedPath: cropped.first,
        name: _stampName(namePrefix),
        filterName: filter,
      );
      for (int i = 1; i < cropped.length; i++) {
        if (mounted) setState(() => _loadingText = 'Menyimpan halaman ${i + 1} dari ${cropped.length}...');
        doc = await DocumentService.addPageToProject(project: doc, tempCroppedPath: cropped[i], filterName: filter);
      }
      if (mounted) {
        setState(() => _loading = false);
        await _openDoc(doc);
      }
    } catch (e) {
      _snack('Gagal menyimpan dokumen: $e', error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _scanSingle() async {
    try {
      final photo = await _external(() => ImagePicker().pickImage(source: ImageSource.camera));
      if (photo == null) return;
      await _buildDocumentFrom([photo.path], 'Scan');
    } catch (e) {
      _snack('Gagal membuka kamera: $e', error: true);
    }
  }

  Future<void> _scanBatch() async {
    try {
      final paths = <String>[];
      while (mounted) {
        final photo = await _external(() => ImagePicker().pickImage(source: ImageSource.camera));
        if (photo == null) break;
        paths.add(photo.path);
        if (!mounted) return;
        final more = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: Text('${paths.length} halaman diambil'),
            content: const Text('Foto halaman berikutnya?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Selesai')),
              ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Foto lagi')),
            ],
          ),
        );
        if (more != true) break;
      }
      if (paths.isNotEmpty) await _buildDocumentFrom(paths, 'Scan');
    } catch (e) {
      _snack('Gagal memindai: $e', error: true);
    }
  }

  Future<void> _importGallery() async {
    try {
      final files = await _external(() => ImagePicker().pickMultiImage());
      if (files.isEmpty) return;
      await _buildDocumentFrom(files.map((f) => f.path).toList(), 'Impor');
    } catch (e) {
      _snack('Gagal mengimpor gambar: $e', error: true);
    }
  }

  Future<void> _scanIdCard() async {
    try {
      _snack('Foto sisi DEPAN kartu');
      final front = await _external(() => ImagePicker().pickImage(source: ImageSource.camera));
      if (front == null || !mounted) return;
      final frontCropped = await _crop(front.path, 'Potong Sisi Depan');
      if (frontCropped == null || !mounted) return;

      _snack('Sekarang foto sisi BELAKANG kartu');
      final back = await _external(() => ImagePicker().pickImage(source: ImageSource.camera));
      if (back == null || !mounted) return;
      final backCropped = await _crop(back.path, 'Potong Sisi Belakang');
      if (backCropped == null || !mounted) return;

      setState(() {
        _loading = true;
        _loadingText = 'Menggabungkan kartu...';
      });
      final stitched = await compute(_stitchInBg, {
        'front': await File(frontCropped).readAsBytes(),
        'back': await File(backCropped).readAsBytes(),
      });
      if (stitched == null) throw Exception('Gagal menggabungkan gambar.');
      final tmp = await getTemporaryDirectory();
      final stitchedPath = path.join(tmp.path, 'ktp_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await File(stitchedPath).writeAsBytes(stitched);
      await File('${stitchedPath}_preview.jpg').writeAsBytes(
        await compute(_previewInBg, stitched),
      );
      if (mounted) setState(() => _loading = false);

      final filter = await _chooseFilter(stitchedPath);
      if (filter == null || !mounted) return;
      final doc = await DocumentService.createProject(
        tempCroppedPath: stitchedPath,
        name: _stampName('KTP'),
        filterName: filter,
      );
      if (mounted) await _openDoc(doc);
    } catch (e) {
      _snack('Gagal memindai kartu: $e', error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  static Uint8List? _stitchInBg(Map<String, dynamic> p) =>
      HomographyService.stitchIdCard(p['front'] as Uint8List, p['back'] as Uint8List);

  static Uint8List _previewInBg(Uint8List bytes) => ImageFilterService.resizeForPreview(bytes, maxDimension: 1600);

  // ══════════════════════════════════════════════════════════════════════════
  // DOCUMENT ACTIONS
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _rename(ScannedDocument doc) async {
    final c = TextEditingController(text: doc.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ubah Nama'),
        content: TextField(controller: c, autofocus: true, onSubmitted: (_) => Navigator.pop(context, true)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Simpan')),
        ],
      ),
    );
    if (ok == true && c.text.trim().isNotEmpty) {
      await DocumentService.updateProject(doc.copyWith(name: c.text.trim()));
      _loadHistory();
    }
  }

  Future<void> _quickSharePdf(ScannedDocument doc) async {
    setState(() {
      _loading = true;
      _loadingText = 'Membuat PDF...';
    });
    try {
      final pages = <Uint8List>[];
      for (int i = 0; i < doc.pageCount; i++) {
        final bytes = await File(doc.displayPathAt(i)).readAsBytes();
        pages.add(await compute(ImageFilterService.reencodeJpeg, {
          'bytes': bytes,
          'quality': ExportQuality.medium.jpegQuality,
          'maxDim': ExportQuality.medium.maxDim,
        }));
      }
      final pdfPath = await DocumentService.exportPdf(
        pagesBytes: pages,
        name: doc.name,
        pageSize: PdfPageSize.a4,
        saveToPublic: false,
      );
      if (mounted) setState(() => _loading = false);
      await DocumentService.shareFiles([pdfPath]);
    } catch (e) {
      _snack('Gagal membagikan: $e', error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<bool> _confirmDelete(int count) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(count == 1 ? 'Hapus dokumen?' : 'Hapus $count dokumen?'),
        content: const Text('File hasil scan akan dihapus permanen dari aplikasi.'),
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
    return ok == true;
  }

  Future<void> _delete(ScannedDocument doc) async {
    if (!await _confirmDelete(1)) return;
    await DocumentService.deleteDocument(doc.id);
    _snack('Dokumen dihapus');
    _loadHistory();
  }

  Future<void> _deleteSelected() async {
    if (!await _confirmDelete(_selected.length)) return;
    for (final id in List<String>.from(_selected)) {
      await DocumentService.deleteDocument(id);
    }
    _selected.clear();
    _snack('Dokumen dihapus');
    _loadHistory();
  }

  Future<void> _mergeSelected() async {
    if (_selected.length < 2) {
      _snack('Pilih minimal 2 dokumen untuk digabung.');
      return;
    }
    // Keep the order in which the user tapped them
    final docs = _selected.map((id) => _all.firstWhere((d) => d.id == id)).toList();
    final merged = await DocumentService.mergeProjects(docs, _stampName('Gabungan'));
    _selected.clear();
    _snack('${docs.length} dokumen digabung (${merged.pageCount} halaman)');
    await _loadHistory();
  }

  void _toggleSelect(ScannedDocument doc) {
    setState(() {
      if (_selected.contains(doc.id)) {
        _selected.remove(doc.id);
      } else {
        _selected.add(doc.id);
      }
    });
  }

  // ══════════════════════════════════════════════════════════════════════════
  // UI
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    if (_lockEnabled && !_unlocked) return _buildLockScreen();

    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selecting) setState(() => _selected.clear());
      },
      child: Scaffold(
        appBar: _selecting
            ? AppBar(
                leading: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _selected.clear())),
                title: Text('${_selected.length} dipilih'),
                actions: [
                  IconButton(icon: const Icon(Icons.merge_type), tooltip: 'Gabungkan', onPressed: _mergeSelected),
                  IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Hapus', onPressed: _deleteSelected),
                ],
              )
            : AppBar(
                title: const Text('SmartScanner'),
                actions: [
                  IconButton(
                    icon: Icon(_lockEnabled ? Icons.lock : Icons.lock_open, color: _lockEnabled ? _tealLight : Colors.white70),
                    tooltip: _lockEnabled ? 'Kunci aplikasi aktif' : 'Aktifkan kunci aplikasi',
                    onPressed: _toggleLock,
                  ),
                ],
              ),
        body: SafeArea(
          child: Stack(children: [
            Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: TextField(
                  controller: _search,
                  decoration: InputDecoration(
                    hintText: 'Cari dokumen...',
                    prefixIcon: const Icon(Icons.search, color: _teal),
                    suffixIcon: _search.text.isNotEmpty
                        ? IconButton(icon: const Icon(Icons.clear), onPressed: _search.clear)
                        : null,
                    filled: true,
                    fillColor: _card,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide.none),
                  ),
                ),
              ),
              if (_all.isNotEmpty && !_selecting)
                const Padding(
                  padding: EdgeInsets.only(bottom: 4),
                  child: Text('Tekan lama untuk memilih & menggabungkan dokumen',
                      style: TextStyle(fontSize: 11, color: Colors.white38)),
                ),
              Expanded(
                child: _shown.isEmpty && !_loading
                    ? _buildEmpty()
                    : RefreshIndicator(
                        onRefresh: _loadHistory,
                        color: _teal,
                        child: ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                          itemCount: _shown.length,
                          itemBuilder: (context, i) => _buildDocCard(_shown[i]),
                        ),
                      ),
              ),
            ]),
            if (_loading)
              Positioned.fill(
                child: Container(
                  color: Colors.black45,
                  child: Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const CircularProgressIndicator(color: _teal),
                      if (_loadingText.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(_loadingText),
                      ],
                    ]),
                  ),
                ),
              ),
          ]),
        ),
        floatingActionButton: _selecting
            ? null
            : FloatingActionButton.extended(
                onPressed: _loading ? null : _showScanOptions,
                icon: const Icon(Icons.document_scanner),
                label: const Text('Pindai', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
        floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      ),
    );
  }

  Widget _buildLockScreen() {
    return Scaffold(
      backgroundColor: _bg,
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.lock, color: _tealLight, size: 64),
          const SizedBox(height: 20),
          const Text('SmartScanner Terkunci', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 28),
          ElevatedButton.icon(
            onPressed: _authenticate,
            icon: const Icon(Icons.fingerprint),
            label: const Text('Buka Kunci'),
          ),
        ]),
      ),
    );
  }

  Widget _buildEmpty() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 60),
        const Icon(Icons.document_scanner, size: 80, color: _teal),
        const SizedBox(height: 20),
        Text(
          _search.text.isEmpty ? 'Belum ada dokumen' : 'Dokumen tidak ditemukan',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 10),
        if (_search.text.isEmpty)
          const Text(
            'Ketuk "Pindai" untuk memindai dokumen dengan kamera atau impor dari galeri.\nSemua proses berjalan offline di HP Anda.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF94A3B8), height: 1.5),
          ),
      ],
    );
  }

  Widget _buildDocCard(ScannedDocument doc) {
    final selected = _selected.contains(doc.id);
    final order = _selected.indexOf(doc.id);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: selected ? _tealLight : Colors.transparent, width: 2),
      ),
      child: InkWell(
        onTap: () => _selecting ? _toggleSelect(doc) : _openDoc(doc),
        onLongPress: () => _toggleSelect(doc),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Stack(children: [
              Container(
                width: 60,
                height: 78,
                decoration: BoxDecoration(
                  color: _bg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF334155)),
                ),
                clipBehavior: Clip.antiAlias,
                child: Image.file(
                  File(doc.displayPathAt(0)),
                  fit: BoxFit.cover,
                  cacheWidth: 120,
                  errorBuilder: (context, error, stack) => const Icon(Icons.broken_image, color: Colors.grey),
                ),
              ),
              if (selected)
                Positioned(
                  right: 2,
                  top: 2,
                  child: CircleAvatar(
                    radius: 11,
                    backgroundColor: _teal,
                    child: Text('${order + 1}', style: const TextStyle(fontSize: 11, color: Colors.white)),
                  ),
                ),
            ]),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(doc.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  _badge('${doc.pageCount} hal'),
                  _badge(ImageFilterService.labelOf(doc.activeFilters.first)),
                  Text(_formatSize(doc.fileSize), style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
                ]),
                const SizedBox(height: 6),
                Text(DateFormat('dd MMM yyyy, HH:mm').format(doc.createdTime),
                    style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
              ]),
            ),
            if (!_selecting)
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: Color(0xFF94A3B8)),
                onSelected: (v) {
                  switch (v) {
                    case 'open':
                      _openDoc(doc);
                    case 'share':
                      _quickSharePdf(doc);
                    case 'rename':
                      _rename(doc);
                    case 'select':
                      _toggleSelect(doc);
                    case 'delete':
                      _delete(doc);
                  }
                },
                itemBuilder: (_) => [
                  _menu('open', Icons.edit_note, 'Buka & edit'),
                  _menu('share', Icons.share, 'Bagikan sebagai PDF'),
                  _menu('rename', Icons.drive_file_rename_outline, 'Ganti nama'),
                  _menu('select', Icons.check_box_outlined, 'Pilih (untuk gabung)'),
                  _menu('delete', Icons.delete, 'Hapus', color: Colors.redAccent),
                ],
              ),
          ]),
        ),
      ),
    );
  }

  PopupMenuItem<String> _menu(String v, IconData icon, String label, {Color color = _teal}) => PopupMenuItem(
        value: v,
        child: Row(children: [Icon(icon, size: 18, color: color), const SizedBox(width: 10), Text(label)]),
      );

  Widget _badge(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: _teal.withAlpha(51), borderRadius: BorderRadius.circular(4)),
        child: Text(text, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: _tealLight)),
      );

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

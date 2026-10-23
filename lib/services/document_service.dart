// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'package:open_file/open_file.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/scanned_document.dart';
import 'homography_service.dart';
import 'image_filter_service.dart';
import 'ocr_service.dart';

/// PDF page size options.
enum PdfPageSize { auto, a4, letter, legal }

extension PdfPageSizeLabel on PdfPageSize {
  String get label => switch (this) {
        PdfPageSize.auto => 'Otomatis (ikuti dokumen)',
        PdfPageSize.a4 => 'A4',
        PdfPageSize.letter => 'Letter',
        PdfPageSize.legal => 'Legal / F4',
      };
}

/// Image compression for exports.
enum ExportQuality { high, medium, small }

extension ExportQualityValues on ExportQuality {
  int get jpegQuality => switch (this) {
        ExportQuality.high => 92,
        ExportQuality.medium => 80,
        ExportQuality.small => 62,
      };
  int get maxDim => switch (this) {
        ExportQuality.high => 3500,
        ExportQuality.medium => 2200,
        ExportQuality.small => 1500,
      };
  String get label => switch (this) {
        ExportQuality.high => 'Tinggi',
        ExportQuality.medium => 'Sedang',
        ExportQuality.small => 'Kecil (hemat ukuran)',
      };
}

class DocumentService {
  static const String _prefKey = 'scanned_documents_history_projects_v2';

  // ══════════════════════════════════════════════════════════════════════════
  // FILES & DIRECTORIES
  // ══════════════════════════════════════════════════════════════════════════

  static Future<Directory> _dir(String sub) async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory(path.join(base.path, 'scans', sub));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static String _safeName(String name) {
    final s = name.replaceAll(RegExp(r'[^\w\s\-]'), '').trim();
    return s.isEmpty ? 'SmartScanner' : s;
  }

  /// Creates a filtered display image for [rawFilePath] and returns its path.
  static Future<String> saveDisplayImage({
    required String rawFilePath,
    required String filterName,
    required String displayFileName,
    String? previewFilePath,
  }) async {
    final displayDir = await _dir('display');
    final displayPath = path.join(displayDir.path, displayFileName);
    final ok = await compute(ImageFilterService.applyFilterToFile, {
      'input': rawFilePath,
      'output': displayPath,
      'filter': filterName,
      'quality': 92,
    });
    if (!ok) await File(rawFilePath).copy(displayPath);
    return displayPath;
  }

  static Future<int> _totalSize(Iterable<String> paths) async {
    int total = 0;
    for (final p in paths.toSet()) {
      final f = File(p);
      if (await f.exists()) total += await f.length();
    }
    return total;
  }

  static Future<void> _deleteQuietly(Iterable<String?> paths) async {
    for (final p in paths) {
      if (p == null) continue;
      try {
        final f = File(p);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  static String _previewOf(String rawPath) {
    final dir = path.dirname(rawPath);
    return path.join(dir, path.basename(rawPath).replaceFirst('raw_', 'preview_'));
  }

  // ══════════════════════════════════════════════════════════════════════════
  // HISTORY
  // ══════════════════════════════════════════════════════════════════════════

  static Future<List<ScannedDocument>> loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final String? jsonString = prefs.getString(_prefKey);
    if (jsonString == null) return [];

    try {
      final decoded = jsonDecode(jsonString) as List<dynamic>;
      final docs = decoded.map((e) => ScannedDocument.fromJson(e as Map<String, dynamic>)).toList();

      // Drop pages whose raw image disappeared, keeping all lists aligned.
      final List<ScannedDocument> existing = [];
      bool changed = false;
      for (final doc in docs) {
        final raws = <String>[], displays = <String>[], filters = <String>[];
        for (int i = 0; i < doc.filePaths.length; i++) {
          if (!await File(doc.filePaths[i]).exists()) {
            changed = true;
            continue;
          }
          raws.add(doc.filePaths[i]);
          final disp = doc.displayPathAt(i);
          displays.add(await File(disp).exists() ? disp : doc.filePaths[i]);
          filters.add(i < doc.activeFilters.length ? doc.activeFilters[i] : 'Original');
        }
        if (raws.isEmpty) {
          changed = true;
          continue;
        }
        existing.add(doc.copyWith(filePaths: raws, displayFilePaths: displays, activeFilters: filters));
      }
      if (changed) await _saveHistoryList(existing);
      existing.sort((a, b) => b.createdTime.compareTo(a.createdTime));
      return existing;
    } catch (e) {
      print('Error parsing project history: $e');
      return [];
    }
  }

  static Future<void> _saveHistoryList(List<ScannedDocument> docs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, jsonEncode(docs.map((d) => d.toJson()).toList()));
  }

  static Future<void> updateProject(ScannedDocument updated) async {
    final history = await loadHistory();
    final index = history.indexWhere((doc) => doc.id == updated.id);
    if (index != -1) {
      history[index] = updated;
    } else {
      history.add(updated);
    }
    await _saveHistoryList(history);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // PROJECT / PAGE OPERATIONS
  // ══════════════════════════════════════════════════════════════════════════

  /// Copies a cropped temp image into app storage and renders its display image.
  static Future<(String raw, String display)> _storePage(String tempCroppedPath, String filterName, int index) async {
    final rawDir = await _dir('raw');
    final ts = DateTime.now().microsecondsSinceEpoch;
    final rawPath = path.join(rawDir.path, 'raw_${ts}_$index.jpg');
    await File(tempCroppedPath).copy(rawPath);

    final tempPreview = File('${tempCroppedPath}_preview.jpg');
    final previewPath = path.join(rawDir.path, 'preview_${ts}_$index.jpg');
    if (await tempPreview.exists()) await tempPreview.copy(previewPath);

    final displayPath = await saveDisplayImage(
      rawFilePath: rawPath,
      filterName: filterName,
      displayFileName: 'display_${ts}_$index.jpg',
    );
    return (rawPath, displayPath);
  }

  static Future<ScannedDocument> createProject({
    required String tempCroppedPath,
    required String name,
    String filterName = 'Original',
  }) async {
    final (rawPath, displayPath) = await _storePage(tempCroppedPath, filterName, 0);
    final ts = DateTime.now().microsecondsSinceEpoch;
    final newDoc = ScannedDocument(
      id: ts.toString(),
      name: name,
      filePaths: [rawPath],
      displayFilePaths: [displayPath],
      fileType: 'image',
      activeFilters: [filterName],
      createdTime: DateTime.now(),
      fileSize: await _totalSize([rawPath, displayPath]),
    );
    final history = await loadHistory();
    history.add(newDoc);
    await _saveHistoryList(history);
    return newDoc;
  }

  static Future<ScannedDocument> addPageToProject({
    required ScannedDocument project,
    required String tempCroppedPath,
    String filterName = 'Original',
  }) async {
    final (rawPath, displayPath) = await _storePage(tempCroppedPath, filterName, project.filePaths.length);
    final raws = [...project.filePaths, rawPath];
    final displays = [...project.displayFilePaths, displayPath];
    final updated = project.copyWith(
      filePaths: raws,
      displayFilePaths: displays,
      activeFilters: [...project.activeFilters, filterName],
      fileSize: await _totalSize([...raws, ...displays]),
    );
    await updateProject(updated);
    return updated;
  }

  static Future<ScannedDocument> replacePageInProject({
    required ScannedDocument project,
    required int pageIndex,
    required String tempCroppedPath,
    String filterName = 'Original',
  }) async {
    final oldRaw = project.filePaths[pageIndex];
    final oldDisplay = project.displayPathAt(pageIndex);
    final (rawPath, displayPath) = await _storePage(tempCroppedPath, filterName, pageIndex);
    await _deleteQuietly([oldRaw, if (oldDisplay != oldRaw) oldDisplay, _previewOf(oldRaw)]);

    final raws = List<String>.from(project.filePaths)..[pageIndex] = rawPath;
    final displays = List<String>.from(project.displayFilePaths)..[pageIndex] = displayPath;
    final filters = List<String>.from(project.activeFilters)..[pageIndex] = filterName;
    final updated = project.copyWith(
      filePaths: raws,
      displayFilePaths: displays,
      activeFilters: filters,
      fileSize: await _totalSize([...raws, ...displays]),
    );
    await updateProject(updated);
    return updated;
  }

  /// Changes the filter of one page (re-renders its display image).
  static Future<ScannedDocument> setPageFilter({
    required ScannedDocument project,
    required int pageIndex,
    required String filterName,
  }) async {
    final raw = project.filePaths[pageIndex];
    final oldDisplay = project.displayPathAt(pageIndex);
    final ts = DateTime.now().microsecondsSinceEpoch;
    final newDisplay = await saveDisplayImage(
      rawFilePath: raw,
      filterName: filterName,
      displayFileName: 'display_${ts}_$pageIndex.jpg',
    );
    if (oldDisplay != raw) await _deleteQuietly([oldDisplay]);
    final displays = List<String>.from(project.displayFilePaths)..[pageIndex] = newDisplay;
    final filters = List<String>.from(project.activeFilters)..[pageIndex] = filterName;
    final updated = project.copyWith(
      displayFilePaths: displays,
      activeFilters: filters,
      fileSize: await _totalSize([...project.filePaths, ...displays]),
    );
    await updateProject(updated);
    return updated;
  }

  /// Applies one filter to every page.
  static Future<ScannedDocument> setFilterForAllPages({
    required ScannedDocument project,
    required String filterName,
    void Function(int done, int total)? onProgress,
  }) async {
    var doc = project;
    for (int i = 0; i < doc.pageCount; i++) {
      if (doc.activeFilters[i] != filterName) {
        doc = await setPageFilter(project: doc, pageIndex: i, filterName: filterName);
      }
      onProgress?.call(i + 1, doc.pageCount);
    }
    return doc;
  }

  /// Rotates one page by 90° clockwise. New file names are used so Flutter's
  /// image cache never shows the old orientation.
  static Future<ScannedDocument> rotatePage({
    required ScannedDocument project,
    required int pageIndex,
    int angle = 90,
  }) async {
    final ts = DateTime.now().microsecondsSinceEpoch;
    final rawDir = await _dir('raw');
    final displayDir = await _dir('display');
    final oldRaw = project.filePaths[pageIndex];
    final oldDisplay = project.displayPathAt(pageIndex);
    final oldPreview = _previewOf(oldRaw);

    final newRaw = path.join(rawDir.path, 'raw_${ts}_$pageIndex.jpg');
    final newPreview = path.join(rawDir.path, 'preview_${ts}_$pageIndex.jpg');
    final newDisplay = oldDisplay == oldRaw ? newRaw : path.join(displayDir.path, 'display_${ts}_$pageIndex.jpg');

    await File(oldRaw).copy(newRaw);
    final toRotate = [newRaw];
    if (await File(oldPreview).exists()) {
      await File(oldPreview).copy(newPreview);
      toRotate.add(newPreview);
    }
    if (newDisplay != newRaw && await File(oldDisplay).exists()) {
      await File(oldDisplay).copy(newDisplay);
      toRotate.add(newDisplay);
    }
    await compute(HomographyService.rotateFilesInPlace, {'paths': toRotate, 'angle': angle});
    await _deleteQuietly([oldRaw, oldPreview, if (oldDisplay != oldRaw) oldDisplay]);

    final raws = List<String>.from(project.filePaths)..[pageIndex] = newRaw;
    final displays = List<String>.from(project.displayFilePaths)
      ..[pageIndex] = (newDisplay != newRaw && await File(newDisplay).exists()) ? newDisplay : newRaw;
    final updated = project.copyWith(filePaths: raws, displayFilePaths: displays);
    await updateProject(updated);
    return updated;
  }

  static Future<ScannedDocument?> deletePageFromProject({
    required ScannedDocument project,
    required int pageIndex,
  }) async {
    final oldRaw = project.filePaths[pageIndex];
    final oldDisplay = project.displayPathAt(pageIndex);
    await _deleteQuietly([oldRaw, oldDisplay, _previewOf(oldRaw)]);

    final raws = List<String>.from(project.filePaths)..removeAt(pageIndex);
    final displays = List<String>.from(project.displayFilePaths)..removeAt(pageIndex);
    final filters = List<String>.from(project.activeFilters)..removeAt(pageIndex);
    if (raws.isEmpty) {
      await deleteDocument(project.id);
      return null;
    }
    final updated = project.copyWith(
      filePaths: raws,
      displayFilePaths: displays,
      activeFilters: filters,
      fileSize: await _totalSize([...raws, ...displays]),
    );
    await updateProject(updated);
    return updated;
  }

  static Future<List<ScannedDocument>> deleteDocument(String id) async {
    final docs = await loadHistory();
    final index = docs.indexWhere((doc) => doc.id == id);
    if (index != -1) {
      final doc = docs[index];
      await _deleteQuietly([
        ...doc.filePaths,
        ...doc.displayFilePaths,
        ...doc.filePaths.map(_previewOf),
      ]);
      docs.removeAt(index);
      await _saveHistoryList(docs);
    }
    return docs;
  }

  /// Merges several documents (in the given order) into a new one.
  /// The source documents are removed from the list; their files are reused.
  static Future<ScannedDocument> mergeProjects(List<ScannedDocument> sources, String name) async {
    final raws = <String>[], displays = <String>[], filters = <String>[];
    for (final d in sources) {
      raws.addAll(d.filePaths);
      for (int i = 0; i < d.pageCount; i++) {
        displays.add(d.displayPathAt(i));
      }
      filters.addAll(d.activeFilters);
    }
    final merged = ScannedDocument(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      filePaths: raws,
      displayFilePaths: displays,
      fileType: 'image',
      activeFilters: filters,
      createdTime: DateTime.now(),
      fileSize: await _totalSize([...raws, ...displays]),
    );
    final ids = sources.map((d) => d.id).toSet();
    final history = (await loadHistory()).where((d) => !ids.contains(d.id)).toList()..add(merged);
    await _saveHistoryList(history);
    return merged;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // PUBLIC SAVE LOCATION
  // ══════════════════════════════════════════════════════════════════════════

  static String? _lastSaveDirDescription;

  /// Writes [bytes] to Download/SmartScanner (Android) and returns the path.
  /// Falls back to the app's own folder if the public folder is not writable.
  static Future<String> _writePublic(String fileName, List<int> bytes) async {
    if (Platform.isAndroid) {
      final dir = Directory('/storage/emulated/0/Download/SmartScanner');
      for (int attempt = 0; attempt < 2; attempt++) {
        try {
          if (!await dir.exists()) await dir.create(recursive: true);
          final f = File(path.join(dir.path, fileName));
          await f.writeAsBytes(bytes, flush: true);
          _lastSaveDirDescription = 'Penyimpanan Internal > Download > SmartScanner';
          return f.path;
        } catch (e) {
          print('Public write failed (attempt $attempt): $e');
          if (attempt == 0) {
            // Android 9/10 need the legacy storage permission
            try {
              await Permission.storage.request();
            } catch (_) {}
          }
        }
      }
      final ext = await getExternalStorageDirectory();
      final fallback = Directory(path.join((ext ?? await getApplicationDocumentsDirectory()).path, 'SmartScanner'));
      if (!await fallback.exists()) await fallback.create(recursive: true);
      final f = File(path.join(fallback.path, fileName));
      await f.writeAsBytes(bytes, flush: true);
      _lastSaveDirDescription = 'Android > data > (folder aplikasi) > SmartScanner';
      return f.path;
    }
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(path.join(docs.path, 'SmartScanner'));
    if (!await dir.exists()) await dir.create(recursive: true);
    final f = File(path.join(dir.path, fileName));
    await f.writeAsBytes(bytes, flush: true);
    _lastSaveDirDescription = 'Files > SmartScanner';
    return f.path;
  }

  static String getPublicDirectoryDescription() =>
      _lastSaveDirDescription ??
      (Platform.isAndroid ? 'Penyimpanan Internal > Download > SmartScanner' : 'Files > SmartScanner');

  static String _stamp() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}${two(n.month)}${two(n.day)}_${two(n.hour)}${two(n.minute)}${two(n.second)}';
  }

  // ══════════════════════════════════════════════════════════════════════════
  // EXPORTS
  // ══════════════════════════════════════════════════════════════════════════

  /// Saves pages to the gallery and to Download/SmartScanner. Returns all paths.
  static Future<List<String>> exportImages({
    required List<Uint8List> pagesBytes,
    required String name,
  }) async {
    final safe = _safeName(name);
    final stamp = _stamp();
    final out = <String>[];
    for (int i = 0; i < pagesBytes.length; i++) {
      final suffix = pagesBytes.length > 1 ? '_hal${i + 1}' : '';
      try {
        await ImageGallerySaverPlus.saveImage(pagesBytes[i], name: '${safe}_$stamp$suffix', quality: 95);
      } catch (e) {
        print('Gallery save failed: $e');
      }
      out.add(await _writePublic('${safe}_$stamp$suffix.jpg', pagesBytes[i]));
    }
    return out;
  }

  /// Builds a PDF. If [ocrPages] is given, an invisible, selectable and
  /// searchable text layer is placed exactly over the words in the image.
  static Future<String> exportPdf({
    required List<Uint8List> pagesBytes,
    required String name,
    PdfPageSize pageSize = PdfPageSize.a4,
    List<OcrPage>? ocrPages,
    bool saveToPublic = true,
  }) async {
    final pdf = pw.Document(title: name, author: 'SmartScanner', creator: 'SmartScanner');
    final helvetica = PdfFont.helvetica(pdf.document);

    for (int i = 0; i < pagesBytes.length; i++) {
      final image = pw.MemoryImage(pagesBytes[i]);
      final imgW = (image.width ?? 1000).toDouble();
      final imgH = (image.height ?? 1414).toDouble();
      final landscape = imgW > imgH;

      PdfPageFormat format = PdfPageFormat.a4;
      switch (pageSize) {
        case PdfPageSize.auto:
          const baseW = 595.28; // A4 width in points
          format = landscape
              ? PdfPageFormat(841.89, 841.89 * imgH / imgW)
              : PdfPageFormat(baseW, baseW * imgH / imgW);
        case PdfPageSize.a4:
          format = landscape ? PdfPageFormat.a4.landscape : PdfPageFormat.a4;
        case PdfPageSize.letter:
          format = landscape ? PdfPageFormat.letter.landscape : PdfPageFormat.letter;
        case PdfPageSize.legal:
          // F4 / Folio (215 x 330 mm), common in Indonesia
          const f4 = PdfPageFormat(215 * PdfPageFormat.mm, 330 * PdfPageFormat.mm);
          format = landscape ? f4.landscape : f4;
      }

      final pageW = format.width, pageH = format.height;
      final margin = pageSize == PdfPageSize.auto ? 0.0 : 12.0;
      final k = [(pageW - 2 * margin) / imgW, (pageH - 2 * margin) / imgH].reduce((a, b) => a < b ? a : b);
      final drawW = imgW * k, drawH = imgH * k;
      final offX = (pageW - drawW) / 2, offY = (pageH - drawH) / 2;
      final ocr = (ocrPages != null && i < ocrPages.length) ? ocrPages[i] : null;

      pdf.addPage(
        pw.Page(
          pageFormat: format,
          margin: pw.EdgeInsets.zero,
          build: (context) => pw.SizedBox(
            width: pageW,
            height: pageH,
            child: pw.Stack(
              children: [
                pw.Positioned(
                  left: offX,
                  top: offY,
                  child: pw.Image(image, width: drawW, height: drawH, fit: pw.BoxFit.fill),
                ),
                if (ocr != null && ocr.lines.isNotEmpty)
                  pw.Positioned(
                    left: 0,
                    top: 0,
                    child: pw.CustomPaint(
                      size: PdfPoint(pageW, pageH),
                      painter: (PdfGraphics canvas, PdfPoint size) {
                        for (final line in ocr.lines) {
                          final text = _latin1Safe(line.text);
                          if (text.trim().isEmpty) continue;
                          final fontSize = (line.height * k * 0.85).clamp(2.0, 200.0);
                          final metrics = helvetica.stringMetrics(text);
                          final natural = metrics.width * fontSize;
                          if (natural <= 0) continue;
                          final hScale = (line.width * k) / natural;
                          final x = offX + line.left * k;
                          // PDF y axis points up; baseline slightly above the box bottom
                          final y = size.y - (offY + (line.top + line.height) * k) + fontSize * 0.2;
                          canvas.drawString(
                            helvetica, fontSize, text, x, y,
                            scale: hScale,
                            mode: PdfTextRenderingMode.invisible,
                          );
                        }
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    final bytes = await pdf.save();
    final fileName = '${_safeName(name)}_${_stamp()}.pdf';
    if (saveToPublic) return _writePublic(fileName, bytes);
    final tmp = await getTemporaryDirectory();
    final f = File(path.join(tmp.path, fileName));
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  /// Helvetica (built into every PDF reader) only covers Latin-1.
  static String _latin1Safe(String s) {
    final codes = s.runes.map((r) => (r >= 32 && r <= 255) ? r : (r == 9 ? 32 : 63));
    return String.fromCharCodes(codes);
  }

  static String _xmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      // remove characters that are illegal in XML 1.0
      .replaceAll(RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F]'), '');

  /// Creates a real Word document (one paragraph per OCR text block, a page
  /// break between scanned pages). Pure Dart, offline.
  static Future<String> exportDocx({
    required List<OcrPage> pages,
    required String name,
  }) async {
    final body = StringBuffer();
    for (int p = 0; p < pages.length; p++) {
      final paragraphs = pages[p].paragraphs.isNotEmpty
          ? pages[p].paragraphs
          : (pages[p].text.trim().isEmpty ? ['(Halaman ${p + 1}: tidak ada teks terdeteksi)'] : [pages[p].text]);
      for (final para in paragraphs) {
        final runs = para
            .split('\n')
            .map((line) => '<w:t xml:space="preserve">${_xmlEscape(line)}</w:t>')
            .join('<w:br/>');
        body.write('<w:p><w:r>$runs</w:r></w:p>');
      }
      if (p < pages.length - 1) {
        body.write('<w:p><w:r><w:br w:type="page"/></w:r></w:p>');
      }
    }

    const contentTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        '</Types>';
    const rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        '</Relationships>';
    final documentXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        '<w:body>$body'
        '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
        '<w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" w:header="708" w:footer="708" w:gutter="0"/>'
        '</w:sectPr></w:body></w:document>';

    final archive = Archive();
    void add(String name, String content) {
      final data = utf8.encode(content);
      archive.addFile(ArchiveFile(name, data.length, data));
    }

    add('[Content_Types].xml', contentTypes);
    add('_rels/.rels', rels);
    add('word/document.xml', documentXml);

    final zipped = ZipEncoder().encode(archive);
    if (zipped == null) throw Exception('Gagal mengemas berkas Word.');
    return _writePublic('${_safeName(name)}_${_stamp()}.docx', zipped);
  }

  static Future<String> exportTxt({
    required List<OcrPage> pages,
    required String name,
  }) async {
    final buf = StringBuffer();
    for (int i = 0; i < pages.length; i++) {
      if (pages.length > 1) buf.writeln('===== Halaman ${i + 1} =====');
      buf.writeln(pages[i].text);
      buf.writeln();
    }
    return _writePublic('${_safeName(name)}_${_stamp()}.txt', utf8.encode(buf.toString()));
  }

  // ══════════════════════════════════════════════════════════════════════════
  // OPEN & SHARE
  // ══════════════════════════════════════════════════════════════════════════

  static Future<String?> openDocument(String filePath) async {
    try {
      final result = await OpenFile.open(filePath);
      if (result.type != ResultType.done) return result.message;
      return null;
    } catch (e) {
      print('Error opening file: $e');
      return '$e';
    }
  }

  static Future<void> shareFiles(List<String> paths, {String? text}) async {
    await SharePlus.instance.share(ShareParams(
      files: paths.map((p) => XFile(p)).toList(),
      text: text,
    ));
  }

  static Future<void> shareText(String text) async {
    await SharePlus.instance.share(ShareParams(text: text));
  }
}

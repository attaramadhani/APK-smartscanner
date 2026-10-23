import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/image_filter_service.dart';

class FilterScreen extends StatefulWidget {
  final String imagePath;
  final String initialFilter;
  final String title;

  const FilterScreen({
    super.key,
    required this.imagePath,
    required this.initialFilter,
    this.title = 'Pilih Filter',
  });

  @override
  State<FilterScreen> createState() => _FilterScreenState();
}

class _FilterScreenState extends State<FilterScreen> {
  bool _isLoading = true;
  bool _isProcessingFilter = false;
  
  late Uint8List _previewBytes; // 1200px downscaled image for fast filtering
  Uint8List? _filteredPreviewBytes; // Current filtered preview bytes
  
  String _selectedFilter = 'Original';
  
  // Thumbnail cache for the bottom list
  final Map<String, Uint8List> _filterThumbnails = {};
  
  final List<Map<String, String>> _filtersList = ImageFilterService.filterIds
      .map((id) => {'id': id, 'name': ImageFilterService.labelOf(id)})
      .toList();

  @override
  void initState() {
    super.initState();
    _selectedFilter = ImageFilterService.filterIds.contains(widget.initialFilter)
        ? widget.initialFilter
        : 'Original';
    _loadAndPrepareImage();
  }

  Future<void> _loadAndPrepareImage() async {
    try {
      // Look for a pre-generated cropped preview file first
      final String previewFilePath = widget.imagePath.contains('_preview.jpg') || widget.imagePath.contains('preview_')
          ? widget.imagePath
          : '${widget.imagePath}_preview.jpg';

      Uint8List previewBytes;
      if (await File(previewFilePath).exists()) {
        previewBytes = await File(previewFilePath).readAsBytes();
      } else {
        // Fallback to raw file loading and downscaling
        final fileBytes = await File(widget.imagePath).readAsBytes();
        previewBytes = await compute(_resizeImageBg, {
          'bytes': fileBytes,
          'dim': 1600,
        });
      }

      // Generate 90px tiny thumbnail using native C++ engine (takes <1ms)
      final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(previewBytes);
      final ui.ImageDescriptor descriptor = await ui.ImageDescriptor.encoded(buffer);
      final int thumbW = 90;
      final int thumbH = (descriptor.height * (thumbW / descriptor.width)).round();

      final ui.Codec codec = await descriptor.instantiateCodec(
        targetWidth: thumbW,
        targetHeight: thumbH,
      );
      final ui.FrameInfo frame = await codec.getNextFrame();
      final byteData = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final Uint8List tinyRgbaBytes = byteData!.buffer.asUint8List();

      // Generate all 6 filter thumbnails in 1 single isolate call from raw RGBA!
      final thumbs = await compute(
        ImageFilterService.generateAllThumbnails,
        {
          'width': thumbW,
          'height': thumbH,
          'rgbaBytes': tinyRgbaBytes,
          'filters': _filtersList.map((f) => f['id']!).toList(),
        },
      );

      // Pre-apply the initial filter to the 800px preview
      final filteredPreview = _selectedFilter == 'Original'
          ? previewBytes
          : await compute(ImageFilterService.applyFilter, {
              'bytes': previewBytes,
              'filter': _selectedFilter,
              'quality': 88,
            });

      if (mounted) {
        setState(() {
          _previewBytes = previewBytes;
          _filteredPreviewBytes = filteredPreview;
          _filterThumbnails.addAll(thumbs);
          _isLoading = false;
        });
      }
    } catch (e) {
      print('Error preparing FilterScreen image: $e');
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal memuat gambar: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  static Uint8List _resizeImageBg(Map<String, dynamic> params) {
    final bytes = params['bytes'] as Uint8List;
    final dim = params['dim'] as int;
    return ImageFilterService.resizeForPreview(bytes, maxDimension: dim);
  }

  Future<void> _confirm() async {
    // Remember the last used filter as the default for the next scan
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('default_filter', _selectedFilter);
    } catch (_) {}
    if (mounted) Navigator.pop(context, _selectedFilter);
  }

  Future<void> _selectFilter(String filterId) async {
    if (_selectedFilter == filterId || _isProcessingFilter) return;

    setState(() {
      _selectedFilter = filterId;
      _isProcessingFilter = true;
    });

    try {
      // 'Original' filter needs no compute — just show the unfiltered preview bytes
      final Uint8List result = filterId == 'Original'
          ? _previewBytes
          : await compute(ImageFilterService.applyFilter, {
              'bytes': _previewBytes,
              'filter': filterId,
              'quality': 88, // crisp JPEG for filter preview
            });

      if (mounted) {
        setState(() {
          _filteredPreviewBytes = result;
          _isProcessingFilter = false;
        });
      }
    } catch (e) {
      print('Error applying filter preview: $e');
      if (mounted) {
        setState(() => _isProcessingFilter = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        title: Text(widget.title, style: const TextStyle(fontSize: 16)),
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.pop(context, null),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.check, color: Color(0xFF2DD4BF), size: 26),
            onPressed: _isLoading ? null : _confirm,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF14B8A6)),
            )
          : Column(
              children: [
                // Filtered Image Preview Area
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(16.0),
                    alignment: Alignment.center,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        if (_filteredPreviewBytes != null)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8.0),
                            child: Image.memory(
                              _filteredPreviewBytes!,
                              fit: BoxFit.contain,
                            ),
                          ),
                        if (_isProcessingFilter)
                          Container(
                            color: Colors.black38,
                            padding: const EdgeInsets.all(20),
                            child: const CircularProgressIndicator(color: Color(0xFF2DD4BF)),
                          ),
                      ],
                    ),
                  ),
                ),

                // Bottom Filters Horizontal Selector Bar
                Container(
                  color: const Color(0xFF1E293B),
                  padding: const EdgeInsets.symmetric(vertical: 12.0),
                  child: SafeArea(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          height: 90,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 16.0),
                            itemCount: _filtersList.length,
                            itemBuilder: (context, index) {
                              final filter = _filtersList[index];
                              final isSelected = _selectedFilter == filter['id'];
                              final thumbBytes = _filterThumbnails[filter['id']];

                              return GestureDetector(
                                onTap: () => _selectFilter(filter['id']!),
                                child: Container(
                                  width: 72,
                                  margin: const EdgeInsets.only(right: 12.0),
                                  child: Column(
                                    children: [
                                      // Thumbnail box
                                      Container(
                                        height: 60,
                                        width: 60,
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                            color: isSelected
                                                ? const Color(0xFF2DD4BF)
                                                : Colors.transparent,
                                            width: 2.5,
                                          ),
                                          borderRadius: BorderRadius.circular(6.0),
                                          color: const Color(0xFF0F172A),
                                        ),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(4.0),
                                          child: thumbBytes != null
                                              ? Image.memory(thumbBytes, fit: BoxFit.cover)
                                              : const Center(
                                                  child: SizedBox(
                                                    width: 12,
                                                    height: 12,
                                                    child: CircularProgressIndicator(
                                                      strokeWidth: 1.5,
                                                      color: Color(0xFF14B8A6),
                                                    ),
                                                  ),
                                                ),
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      // Text label
                                      Text(
                                        filter['name']!,
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: isSelected ? const Color(0xFF2DD4BF) : Colors.white70,
                                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

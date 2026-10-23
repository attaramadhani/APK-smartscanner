class ScannedDocument {
  final String id;
  final String name;
  final List<String> filePaths;        // Raw cropped images (full resolution, unfiltered)
  final List<String> displayFilePaths; // Filtered images (used for preview AND export)
  final String fileType;
  final List<String> activeFilters;    // Filter id per page
  final DateTime createdTime;
  final int fileSize;

  ScannedDocument({
    required this.id,
    required this.name,
    required this.filePaths,
    List<String>? displayFilePaths,
    required this.fileType,
    required this.activeFilters,
    required this.createdTime,
    required this.fileSize,
  }) : displayFilePaths = displayFilePaths ?? List<String>.from(filePaths);

  int get pageCount => filePaths.length;

  /// Path shown/exported for page [i] (falls back to the raw image).
  String displayPathAt(int i) =>
      i < displayFilePaths.length ? displayFilePaths[i] : filePaths[i];

  ScannedDocument copyWith({
    String? name,
    List<String>? filePaths,
    List<String>? displayFilePaths,
    List<String>? activeFilters,
    int? fileSize,
    DateTime? createdTime,
  }) {
    return ScannedDocument(
      id: id,
      name: name ?? this.name,
      filePaths: filePaths ?? this.filePaths,
      displayFilePaths: displayFilePaths ?? this.displayFilePaths,
      fileType: fileType,
      activeFilters: activeFilters ?? this.activeFilters,
      createdTime: createdTime ?? this.createdTime,
      fileSize: fileSize ?? this.fileSize,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'filePaths': filePaths,
      'displayFilePaths': displayFilePaths,
      'fileType': fileType,
      'activeFilters': activeFilters,
      'createdTime': createdTime.toIso8601String(),
      'fileSize': fileSize,
    };
  }

  factory ScannedDocument.fromJson(Map<String, dynamic> json) {
    List<String> paths = [];
    if (json['filePaths'] != null) {
      paths = List<String>.from(json['filePaths'] as List<dynamic>);
    } else if (json['filePath'] != null) {
      paths = [json['filePath'] as String];
    }

    List<String> displayPaths = json['displayFilePaths'] != null
        ? List<String>.from(json['displayFilePaths'] as List<dynamic>)
        : List<String>.from(paths);

    List<String> filters = [];
    if (json['activeFilters'] != null) {
      filters = List<String>.from(json['activeFilters'] as List<dynamic>);
    } else if (json['activeFilter'] != null) {
      filters = [json['activeFilter'] as String];
    }

    while (filters.length < paths.length) {
      filters.add('Original');
    }
    while (displayPaths.length < paths.length) {
      displayPaths.add(paths[displayPaths.length]);
    }
    if (filters.length > paths.length) filters = filters.sublist(0, paths.length);
    if (displayPaths.length > paths.length) displayPaths = displayPaths.sublist(0, paths.length);

    return ScannedDocument(
      id: json['id'] as String,
      name: json['name'] as String,
      filePaths: paths,
      displayFilePaths: displayPaths,
      fileType: (json['fileType'] as String?) ?? 'image',
      activeFilters: filters,
      createdTime: DateTime.parse(json['createdTime'] as String),
      fileSize: (json['fileSize'] as num?)?.toInt() ?? 0,
    );
  }
}

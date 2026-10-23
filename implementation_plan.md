# SmartScanner Implementation Plan

This plan details the design and architecture of the "SmartScanner" mobile application built with Flutter. The application runs 100% locally on the user's device and uses the camera to capture documents, detect edges, crop them, apply enhancements, and save them as Images (Gallery) or PDFs.

## User Review Required

> [!IMPORTANT]
> **Pure Dart Image Processing for Filters:**
> To guarantee 100% local, cross-platform stability without complex C++ compilation or platform-specific NDK/Cocoapod dependency conflicts, we will implement the 6 image processing filters using the pure-Dart `image` package. We will optimize the shadow-removal and enhancement algorithms by downscaling the background estimation map, making the filter application very fast (under 1 second).

> [!NOTE]
> **Saving PDFs on Android & iOS:**
> Operating systems (especially Android 11+ and iOS) restrict writing directly to the public "Downloads" folder due to scoped storage. We will save the PDF files to the app's secure local documents directory, show a "Successfully Saved!" notification, and immediately present options to **Open** the PDF (using `open_file`) or **Share/Export** it (allowing the user to save it to their Downloads folder, Google Drive, or send it via chat).

---

## Open Questions

None at the moment. The requirements are clear, and the proposed implementation addresses the native permission constraints and local processing requirements.

---

## Proposed Changes

We will initialize a new Flutter project in the current directory and create/modify the following files.

### Configuration & Permissions

#### [MODIFY] [pubspec.yaml](file:///c:/Users/Atta/OneDrive/Documents/SmartScanner/pubspec.yaml)
*   Add dependencies: `edge_detection`, `image`, `pdf`, `image_gallery_saver`, `path_provider`, `permission_handler`, `shared_preferences`, `intl`, and `open_file`.

#### [MODIFY] [android/app/build.gradle](file:///c:/Users/Atta/OneDrive/Documents/SmartScanner/android/app/build.gradle)
*   Set `minSdkVersion` to `21` (required by `edge_detection`).

#### [MODIFY] [android/app/src/main/AndroidManifest.xml](file:///c:/Users/Atta/OneDrive/Documents/SmartScanner/android/app/src/main/AndroidManifest.xml)
*   Add permissions: `android.permission.CAMERA`, `android.permission.WRITE_EXTERNAL_STORAGE`, `android.permission.READ_EXTERNAL_STORAGE`.

#### [MODIFY] [ios/Runner/Info.plist](file:///c:/Users/Atta/OneDrive/Documents/SmartScanner/ios/Runner/Info.plist)
*   Add permission strings for `NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`, and `NSPhotoLibraryAddUsageDescription`.

---

### Core Application Code

#### [NEW] [scanned_document.dart](file:///c:/Users/Atta/OneDrive/Documents/SmartScanner/lib/models/scanned_document.dart)
*   Model representing a scanned item: `id`, `name`, `filePath`, `fileType` (image/pdf), `createdTime`, `fileSize`.

#### [NEW] [document_service.dart](file:///c:/Users/Atta/OneDrive/Documents/SmartScanner/lib/services/document_service.dart)
*   Saves scanned references using `shared_preferences`.
*   Manages files using `path_provider`.
*   Handles saving to gallery via `image_gallery_saver` and building PDFs via the `pdf` library.

#### [NEW] [image_filter_service.dart](file:///c:/Users/Atta/OneDrive/Documents/SmartScanner/lib/services/image_filter_service.dart)
*   Implements the 6 filters in pure Dart:
    1.  **Original:** Unaltered cropped image.
    2.  **No Shadow:** Downscales image -> Gaussian blurs it to estimate the background illumination map -> divides the original image channels by the blurred background map -> clamps to `[0, 255]`.
    3.  **Lighten:** Adjusts brightness by scale factor (e.g., `1.2x`) and contrast.
    4.  **Magic Color / Enhance:** Removes shadows (division normalization), increases contrast (stretching pixels) and saturation to make backgrounds white and text pop.
    5.  **B&W (Adaptive Thresholding):** Converts image to grayscale and applies local thresholding based on the illumination map, creating a high-contrast copy-machine scan.
    6.  **Grayscale:** Standard luminance conversion (`Y = 0.299R + 0.587G + 0.114B`).

---

### User Interface Screens

#### [NEW] [main.dart](file:///c:/Users/Atta/OneDrive/Documents/SmartScanner/lib/main.dart)
*   Configures the App theme: teal green color scheme (`Colors.teal` or Dark Teal `#008080` with dark gray accents matching the CamScanner aesthetic).

#### [NEW] [dashboard_screen.dart](file:///c:/Users/Atta/OneDrive/Documents/SmartScanner/lib/screens/dashboard_screen.dart)
*   Dashboard UI.
*   "SmartScanner" title.
*   Large floating/prominent button with a camera icon and the text "Pindai Dokumen".
*   List View of previously saved scans displaying thumbnail, name, creation date, format, and actions (Open, Share, Delete).

#### [NEW] [preview_screen.dart](file:///c:/Users/Atta/OneDrive/Documents/SmartScanner/lib/screens/preview_screen.dart)
*   Displays the full perspective-warped document.
*   Panel scrollable horizontally at the bottom for selecting the 6 filters, each displaying a dynamic tiny thumbnail preview.
*   "Foto Ulang" (Retake) button and "Simpan" (Save/Done) checkmark button.
*   Handles file format input and saving pop-up dialog (JPG/PNG to Gallery vs. PDF to Local Storage).

---

## Verification Plan

### Automated Tests
- Since this is a new Flutter codebase, we will compile and run the project using `flutter run` on the target device or simulator to verify:
  1. No compilation errors.
  2. Integration of edge detection (camera opens successfully and boundary is drawn).

### Manual Verification
1.  **Dashboard Screen:** Ensure the list displays previous items properly.
2.  **Scan Camera Flow:** Verify camera permission request, real-time edge overlay, crop adjustment page, and receipt of cropped file.
3.  **Filter Screen:** Toggle between the 6 filters. Verify that "No Shadow" removes shadows and "B&W" looks like a scan.
4.  **Save Dialog:** Choose Image -> input file name -> verify it is saved in the device's Gallery under "SmartScanner".
5.  **Save Dialog:** Choose PDF -> input file name -> verify it is saved in local app storage and can be shared/opened.
6.  **Dashboard List Update:** Verify that new documents appear immediately on the dashboard list.

# SmartScanner

Aplikasi pemindai dokumen Android **gratis, tanpa iklan, dan 100% offline** (tidak meminta izin internet sama sekali). Dibuat dengan Flutter + OpenCV + Google ML Kit (model OCR dibundel di dalam APK).

## Fitur

| Fitur | Keterangan |
|---|---|
| Deteksi tepi otomatis | Mendeteksi batas kertas walau kertas putih di atas lantai/meja terang (gabungan deteksi garis Hough + kontur) |
| Potong & luruskan | Seret 4 sudut atau 4 sisi, kaca pembesar, putar 90°, tombol *Otomatis / Semua* |
| 7 filter | Asli, Tingkatkan, Tanpa Bayang, Warna Ajaib, Pencerah, Hitam Putih, Abu-Abu — filter terakhir diingat sebagai default |
| Banyak halaman | Foto beruntun, impor banyak foto dari galeri sekaligus, tambah/foto ulang/hapus/putar/susun halaman, filter untuk semua halaman |
| KTP / kartu | Depan + belakang digabung dalam satu lembar A4 |
| Ekspor | PDF (A4, Letter, F4, atau ukuran otomatis), JPG ke galeri, Word (.docx), TXT; pilihan kualitas/ukuran file |
| PDF bisa dicari | Lapisan teks OCR tak terlihat ditempatkan tepat di atas tulisan, jadi teks PDF bisa dicari & disalin |
| OCR | Ambil teks dari halaman, salin atau bagikan |
| Bagikan | Langsung ke WhatsApp, email, Drive, dll. |
| Gabung dokumen | Tekan lama beberapa dokumen → Gabungkan |
| Tanda tangan & tanda air | Gambar tanda tangan lalu geser/ubah ukuran; tanda air diagonal |
| Kunci aplikasi | Sidik jari / wajah / PIN HP |

File hasil ekspor disimpan di **Penyimpanan Internal › Download › SmartScanner**.

## Cara build APK (Windows)

1. Pastikan Flutter sudah terpasang (`flutter doctor`).
2. Klik dua kali **`build_apk.bat`**, atau jalankan:
   ```
   flutter pub get
   flutter build apk --release --split-per-abi
   ```
3. Pasang `build\app\outputs\flutter-apk\app-arm64-v8a-release.apk` ke HP
   (untuk HP lama 32-bit pakai `app-armeabi-v7a-release.apk`).

`--split-per-abi` membuat APK jauh lebih kecil dibanding satu APK gabungan (~180 MB).

## Struktur kode

```
lib/
  main.dart                      tema & entry point
  models/scanned_document.dart   data dokumen (halaman, filter)
  services/
    homography_service.dart      normalisasi foto, deteksi tepi, warp perspektif, putar, KTP
    image_filter_service.dart    7 filter dokumen (OpenCV)
    document_service.dart        penyimpanan, PDF/Word/TXT/JPG, bagikan, gabung
    ocr_service.dart             OCR offline (ML Kit)
  screens/
    dashboard_screen.dart        daftar dokumen, pindai, pilih & gabung
    crop_screen.dart             potong & luruskan
    filter_screen.dart           pilih filter
    preview_screen.dart          kelola halaman, tanda tangan, ekspor
```

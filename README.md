# SmartScanner

Aplikasi pemindai dokumen Android yang **gratis, tanpa iklan, dan 100% offline**. Aplikasi tidak meminta izin internet sama sekali, jadi dokumen Anda tidak pernah keluar dari HP.

**[⬇️ Unduh APK terbaru](https://github.com/attaramadhani/APK-smartscanner/releases/latest)**

---

## Daftar isi

1. [Unduh & pasang](#1-unduh--pasang)
2. [Memindai dokumen](#2-memindai-dokumen)
3. [Mengelola halaman](#3-mengelola-halaman)
4. [Menyimpan & membagikan](#4-menyimpan--membagikan)
5. [Fitur lain](#5-fitur-lain)
6. [Tips hasil scan terbaik](#6-tips-hasil-scan-terbaik)
7. [Pertanyaan umum](#7-pertanyaan-umum)
8. [Untuk developer](#8-untuk-developer)

---

## 1. Unduh & pasang

1. Buka halaman **[Releases](https://github.com/attaramadhani/APK-smartscanner/releases/latest)** dari browser HP.
2. Pilih file sesuai HP Anda:

   | File | Untuk |
   |---|---|
   | `SmartScanner-arm64-v8a.apk` | Hampir semua HP Android sekarang (pilih ini kalau ragu) |
   | `SmartScanner-armeabi-v7a.apk` | HP Android lama / 32-bit |

3. Buka file yang sudah diunduh. Jika muncul peringatan *"Instal aplikasi tidak dikenal"*, ketuk **Setelan** lalu aktifkan **Izinkan dari sumber ini**, kemudian kembali dan ketuk **Instal**.
4. Jika Play Protect menampilkan peringatan, ketuk **Detail lainnya**, lalu **Tetap instal**. Peringatan ini muncul karena aplikasi tidak berasal dari Play Store.

> **Memperbarui aplikasi:** cukup pasang APK versi baru dari halaman Releases; dokumen yang tersimpan tetap ada.
> Jika HP menolak dengan pesan *"Aplikasi tidak terinstal"*, berarti versi lama dibuat dengan tanda tangan berbeda. Ekspor dulu dokumen penting, hapus aplikasi lama, lalu pasang yang baru.

Minimal Android 7.0. Saat pertama memindai, izinkan akses **Kamera**.

---

## 2. Memindai dokumen

Ketuk tombol **Pindai** di layar utama, lalu pilih:

| Pilihan | Kegunaan |
|---|---|
| **Kamera — satu halaman** | Satu lembar dokumen |
| **Kamera — banyak halaman** | Foto beberapa lembar berturut-turut menjadi satu dokumen. Setelah setiap foto, pilih **Foto lagi** atau **Selesai** |
| **KTP / Kartu identitas** | Foto sisi depan lalu belakang. Keduanya digabung di satu lembar A4 |
| **Impor dari galeri** | Pilih satu atau banyak foto yang sudah ada di HP |

### Langkah 1 — Potong (layar *Potong Dokumen*)

- Aplikasi **mendeteksi tepi kertas secara otomatis** (garis hijau).
- Jika kurang pas, **seret titik bulat** di sudut atau **garis pendek** di tengah sisi. Kaca pembesar muncul agar penempatan lebih presisi.
- **Putar**: memutar foto 90°.
- **Semua / Otomatis**: beralih antara memakai seluruh foto dan hasil deteksi otomatis.
- Ketuk **Lanjut**.

**Penyesuaian otomatis** (tombol ✨ di kanan atas, keduanya aktif secara bawaan):

- **Ukuran kertas otomatis**: memperbaiki proporsi kertas yang difoto miring dan menyesuaikannya ke ukuran standar terdekat (A4, F4, Letter, Legal, A5, atau kartu ID). Akan muncul pesan, misalnya *"Ukuran kertas disesuaikan: A4"*.
- **Putar otomatis (teks tegak)**: membaca arah tulisan, lalu memutar halaman yang miring atau terbalik. Halaman tidak diputar jika tulisannya terlalu sedikit untuk dibaca.

### Langkah 2 — Pilih filter

| Filter | Cocok untuk |
|---|---|
| **Asli** | Foto apa adanya |
| **Tingkatkan** | Warna alami, sedikit lebih tajam |
| **Tanpa Bayang** | Menghapus bayangan tangan/HP, kertas jadi putih, warna tetap |
| **Warna Ajaib** | Dokumen berwarna (stempel, logo): kertas putih, tinta lebih tegas |
| **Pencerah** | Foto yang terlalu gelap |
| **Hitam Putih** | Seperti hasil fotokopi; paling bagus untuk teks dan OCR |
| **Abu-Abu** | Hitam putih yang lebih halus |

Ketuk ✓. Filter yang terakhir dipakai akan diingat sebagai pilihan awal berikutnya.

---

## 3. Mengelola halaman

Setelah disimpan, dokumen terbuka di layar pratinjau. Geser ke kiri/kanan untuk berpindah halaman, atau ketuk thumbnail di bawah.

| Tombol | Fungsi |
|---|---|
| **Putar** | Memutar halaman yang sedang dibuka 90° |
| **Filter** | Mengganti filter; bisa untuk halaman ini saja atau **semua halaman** |
| **Tambah** | Menambah halaman dari kamera atau galeri (bisa pilih banyak sekaligus) |
| **OCR** | Mengambil teks dari halaman, lalu **Salin** atau **Bagikan** |
| **Nama dokumen** (di atas) | Ketuk untuk mengganti nama |
| Menu **⋮** | Tanda tangan, tanda air, susun ulang halaman, foto ulang halaman, hapus halaman |

---

## 4. Menyimpan & membagikan

Ketuk **Simpan** (atau ikon **Bagikan** di kanan atas), lalu pilih:

- **Format**
  - **PDF**: pilihan ukuran kertas **A4 / Letter / Legal-F4 / Otomatis (ikuti dokumen)**. Aktifkan *"PDF bisa dicari & disalin teksnya"* agar teks dalam PDF bisa dicari (Ctrl+F) dan disalin.
  - **Gambar JPG**: disimpan juga ke Galeri.
  - **Word (.docx)** dan **Teks (.txt)**: berisi teks hasil OCR yang bisa diedit.
- **Kualitas**: *Tinggi*, *Sedang* (bawaan), atau *Kecil* untuk file yang ringan dikirim lewat WhatsApp/email.

Hasil tersimpan di: **Penyimpanan Internal › Download › SmartScanner**.
Setelah tersimpan, Anda bisa langsung **Buka** atau **Bagikan** file-nya.

Dari layar utama, menu **⋮** pada dokumen › **Bagikan sebagai PDF** adalah cara tercepat untuk mengirim dokumen.

---

## 5. Fitur lain

- **Gabung dokumen**: tekan lama satu dokumen, ketuk dokumen lain sesuai urutan yang diinginkan (nomor urut terlihat), lalu ketuk ikon **Gabungkan** di atas.
- **Hapus banyak dokumen**: tekan lama untuk memilih, lalu ketuk ikon 🗑.
- **Cari dokumen**: ketik nama di kolom pencarian.
- **Tanda tangan**: menu ⋮ › Tanda tangan › gambar dengan jari › geser ke posisi yang diinginkan, tarik ikon sudut untuk mengubah ukuran. Tanda tangan ikut tersimpan saat ekspor.
- **Tanda air**: menu ⋮ › Tanda air, misalnya *"Hanya untuk verifikasi"*.
- **Kunci aplikasi**: ikon 🔒 di layar utama, memakai sidik jari, wajah, atau PIN HP.

---

## 6. Tips hasil scan terbaik

- Letakkan kertas di atas **alas yang warnanya berbeda** dengan kertas (meja gelap untuk kertas putih), supaya tepi kertas mudah terdeteksi.
- Pastikan **keempat sudut kertas terlihat** di foto.
- Gunakan cahaya terang dan merata. Bayangan ringan akan dihapus oleh filter *Tanpa Bayang* atau *Warna Ajaib*.
- Untuk OCR / PDF yang bisa dicari, gunakan filter **Hitam Putih** dan foto dari jarak yang cukup dekat agar tulisan tajam.
- Untuk dokumen yang dikirim lewat WhatsApp, pilih kualitas **Sedang** atau **Kecil**.

---

## 7. Pertanyaan umum

**Apakah perlu internet?**
Tidak. Semua proses (deteksi tepi, filter, OCR, PDF) berjalan di HP. Aplikasi bahkan tidak memiliki izin internet.

**Tepi kertas tidak terdeteksi atau kurang pas?**
Geser titik sudut secara manual, atau ketuk **Semua** untuk memakai seluruh foto. Untuk hasil deteksi yang lebih baik, gunakan alas yang kontras dengan kertas.

**Halaman terputar ke arah yang salah?**
Ketuk **Putar** di layar pratinjau. Jika sering terjadi, matikan *Putar otomatis* lewat tombol ✨ di layar potong.

**Ukuran kertas berubah tidak sesuai?**
Matikan *Ukuran kertas otomatis* lewat tombol ✨ di layar potong.

**OCR bahasa apa saja?**
Huruf latin (Indonesia, Inggris, dan bahasa berhuruf latin lainnya). Tulisan tangan yang rapi juga bisa terbaca, tetapi hasilnya tidak sebaik teks cetak.

**File hasil ekspor di mana?**
`Download/SmartScanner` di penyimpanan internal. Buka dengan aplikasi *File* / *File Manager* bawaan HP.

---

## 8. Untuk developer

Dibuat dengan **Flutter**, **OpenCV** (`opencv_dart`), dan **Google ML Kit Text Recognition**. Model OCR dibundel di dalam APK.

### Build otomatis (GitHub Actions)

Setiap *push* ke branch `main` menjalankan `.github/workflows/build-apk.yml`, yang membuat APK dan menerbitkannya di halaman **Releases** (`build-N`). Perubahan yang hanya menyentuh file Markdown tidak memicu build.

### Build manual (Windows)

```
flutter pub get
flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64
```

Atau klik dua kali `build_apk.bat`. Hasilnya ada di `build\app\outputs\flutter-apk\`.

### Struktur kode

```
lib/
  main.dart                      tema & entry point
  models/scanned_document.dart   data dokumen (halaman, filter)
  services/
    homography_service.dart      normalisasi foto, deteksi tepi, ukuran kertas otomatis,
                                 warp perspektif, putar, gabung KTP
    image_filter_service.dart    7 filter dokumen (OpenCV)
    document_service.dart        penyimpanan, PDF/Word/TXT/JPG, bagikan, gabung
    ocr_service.dart             OCR offline & deteksi arah tulisan (ML Kit)
  screens/
    dashboard_screen.dart        daftar dokumen, pindai, pilih & gabung
    crop_screen.dart             potong & luruskan
    filter_screen.dart           pilih filter
    preview_screen.dart          kelola halaman, tanda tangan, ekspor
```

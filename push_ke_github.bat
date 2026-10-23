@echo off
REM ============================================================
REM  Unggah kode SmartScanner ke GitHub
REM  Repo: https://github.com/attaramadhani/APK-smartscanner
REM  Jalankan dengan klik dua kali. Saat pertama kali, Windows akan
REM  membuka jendela login GitHub - login dengan akun attaramadhani.
REM ============================================================
cd /d "%~dp0"
where git >nul 2>nul
if errorlevel 1 (
  echo Git belum terpasang. Unduh dan pasang dari https://git-scm.com/download/win
  echo lalu jalankan file ini lagi.
  pause
  exit /b 1
)

if not exist ".git" git init

git config user.name >nul 2>nul || git config user.name "attaramadhani"
git config user.email >nul 2>nul || git config user.email "tigamassejahtera79@gmail.com"

git add -A
git commit -m "SmartScanner v2.0: deteksi tepi otomatis baru, 7 filter, PDF searchable, Word, bagikan, gabung dokumen, putar halaman"
git branch -M main

git remote remove origin >nul 2>nul
git remote add origin https://github.com/attaramadhani/APK-smartscanner.git
git push -u origin main
if errorlevel 1 (
  echo.
  echo ===== PUSH GAGAL - salin pesan error di atas =====
) else (
  echo.
  echo ===== BERHASIL - kode sudah ada di GitHub =====
  start https://github.com/attaramadhani/APK-smartscanner
)
pause

@echo off
REM ============================================================
REM  SmartScanner - build APK (jalankan dengan klik dua kali)
REM  Hasil: build\app\outputs\flutter-apk\
REM    app-arm64-v8a-release.apk   <- untuk hampir semua HP Android modern
REM    app-armeabi-v7a-release.apk <- untuk HP Android lama (32-bit)
REM ============================================================
cd /d "%~dp0"
call flutter pub get || goto :err
call flutter build apk --release --split-per-abi || goto :err
echo.
echo ===== SELESAI =====
echo APK ada di: %~dp0build\app\outputs\flutter-apk\
explorer "%~dp0build\app\outputs\flutter-apk"
pause
exit /b 0
:err
echo.
echo ===== BUILD GAGAL - salin pesan error di atas =====
pause
exit /b 1

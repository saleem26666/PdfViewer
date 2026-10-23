@echo off
REM Pub cache on D: avoids Kotlin C:/D: incremental cache bugs.
set PUB_CACHE=D:\pub-cache
if not exist "%PUB_CACHE%" mkdir "%PUB_CACHE%"
cd /d "%~dp0"
call flutter pub get
call flutter build apk --release
if exist "build\app\outputs\flutter-apk\app-release.apk" (
  copy /Y "build\app\outputs\flutter-apk\app-release.apk" "PDF_Reader.apk"
  echo.
  echo APK ready: %~dp0PDF_Reader.apk
)

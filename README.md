# PDF Reader (personal)

Lightweight Android PDF viewer using **PDFium** (same engine as Chrome).  
Built so Budget Pro / Urdu / market PDFs show **full page, clear fonts** on screen — unlike the Office WebView apps that crop or mis-render some PDFs.

## Features

- Open any `.pdf` from storage
- Share / Open-with from Budget Pro, WhatsApp, Files
- Pinch zoom, page prev/next, go-to-page
- Night page background
- Recent files list

## Build APK

```bat
cd /d d:\projects\PdfViewer
flutter pub get
flutter build apk --release
```

APK: `build\app\outputs\flutter-apk\app-release.apk`

# EasyBuy — Android app

The Flutter client. See the [repository README](../README.md) for the full picture and setup.

```bash
flutter pub get
flutter build apk --release      # -> build/app/outputs/flutter-apk/app-release.apk
flutter test
```

The app talks only to the local Node proxy in [`../backend`](../backend); the YouCam API key never
reaches the device. Set the proxy address on first run under **Setup**.

## Layout

```
lib/
  main.dart          app shell, share-sheet intake, three-tab navigation
  store.dart         shared state (photo, renders, connection) via ChangeNotifier
  api.dart           proxy client and on-device garment image fetching
  extractor.dart     offscreen WebView that runs the shared extractor script
  theme.dart         palette and component styling
  screens/           home, wardrobe, you, try-on, setup
  widgets/           before/after slider, stage progress, photo viewer, common bits
assets/
  extractor.js       shared with the Chrome extension — see note below
tool/
  generate_icon.py   regenerates every launcher icon density
```

`assets/extractor.js` is a copy of `../extension/content/adapters.js` with a `JSON.stringify` call
appended so the WebView can return the result. Regenerate it with:

```bash
cp ../extension/content/adapters.js assets/extractor.js
printf '\nJSON.stringify(window.__EASYBUY_EXTRACT());\n' >> assets/extractor.js
```

# Bundled Offline Doc Chat

A separate bare React Native CLI POC. The app includes an office guide and bundled local model, and lets users choose a text document from the system file picker on iOS and Android. The app does not contact a server or download assets.

## Start the app

Requirements: Node.js 20+, Android Studio for Android, or Xcode and CocoaPods for iOS. Install packages while online, then build and install the release app. Runtime Q&A works offline.

```sh
npm install
npm run android
# macOS / iOS:
npx pod-install
npm run ios
```

The bundled model loads at startup on both platforms. Use **Choose file** to select a `.txt`, `.md`, `.pdf`, or Word `.docx` document; the app extracts its text locally and uses it for passage retrieval and answers. Scanned PDFs without an embedded text layer cannot be searched. Legacy binary Word `.doc` files are not supported. The selected document is kept for the current app session. The original sample guide is used until a document is selected.

For a debug build on a USB-connected Android phone, keep Metro running in one terminal with `npm start`. In another terminal, run `adb reverse tcp:8081 tcp:8081` and then `npx react-native run-android`. Re-run `adb reverse` after reconnecting the phone. The `npm run android` script builds release mode and does not use Metro.

## Included content and model

- Document text: `src/sampleDocument.ts`
- Local passage ranking: `src/retrieval.ts`
- Bundled model: `assets/models/Qwen2.5-0.5B-Instruct-Q4_K_M.gguf`
- Model source: [bartowski/Qwen2.5-0.5B-Instruct-GGUF](https://huggingface.co/bartowski/Qwen2.5-0.5B-Instruct-GGUF)
- Model license: Apache-2.0; review the model card before redistributing.

The bundled model is stored with Git LFS because it exceeds GitHub’s regular 100 MiB file limit. Install Git LFS before cloning this repository; after cloning, run `git lfs pull` if the model was not checked out automatically. The app does not download models at runtime.

The GGUF file is about 398 MB. The installed app is correspondingly large; Android also needs additional free space for its first-launch private copy.

The sample guide is intentionally fictional and serves as the initial document. Users can choose a `.txt`, `.md`, `.pdf`, or `.docx` file in the app without rebuilding.

## Offline behavior

- Android removes the `INTERNET` permission from the merged manifest.
- The app contains no API client, network request, database, or analytics.
- Text ranking and answer generation run locally using `llama.rn` / `llama.cpp`.
- The user can choose a `.txt`, `.md`, `.pdf`, or `.docx` document on either platform. The original sample guide is included as the initial document; chat state exists in memory for the current app session.

This is a small-model POC. Keyword retrieval is strongest when the question shares terms with the document. The model and retrieval code are English-oriented in this sample.

# 3D Playground

Live at **https://thebehera.github.io/3d/**

| | Web | iPhone app |
|---|---|---|
| **Facefield** (`facefield/`) | Front camera via MediaPipe Face Landmarker: head pose, 52 blendshapes, mic | ARKit face tracking: 1,220-vertex mesh, blendshapes, head pose, TrueDepth depth map, mic |
| **Sky Duel** (`sky-duel/`) | Pass and play (online duels only work inside Claude) | – |

## Facefield on the web

Open `facefield/` and tap **Use camera**. iOS Safari needs https (GitHub Pages serves it that way) and a tap to start the camera, which the button provides. If you denied access before, re-enable it in Settings › Apps › Safari › Camera.

## Facefield iPhone app (`ios/`)

The app is a thin Swift shell: `FaceStreamer.swift` runs `ARFaceTrackingConfiguration` and pushes each frame into the same Facefield page (bundled from `facefield/index.html`) through `window.facefieldNative.frame()`. The pin-screen mode then shows measured TrueDepth depth, so hair and shoulders appear too. The other modes deform with your real face mesh.

```sh
brew install xcodegen      # once
cd ios && xcodegen generate && open Facefield.xcodeproj
```

Pick your iPhone and run. It needs a Face ID iPhone (TrueDepth camera). From the command line:

```sh
xcodebuild -project ios/Facefield.xcodeproj -scheme Facefield -destination 'id=<device-udid>' -allowProvisioningUpdates build
xcrun devicectl device install app --device <device-udid> <DerivedData>/Build/Products/Debug-iphoneos/Facefield.app
```

Debug the page inside the app from Safari › Develop › your iPhone › Facefield.

## Local preview

Serve the repo root over http (any static server) and open `/facefield/`. Camera access works on `localhost` without https.

# Camera App (相机伴侣)

iOS camera companion app with WiFi photo transfer and AI neural network filters.

## Architecture

```
lib/
├── main.dart              # Entry point, service initialization
├── app.dart               # MaterialApp configuration, theme
├── models/
│   └── filter.dart        # PhotoFilter, Watermark data models
├── services/
│   ├── filter_service.dart   # Filter management, CoreML inference
│   ├── image_service.dart    # Image storage, caching, watermark
│   └── camera_service.dart   # WiFi camera connection, photo transfer
├── screens/
│   ├── home_screen.dart         # Main navigation hub
│   ├── camera_connect_screen.dart  # WiFi camera connection UI
│   ├── edit_screen.dart         # Filter application editor
│   └── gallery_screen.dart      # Photo gallery browser
└── widgets/                    # Reusable UI components
```

## Tech Stack

- **Framework:** Flutter 3.27+ (Dart 3.6+)
- **State Management:** Provider
- **ML Inference:** CoreML (iOS native, via platform channel)
- **Image Processing:** image package (Dart) + CoreML (native)
- **Filters:** Filter4Free neural film simulations (Apache 2.0)

## Filter Pipeline

```
PyTorch .pth → coremltools → .mlmodel → CoreML on iOS
     ↑                              ↑
  Filter4Free                  scripts/convert_models.py
  (Gitee)                      (runs on macOS CI)
```

### Available Filters (22 total)

| Brand | Filters |
|-------|---------|
| Fuji | ACROS, CLASSIC CHROME, ETERNA, ETERNA BLEACH BYPASS, CLASSIC Neg., PRO Neg.Hi, NOSTALGIC Neg., PRO Neg.Std, ASTIA, PROVIA, VELVIA, Pro 400H, Superia 400, reala |
| Kodak | Color Plus, Gold 200, Portra 400, Portra 160NC, UltraMax 400 |
| Olympus | VIVID |
| Polaroid | Polaroid |

## Development

### Prerequisites
- Flutter 3.27+
- Python 3.12+ (for model conversion)
- macOS + Xcode (for iOS builds and model conversion)

### Setup

```bash
# Install Flutter dependencies
flutter pub get

# Convert Filter4Free models to CoreML (macOS only)
pip install -r ../filter4free/requirements.txt coremltools
python scripts/convert_models.py --checkpoints-dir ../filter4free/pretrained_checkpoints --output-dir assets/models

# Run on simulator
flutter run

# Build for iOS
flutter build ios --release
```

### Testing on Windows/Linux (Web fallback)
```bash
flutter run -d chrome
```

## CI/CD

- **Repository:** Gitee (primary) → GitHub (mirror for CI)
- **iOS Build:** GitHub Actions with macOS runner
- **Model Conversion:** GitHub Actions workflow_dispatch trigger

## Key Design Decisions

1. **CoreML over ONNX** — CoreML is Apple-native, optimized for A-series chips. Filter4Free models are tiny (80-200K params), no server needed.
2. **Tile-based inference** — Images are split into fixed-size patches (448px with 16px padding) for memory-efficient processing regardless of photo resolution.
3. **Progressive rendering** — Low-res preview (<1s) then full-res processing (~4s for 12MP).
4. **WiFi camera API** — Most cameras expose HTTP APIs. We auto-detect common brands (Sony, Fujifilm, Canon, Nikon) by probing known IPs.

import 'dart:math';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'neural_filter_client.dart';
import 'coreml_bridge.dart';

/// Pre-computed light leak overlay textures.
///
/// Generated once on first use, cached forever. Each overlay is a 800x600 RGBA
/// image representing a different light leak pattern — large, soft, diffused
/// warm glows that mimic real film light leaks (like sunlight bleeding into frame).
/// At runtime, one is randomly selected, scaled to the target image, tinted
/// per style, and composited via screen blend.
class _LeakOverlays {
  static List<img.Image>? _cache;

  static List<img.Image> get overlays => _cache ??= _generate();

  static List<img.Image> _generate() {
    const w = 800, h = 600;
    return [
      _rightSunburst(w, h), // Large warm glow from right (matches reference)
      _leftSunburst(w, h), // Mirror: glow from left
      _topRightSunburst(w, h), // Glow from top-right corner
      _bottomRightSunburst(w, h), // Glow from bottom-right
      _topSunburst(w, h), // Glow from top edge
      _leftCenterGlow(w, h), // Soft glow left-center
      _edgeWash(w, h), // Soft wash along right edge
      _warmHaze(w, h), // Overall warm haze
    ];
  }

  // ── Large soft sunburst patterns ──

  /// Large warm glow from the right side — matches the reference image.
  /// Big, diffused, golden-orange wash bleeding in from the right edge.
  static img.Image _rightSunburst(int w, int h) {
    final m = img.Image(width: w, height: h, numChannels: 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final dx = 1.0 - x / w; // 0 at right edge, 1 at left
        final vy = (y / h - 0.45) * 2.0; // slightly above center
        // Main glow: large soft radial from right edge
        final radialFade = exp(-2.5 * dx);
        // Vertical spread: wide Gaussian
        final vertFade = exp(-1.2 * vy * vy);
        // Secondary softer glow for depth
        final softGlow = exp(-1.5 * dx) * exp(-0.8 * vy * vy);
        final fade = (radialFade * vertFade * 0.7 + softGlow * 0.3).clamp(0.0, 1.0);
        final a = (fade * 255).toInt().clamp(0, 255);
        if (a < 1) continue;
        // Warm golden-orange color
        m.setPixelRgba(x, y, 255, (200 * fade + 80 * (1 - fade)).toInt().clamp(0, 255), (80 * fade).toInt().clamp(0, 255), a);
      }
    }
    return _blurOverlay(m);
  }

  /// Large warm glow from the left side.
  static img.Image _leftSunburst(int w, int h) {
    final m = img.Image(width: w, height: h, numChannels: 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final dx = x / w;
        final vy = (y / h - 0.45) * 2.0;
        final radialFade = exp(-2.5 * dx);
        final vertFade = exp(-1.2 * vy * vy);
        final softGlow = exp(-1.5 * dx) * exp(-0.8 * vy * vy);
        final fade = (radialFade * vertFade * 0.7 + softGlow * 0.3).clamp(0.0, 1.0);
        final a = (fade * 255).toInt().clamp(0, 255);
        if (a < 1) continue;
        m.setPixelRgba(x, y, 255, (200 * fade + 80 * (1 - fade)).toInt().clamp(0, 255), (80 * fade).toInt().clamp(0, 255), a);
      }
    }
    return _blurOverlay(m);
  }

  /// Warm glow from the top-right corner.
  static img.Image _topRightSunburst(int w, int h) {
    final m = img.Image(width: w, height: h, numChannels: 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final dx = 1.0 - x / w;
        final dy = y / h;
        final dist = sqrt(dx * dx * 0.7 + dy * dy * 1.3);
        final fade = exp(-2.0 * dist);
        final a = (fade * 255).toInt().clamp(0, 255);
        if (a < 1) continue;
        m.setPixelRgba(x, y, 255, (190 * fade + 60 * (1 - fade)).toInt().clamp(0, 255), (70 * fade).toInt().clamp(0, 255), a);
      }
    }
    return _blurOverlay(m);
  }

  /// Warm glow from the bottom-right corner.
  static img.Image _bottomRightSunburst(int w, int h) {
    final m = img.Image(width: w, height: h, numChannels: 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final dx = 1.0 - x / w;
        final dy = 1.0 - y / h;
        final dist = sqrt(dx * dx * 0.7 + dy * dy * 1.3);
        final fade = exp(-2.0 * dist);
        final a = (fade * 255).toInt().clamp(0, 255);
        if (a < 1) continue;
        m.setPixelRgba(x, y, 255, (190 * fade + 60 * (1 - fade)).toInt().clamp(0, 255), (70 * fade).toInt().clamp(0, 255), a);
      }
    }
    return _blurOverlay(m);
  }

  /// Large warm glow from the top edge.
  static img.Image _topSunburst(int w, int h) {
    final m = img.Image(width: w, height: h, numChannels: 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final dy = y / h;
        final vx = (x / w - 0.5) * 2.0;
        final radialFade = exp(-2.5 * dy);
        final horizFade = exp(-1.0 * vx * vx);
        final softGlow = exp(-1.5 * dy) * exp(-0.6 * vx * vx);
        final fade = (radialFade * horizFade * 0.7 + softGlow * 0.3).clamp(0.0, 1.0);
        final a = (fade * 255).toInt().clamp(0, 255);
        if (a < 1) continue;
        m.setPixelRgba(x, y, 255, (200 * fade + 80 * (1 - fade)).toInt().clamp(0, 255), (90 * fade).toInt().clamp(0, 255), a);
      }
    }
    return _blurOverlay(m);
  }

  /// Soft glow from the left-center area.
  static img.Image _leftCenterGlow(int w, int h) {
    final m = img.Image(width: w, height: h, numChannels: 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final dx = x / w;
        final vy = (y / h - 0.5) * 2.0;
        final horizFade = exp(-3.0 * dx);
        final edgeSoft = exp(-1.5 * dx);
        final fade = (horizFade * 0.6 + edgeSoft * 0.4).clamp(0.0, 1.0);
        final fadeY = exp(-0.8 * vy * vy);
        final a = (fade * fadeY * 240).toInt().clamp(0, 255);
        if (a < 1) continue;
        m.setPixelRgba(x, y, 255, (200 * fade * fadeY).toInt().clamp(0, 255), (100 * fade * fadeY).toInt().clamp(0, 255), a);
      }
    }
    return _blurOverlay(m);
  }

  /// Soft warm wash along the right edge — thin but tall.
  static img.Image _edgeWash(int w, int h) {
    final m = img.Image(width: w, height: h, numChannels: 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final dx = 1.0 - x / w;
        final vy = (y / h - 0.5) * 2.0;
        final hFade = exp(-5.0 * dx);
        final vFade = exp(-1.5 * vy * vy);
        final soft = exp(-3.0 * dx) * exp(-1.0 * vy * vy);
        final fade = (hFade * vFade * 0.5 + soft * 0.5).clamp(0.0, 1.0);
        final a = (fade * 255).toInt().clamp(0, 255);
        if (a < 1) continue;
        m.setPixelRgba(x, y, 255, (210 * fade).toInt().clamp(0, 255), (100 * fade).toInt().clamp(0, 255), a);
      }
    }
    return _blurOverlay(m);
  }

  /// Overall warm haze — subtle full-image warm wash, slightly right-biased.
  static img.Image _warmHaze(int w, int h) {
    final m = img.Image(width: w, height: h, numChannels: 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final nx = (x / w - 0.5) * 2.0;
        final ny = (y / h - 0.5) * 2.0;
        final dist = sqrt(nx * nx + ny * ny);
        final fade = exp(-1.0 * dist);
        final rightBias = exp(-1.5 * (1.0 - x / w));
        final combined = (fade * 0.6 + rightBias * 0.4).clamp(0.0, 1.0);
        final a = (combined * 200).toInt().clamp(0, 255);
        if (a < 1) continue;
        m.setPixelRgba(x, y, 255, (220 * combined).toInt().clamp(0, 255), (120 * combined).toInt().clamp(0, 255), a);
      }
    }
    return _blurOverlay(m);
  }

  /// Heavy Gaussian blur for soft, realistic glow edges.
  static img.Image _blurOverlay(img.Image src) {
    return img.gaussianBlur(src, radius: 12);
  }
}

/// Applies film simulation filters to images.
///
/// Filter processing — uses local Dart color matrix simulation.
class FilterProcessor {
  static NeuralFilterClient? _neuralClient;

  /// Configure neural backend.
  static void setNeuralBackend(NeuralFilterClient client) {
    _neuralClient = client;
  }

  /// Check if neural backend is available.
  static Future<bool> get isNeuralAvailable async {
    if (_neuralClient == null) return false;
    return await _neuralClient!.isAvailable();
  }

  /// Apply a named film filter to image bytes.
  /// Uses local color matrix simulation (fast, reliable, no CoreML dependency).
  static Future<Uint8List> apply(Uint8List input, String filterName) async {
    // Local simulation — always works, no model loading or CoreML issues.
    return _applyLocal(input, filterName);
  }

  /// Downsample image for fast preview processing.
  /// Returns the input unchanged if already small enough.
  static Uint8List downsampleForPreview(Uint8List input, {int maxDim = 1000}) {
    final image = img.decodeImage(input);
    if (image == null) return input;
    if (image.width <= maxDim && image.height <= maxDim) return input;

    final resized = img.copyResize(image,
        width: image.width >= image.height ? maxDim : null,
        height: image.height > image.width ? maxDim : null,
        interpolation: img.Interpolation.linear);
    return Uint8List.fromList(img.encodeJpg(resized, quality: 85));
  }

  /// Convert display filter name to CoreML model name.
  static String _filterNameToModelName(String filterName) {
    // Map from display names used in EffectsScreen to model file names
    const nameMap = {
      'ACROS': 'fuji_acros',
      'CLASSIC CHROME': 'fuji_classic_chrome',
      'ETERNA': 'fuji_eterna',
      'ETERNA BLEACH BYPASS': 'fuji_eterna_bleach',
      'CLASSIC Neg.': 'fuji_classic_neg',
      'PRO Neg.Hi': 'fuji_pro_neg_hi',
      'NOSTALGIC Neg.': 'fuji_nostalgic_neg',
      'PRO Neg.Std': 'fuji_pro_neg_std',
      'ASTIA': 'fuji_astia',
      'PROVIA': 'fuji_provia',
      'VELVIA': 'fuji_velvia',
      'Pro 400H': 'fuji_pro400h',
      'Superia 400': 'fuji_superia400',
      'reala': 'fuji_reala',
      'Color Plus': 'kodak_color_plus',
      'Gold 200': 'kodak_gold200',
      'Portra 400': 'kodak_portra400',
      'Portra 160NC': 'kodak_portra160nc',
      'UltraMax 400': 'kodak_ultramax400',
      'VIVID': 'olympus_vivid',
      'Polaroid': 'polaroid',
    };
    return nameMap[filterName] ?? filterName.toLowerCase().replaceAll(' ', '_');
  }

  /// Local color matrix simulation (fallback).
  static Uint8List _applyLocal(Uint8List input, String filterName) {
    final image = img.decodeImage(input);
    if (image == null) return input;

    img.Image result;
    switch (filterName) {
      // === Fuji ===
      case 'ACROS':
        result = _acros(image);
      case 'CLASSIC CHROME':
        result = _classicChrome(image);
      case 'ETERNA':
        result = _eterna(image);
      case 'ETERNA BLEACH BYPASS':
        result = _eternaBleach(image);
      case 'CLASSIC Neg.':
        result = _classicNeg(image);
      case 'PRO Neg.Hi':
        result = _proNegHi(image);
      case 'NOSTALGIC Neg.':
        result = _nostalgicNeg(image);
      case 'PRO Neg.Std':
        result = _proNegStd(image);
      case 'ASTIA':
        result = _astia(image);
      case 'PROVIA':
        result = _provia(image);
      case 'VELVIA':
        result = _velvia(image);
      case 'Pro 400H':
        result = _pro400h(image);
      case 'Superia 400':
        result = _superia400(image);
      case 'reala':
        result = _reala(image);

      // === Kodak ===
      case 'Color Plus':
        result = _colorPlus(image);
      case 'Gold 200':
        result = _gold200(image);
      case 'Portra 400':
        result = _portra400(image);
      case 'Portra 160NC':
        result = _portra160nc(image);
      case 'UltraMax 400':
        result = _ultramax400(image);

      // === Olympus ===
      case 'VIVID':
        result = _vivid(image);

      // === Polaroid ===
      case 'Polaroid':
        result = _polaroid(image);

      default:
        result = image;
    }

    return Uint8List.fromList(img.encodeJpg(result, quality: 92));
  }

  // ─── Color Helpers ───

  static img.Image _adjustRGB(img.Image src, {
    double rMul = 1.0, double gMul = 1.0, double bMul = 1.0,
    int rAdd = 0, int gAdd = 0, int bAdd = 0,
    double contrast = 1.0, double saturation = 1.0,
    double brightness = 0.0, double gamma = 1.0,
  }) {
    final out = img.Image(width: src.width, height: src.height);
    for (var y = 0; y < src.height; y++) {
      for (var x = 0; x < src.width; x++) {
        final p = src.getPixel(x, y);

        // RGB adjustment
        double r = (p.r * rMul + rAdd).clamp(0, 255).toDouble();
        double g = (p.g * gMul + gAdd).clamp(0, 255).toDouble();
        double b = (p.b * bMul + bAdd).clamp(0, 255).toDouble();

        // Brightness
        r += brightness * 255;
        g += brightness * 255;
        b += brightness * 255;

        // Gamma
        r = 255 * ((r / 255) * (r / 255) * gamma + (r / 255) * (1 - gamma));
        g = 255 * ((g / 255) * (g / 255) * gamma + (g / 255) * (1 - gamma));
        b = 255 * ((b / 255) * (b / 255) * gamma + (b / 255) * (1 - gamma));

        // Saturation
        final gray = 0.299 * r + 0.587 * g + 0.114 * b;
        r = (gray + saturation * (r - gray)).clamp(0, 255);
        g = (gray + saturation * (g - gray)).clamp(0, 255);
        b = (gray + saturation * (b - gray)).clamp(0, 255);

        // Contrast
        r = (((r / 255 - 0.5) * contrast + 0.5) * 255).clamp(0, 255);
        g = (((g / 255 - 0.5) * contrast + 0.5) * 255).clamp(0, 255);
        b = (((b / 255 - 0.5) * contrast + 0.5) * 255).clamp(0, 255);

        out.setPixelRgba(x, y, r.toInt(), g.toInt(), b.toInt(), p.a);
      }
    }
    return out;
  }

  // ─── Fuji Film Simulations ───

  /// ACROS — Classic B&W with rich shadow detail
  static img.Image _acros(img.Image src) {
    final out = img.Image(width: src.width, height: src.height);
    for (var y = 0; y < src.height; y++) {
      for (var x = 0; x < src.width; x++) {
        final p = src.getPixel(x, y);
        // Acros tonal curve: emphasize reds, smooth greens
        final gray = (0.4 * p.r + 0.3 * p.g + 0.3 * p.b).toInt();
        // S-curve for contrast
        final v = gray / 255.0;
        final curved = (v < 0.5 ? 2 * v * v : -1 + (4 - 2 * v) * v) * 255;
        final g = curved.clamp(0, 255).toInt();
        out.setPixelRgba(x, y, g, g, g, p.a);
      }
    }
    return out;
  }

  /// CLASSIC CHROME — Muted colors, strong contrast, documentary style
  static img.Image _classicChrome(img.Image src) {
    return _adjustRGB(src, saturation: 0.7, contrast: 1.15,
        rMul: 1.05, gMul: 0.95, bMul: 0.9, brightness: -0.03);
  }

  /// ETERNA — Cinema film, soft colors, rich shadows
  static img.Image _eterna(img.Image src) {
    return _adjustRGB(src, saturation: 0.75, contrast: 0.95,
        rMul: 1.0, gMul: 0.95, bMul: 1.05, brightness: -0.02, gamma: 0.95);
  }

  /// ETERNA BLEACH BYPASS — Low saturation, high contrast
  static img.Image _eternaBleach(img.Image src) {
    return _adjustRGB(src, saturation: 0.3, contrast: 1.35,
        brightness: -0.05, gamma: 0.9);
  }

  /// CLASSIC Neg. — High contrast modern negative
  static img.Image _classicNeg(img.Image src) {
    return _adjustRGB(src, saturation: 0.85, contrast: 1.25,
        rMul: 1.1, gMul: 0.9, bMul: 0.85, brightness: 0.02);
  }

  /// PRO Neg.Hi — Portrait negative, excellent skin tones
  static img.Image _proNegHi(img.Image src) {
    return _adjustRGB(src, saturation: 0.7, contrast: 0.9,
        rMul: 1.05, gMul: 0.95, bMul: 0.85, brightness: 0.03);
  }

  /// NOSTALGIC Neg. — Amber-tinted nostalgic tones
  static img.Image _nostalgicNeg(img.Image src) {
    return _adjustRGB(src, saturation: 0.65, contrast: 1.05,
        rMul: 1.15, gMul: 0.95, bMul: 0.75, brightness: 0.04,
        rAdd: 15, gAdd: 0, bAdd: -10);
  }

  /// PRO Neg.Std — Natural, soft pro negative
  static img.Image _proNegStd(img.Image src) {
    return _adjustRGB(src, saturation: 0.8, contrast: 0.95,
        rMul: 1.02, gMul: 0.98, bMul: 0.9, brightness: 0.01);
  }

  /// ASTIA — Soft slide film, great for skin & flowers
  static img.Image _astia(img.Image src) {
    return _adjustRGB(src, saturation: 0.9, contrast: 0.9,
        rMul: 1.05, gMul: 0.95, bMul: 0.95, brightness: 0.04);
  }

  /// PROVIA — Standard slide, true color reproduction
  static img.Image _provia(img.Image src) {
    return _adjustRGB(src, saturation: 1.05, contrast: 1.1,
        brightness: 0.01);
  }

  /// VELVIA — Vivid landscape slide, extreme saturation
  static img.Image _velvia(img.Image src) {
    return _adjustRGB(src, saturation: 1.4, contrast: 1.2,
        rMul: 1.02, gMul: 1.05, bMul: 1.0, brightness: -0.02);
  }

  /// Pro 400H — Professional color negative, Japanese pastel style
  static img.Image _pro400h(img.Image src) {
    return _adjustRGB(src, saturation: 0.65, contrast: 0.85,
        rMul: 0.95, gMul: 1.05, bMul: 1.1, brightness: 0.06);
  }

  /// Superia 400 — Everyday color negative, crisp colors
  static img.Image _superia400(img.Image src) {
    return _adjustRGB(src, saturation: 1.1, contrast: 1.05,
        rMul: 1.05, gMul: 0.95, bMul: 0.9);
  }

  /// reala — True color reproduction negative film
  static img.Image _reala(img.Image src) {
    return _adjustRGB(src, saturation: 0.95, contrast: 0.95,
        rMul: 1.0, gMul: 1.0, bMul: 0.95);
  }

  // ─── Kodak Film Simulations ───

  /// Color Plus — Classic consumer color negative, warm tones
  static img.Image _colorPlus(img.Image src) {
    return _adjustRGB(src, saturation: 1.1, contrast: 1.0,
        rMul: 1.1, gMul: 0.95, bMul: 0.85, brightness: 0.02,
        rAdd: 8, bAdd: -5);
  }

  /// Gold 200 — Golden warm daylight negative
  static img.Image _gold200(img.Image src) {
    return _adjustRGB(src, saturation: 1.05, contrast: 1.02,
        rMul: 1.12, gMul: 0.95, bMul: 0.8, brightness: 0.03,
        rAdd: 10, bAdd: -8);
  }

  /// Portra 400 — Professional portrait, perfect skin tones
  static img.Image _portra400(img.Image src) {
    return _adjustRGB(src, saturation: 0.7, contrast: 0.88,
        rMul: 1.02, gMul: 0.95, bMul: 0.82, brightness: 0.05,
        rAdd: 5, bAdd: -3);
  }

  /// Portra 160NC — Low ISO pro negative, neutral color
  static img.Image _portra160nc(img.Image src) {
    return _adjustRGB(src, saturation: 0.65, contrast: 0.9,
        rMul: 1.0, gMul: 0.97, bMul: 0.85, brightness: 0.03);
  }

  /// UltraMax 400 — High saturation general-purpose
  static img.Image _ultramax400(img.Image src) {
    return _adjustRGB(src, saturation: 1.2, contrast: 1.08,
        rMul: 1.08, gMul: 0.92, bMul: 0.88);
  }

  // ─── Olympus ───

  /// VIVID — Olympus vivid color mode
  static img.Image _vivid(img.Image src) {
    return _adjustRGB(src, saturation: 1.3, contrast: 1.1,
        rMul: 1.02, gMul: 1.04, bMul: 1.05);
  }

  // ─── Polaroid ───

  /// Polaroid — Instant film look, slightly faded
  static img.Image _polaroid(img.Image src) {
    return _adjustRGB(src, saturation: 0.75, contrast: 0.85,
        rMul: 1.05, gMul: 0.95, bMul: 0.9, brightness: 0.08,
        rAdd: 10, gAdd: 5, bAdd: -5);
  }

  // ─── Post-processing: Grain & Light Leak ───

  /// Apply optional film grain and light leak effects to image bytes.
  ///
  /// Decodes once, applies grain then light leak, encodes once.
  /// [grainIntensity] and [lightLeakIntensity] are 0–100.
  /// [lightLeakRange] controls how far the leak reaches (0–100).
  static Uint8List applyPostEffects(
    Uint8List input, {
    double grainIntensity = 0,
    double lightLeakIntensity = 0,
    double lightLeakRange = 50,
    String lightLeakStyle = 'NONE',
    String? imageName,
  }) {
    if ((grainIntensity <= 0) &&
        (lightLeakStyle == 'NONE' || lightLeakIntensity <= 0)) {
      return input;
    }

    var image = img.decodeImage(input);
    if (image == null) return input;

    final seed = _deriveSeed(input, imageName);

    if (grainIntensity > 0) {
      _addGrainToImage(image, grainIntensity, seed);
    }

    if (lightLeakStyle != 'NONE' && lightLeakIntensity > 0) {
      _addLightLeakToImage(
          image, lightLeakStyle, lightLeakRange, lightLeakIntensity, seed + 1);
    }

    return Uint8List.fromList(img.encodeJpg(image, quality: 95));
  }

  /// Generate a stable seed so the same photo always gets the same pattern.
  static int _deriveSeed(Uint8List bytes, String? name) {
    if (name != null && name.isNotEmpty) {
      return name.hashCode ^ bytes.length;
    }
    var h = bytes.length;
    final count = min(64, bytes.length);
    for (var i = 0; i < count; i++) {
      h = h * 31 + bytes[i];
    }
    return h;
  }

  /// Add luminance-aware monochrome film grain.
  ///
  /// Uses a single random noise value per pixel (monochrome) with a midtone
  /// weighting so grain is most visible in mid-tones and less in shadows /
  /// highlights — matching real film behavior.
  static void _addGrainToImage(
      img.Image image, double intensityPercent, int seed) {
    final sigma = intensityPercent / 100.0 * 80.0; // max sigma 80 — very visible grain
    if (sigma <= 0) return;

    final rand = Random(seed);
    const inv255 = 1.0 / 255.0;

    for (final p in image) {
      final r = p.r.toDouble();
      final g = p.g.toDouble();
      final b = p.b.toDouble();

      // Luminance-aware: grain is most visible in mid-tones.
      final luma = 0.299 * r + 0.587 * g + 0.114 * b;
      final midtoneFactor =
          1.0 - ((luma * inv255 - 0.5).abs() * 1.4);
      final factor = midtoneFactor.clamp(0.25, 1.0);

      // Same noise offset for all channels → monochrome grain
      final noise = _gaussian(rand) * sigma * factor;

      p.setRgba(
        (r + noise).clamp(0, 255).toInt(),
        (g + noise).clamp(0, 255).toInt(),
        (b + noise).clamp(0, 255).toInt(),
        p.a.toInt(),
      );
    }
  }

  /// Box-Muller transform for Gaussian random numbers.
  static double _gaussian(Random rand) {
    final u1 = max(rand.nextDouble(), 1e-10);
    final u2 = rand.nextDouble();
    return sqrt(-2.0 * log(u1)) * cos(2.0 * pi * u2);
  }

  /// Add a light leak using pre-computed overlay textures.
  ///
  /// Randomly selects from cached overlay patterns, scales to target size,
  /// applies color tint, and composites via screen blend.
  static void _addLightLeakToImage(
    img.Image image,
    String style,
    double rangePercent,
    double intensityPercent,
    int seed,
  ) {
    final rand = Random(seed);
    final width = image.width;
    final height = image.height;
    final intensity = intensityPercent / 100.0;

    if (intensity <= 0) return;

    // Select random overlay from cached set
    final overlays = _LeakOverlays.overlays;
    final overlay = overlays[rand.nextInt(overlays.length)];

    // Scale overlay to target size
    final scaled = img.copyResize(overlay,
        width: width, height: height, interpolation: img.Interpolation.linear);

    // Apply color tint based on style
    _tintOverlay(scaled, style);

    // Screen blend onto image
    for (final p in image) {
      final leak = scaled.getPixel(p.x, p.y);
      final la = leak.a.toDouble();
      if (la < 1.0) continue;

      final alpha = intensity * (la / 255.0);
      if (alpha < 0.001) continue;

      final lr = leak.r.toDouble();
      final lg = leak.g.toDouble();
      final lb = leak.b.toDouble();

      final r = p.r.toDouble();
      final g = p.g.toDouble();
      final b = p.b.toDouble();

      // Screen blend: natural light accumulation
      p.setRgba(
        (255.0 - (255.0 - r) * (1.0 - lr * alpha / 255.0))
            .clamp(0, 255)
            .toInt(),
        (255.0 - (255.0 - g) * (1.0 - lg * alpha / 255.0))
            .clamp(0, 255)
            .toInt(),
        (255.0 - (255.0 - b) * (1.0 - lb * alpha / 255.0))
            .clamp(0, 255)
            .toInt(),
        p.a.toInt(),
      );
    }
  }

  /// Tint overlay pixels based on leak style.
  static void _tintOverlay(img.Image overlay, String style) {
    double rm, gm, bm;
    switch (style) {
      case 'COOL':
        rm = 0.5;
        gm = 0.7;
        bm = 1.0;
        break;
      case 'RED':
        rm = 1.0;
        gm = 0.3;
        bm = 0.25;
        break;
      case 'DOUBLE':
        for (final p in overlay) {
          final half = p.x < overlay.width ~/ 2;
          if (half) {
            p.setRgba(
              min(255, (p.r * 1.0).toInt()),
              min(255, (p.g * 0.7).toInt()),
              min(255, (p.b * 0.3).toInt()),
              p.a.toInt(),
            );
          } else {
            p.setRgba(
              min(255, (p.r * 0.5).toInt()),
              min(255, (p.g * 0.7).toInt()),
              min(255, (p.b * 1.0).toInt()),
              p.a.toInt(),
            );
          }
        }
        return;
      case 'WARM':
      default:
        rm = 1.0;
        gm = 0.75;
        bm = 0.3;
        break;
    }
    for (final p in overlay) {
      p.setRgba(
        min(255, (p.r * rm).toInt()),
        min(255, (p.g * gm).toInt()),
        min(255, (p.b * bm).toInt()),
        p.a.toInt(),
      );
    }
  }
}

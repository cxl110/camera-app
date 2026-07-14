import 'dart:math';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'neural_filter_client.dart';
import 'coreml_bridge.dart';

/// Applies film simulation filters to images.
///
/// Filter processing — tries CoreML first, then neural server, then local simulation.
///
/// 1. CoreMLBridge (iOS native) — on-device AI inference via ANE
/// 2. NeuralFilterClient (Python inference_server.py) — remote AI inference
/// 3. Dart color matrix — local simulation fallback
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
  /// Tries CoreML first, then neural inference, falls back to local simulation.
  static Future<Uint8List> apply(Uint8List input, String filterName) async {
    // Try CoreML first (on-device, fastest)
    try {
      final modelName = _filterNameToModelName(filterName);
      final coremlResult = await CoreMLBridge.applyFilter(
        imageBytes: input,
        modelName: modelName,
      );
      if (coremlResult != null) return coremlResult;
    } catch (_) {
      // CoreML not available, fall through
    }

    // Try neural backend second
    if (_neuralClient != null) {
      final result = await _neuralClient!.applyFilter(
        imageBytes: input,
        filterName: filterName,
        preview: true,
      );
      if (result != null) return result;
    }

    // Fallback to local color matrix simulation
    return _applyLocal(input, filterName);
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

  /// Add a light leak overlay starting from a random image edge.
  ///
  /// Creates a soft radial gradient on a mask, blurs it, then screen-blends
  /// the result onto the image. For DOUBLE style, two leaks from opposite
  /// edges are drawn.
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
    final maxSide = max(width, height).toDouble();
    final reach = maxSide * (0.2 + rangePercent / 100.0 * 0.8);

    // Create a transparent RGBA mask
    var mask = img.Image(width: width, height: height, numChannels: 4);
    img.fill(mask, color: img.ColorRgba8(0, 0, 0, 0));

    if (style == 'DOUBLE') {
      _drawRadialLeak(mask, width, height, rand, reach, _leakColor('WARM', rand));
      _drawRadialLeak(mask, width, height, rand, reach, _leakColor('COOL', rand));
    } else {
      _drawRadialLeak(
          mask, width, height, rand, reach, _leakColor(style, rand));
    }

    // Soften the leak edges
    final blurRadius = (reach * 0.18).clamp(15.0, 70.0).toInt();
    mask = img.gaussianBlur(mask, radius: blurRadius);

    final intensity = intensityPercent / 100.0;

    // Screen blend the leak mask onto the image.
    // We use the mask color values directly and blend with intensity.
    // Screen: out = base + leak * (1 - base/255)
    // This brightens the image where the leak is present.
    for (final p in image) {
      final leak = mask.getPixel(p.x, p.y);
      // Skip pixels with negligible leak
      final la = leak.a.toDouble();
      if (la < 1.0) continue;

      final blend = intensity * (la / 255.0);
      if (blend < 0.001) continue;

      final lr = leak.r.toDouble() * blend;
      final lg = leak.g.toDouble() * blend;
      final lb = leak.b.toDouble() * blend;

      final r = p.r.toDouble();
      final g = p.g.toDouble();
      final b = p.b.toDouble();

      // Screen blend: out = base + leak * (1 - base/255)
      p.setRgba(
        (r + lr * (1.0 - r / 255.0)).clamp(0, 255).toInt(),
        (g + lg * (1.0 - g / 255.0)).clamp(0, 255).toInt(),
        (b + lb * (1.0 - b / 255.0)).clamp(0, 255).toInt(),
        p.a.toInt(),
      );
    }
  }

  /// Draw a radial gradient leak on [mask] centered on a random edge point.
  static void _drawRadialLeak(
    img.Image mask,
    int width,
    int height,
    Random rand,
    double reach,
    img.Color color,
  ) {
    // Pick a random point on one of the four edges
    final side = rand.nextInt(4);
    double cx, cy;
    switch (side) {
      case 0: // top
        cx = rand.nextDouble() * width;
        cy = 0.0;
        break;
      case 1: // right
        cx = width.toDouble();
        cy = rand.nextDouble() * height;
        break;
      case 2: // bottom
        cx = rand.nextDouble() * width;
        cy = height.toDouble();
        break;
      default: // left
        cx = 0.0;
        cy = rand.nextDouble() * height;
        break;
    }

    final cr = color.r.toInt();
    final cg = color.g.toInt();
    final cb = color.b.toInt();

    for (final p in mask) {
      final dx = p.x.toDouble() - cx;
      final dy = p.y.toDouble() - cy;
      final dist = sqrt(dx * dx + dy * dy);
      if (dist >= reach) continue;

      final t = 1.0 - (dist / reach);
      final alpha = (t * t * 255.0).clamp(0, 255).toInt();

      // Accumulate onto mask (needed for DOUBLE style)
      final existing = mask.getPixel(p.x, p.y);
      final er = existing.r.toInt();
      final eg = existing.g.toInt();
      final eb = existing.b.toInt();
      final ea = existing.a.toInt();

      p.setRgba(
        min(255, er + (cr * alpha) ~/ 255),
        min(255, eg + (cg * alpha) ~/ 255),
        min(255, eb + (cb * alpha) ~/ 255),
        min(255, ea + alpha),
      );
    }
  }

  /// Pick a leak color based on style. Colors are full-brightness for vivid leaks.
  static img.Color _leakColor(String style, Random rand) {
    switch (style) {
      case 'COOL':
        return img.ColorRgb8(120, 200, 255);
      case 'RED':
        return img.ColorRgb8(255, 80, 100);
      case 'WARM':
      default:
        return rand.nextBool()
            ? img.ColorRgb8(255, 160, 60)
            : img.ColorRgb8(255, 220, 100);
    }
  }
}

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

  /// Add a realistic film light leak overlay.
  ///
  /// Key characteristics of real film light leaks:
  /// - Light enters from camera body edges/seams
  /// - Multiple overlapping layers with different colors
  /// - Core is bright white/yellow (overexposed), edges are orange/red
  /// - Organic, asymmetric shapes (streaks, not circles)
  /// - Screen blend mode (additive light)
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

    // How far the leak extends into the image (0-100%)
    final reach = maxSide * (0.2 + rangePercent / 100.0 * 0.55);
    final intensity = intensityPercent / 100.0;

    // Choose an edge for the leak origin
    final edge = rand.nextInt(4);

    // ── Layer 1: Wide soft glow (base layer) ──
    var glow = img.Image(width: width, height: height, numChannels: 4);
    img.fill(glow, color: img.ColorRgba8(0, 0, 0, 0));
    _drawLeakLayer(glow, width, height, rand, edge, reach * 1.2, _leakBaseColor(style, rand), 0.4);

    // ── Layer 2: Main color band ──
    _drawLeakLayer(glow, width, height, rand, edge, reach * 0.8, _leakMidColor(style, rand), 0.8);

    // ── Layer 3: Bright core streak ──
    _drawLeakLayer(glow, width, height, rand, edge, reach * 0.4, _leakCoreColor(style), 1.0);

    // ── Layer 4: Secondary highlights ──
    _drawLeakLayer(glow, width, height, rand, edge, reach * 0.6, _leakHighlightColor(style, rand), 0.6);

    // Apply gaussian blur — two passes for realistic softness
    final blur1 = (reach * 0.12).clamp(8.0, 40.0).toInt();
    glow = img.gaussianBlur(glow, radius: blur1);
    glow = img.gaussianBlur(glow, radius: (blur1 * 0.6).toInt());

    // ── DOUBLE mode: add opposite-side leak ──
    if (style == 'DOUBLE') {
      final oppEdge = (edge + 2) % 4;
      _drawLeakLayer(glow, width, height, rand, oppEdge, reach * 0.7, _leakMidColor('COOL', rand), 0.6);
      _drawLeakLayer(glow, width, height, rand, oppEdge, reach * 0.35, _leakCoreColor('COOL'), 0.8);
      glow = img.gaussianBlur(glow, radius: blur1);
    }

    // ── Screen blend onto the image ──
    for (final p in image) {
      final leak = glow.getPixel(p.x, p.y);
      final la = leak.a.toDouble();
      if (la < 1.0) continue;

      final alpha = (intensity * la / 255.0);
      if (alpha < 0.001) continue;

      final lr = leak.r.toDouble();
      final lg = leak.g.toDouble();
      final lb = leak.b.toDouble();

      final r = p.r.toDouble();
      final g = p.g.toDouble();
      final b = p.b.toDouble();

      // Screen blend: out = 1 - (1-base)(1-leak) — natural light accumulation
      final blendR = 255.0 - (255.0 - r) * (1.0 - lr * alpha / 255.0);
      final blendG = 255.0 - (255.0 - g) * (1.0 - lg * alpha / 255.0);
      final blendB = 255.0 - (255.0 - b) * (1.0 - lb * alpha / 255.0);

      p.setRgba(
        blendR.clamp(0, 255).toInt(),
        blendG.clamp(0, 255).toInt(),
        blendB.clamp(0, 255).toInt(),
        p.a.toInt(),
      );
    }
  }

  /// Draw one leak layer: an elongated streak from the edge.
  ///
  /// Uses quadratic bezier-like stretching along the edge direction
  /// and soft radial falloff perpendicular to the edge.
  static void _drawLeakLayer(
    img.Image mask,
    int width,
    int height,
    Random rand,
    int edge,
    double reach,
    img.Color color,
    double opacity,
  ) {
    final cr = color.r.toDouble();
    final cg = color.g.toDouble();
    final cb = color.b.toDouble();

    // Randomize the streak position along the edge
    final edgePos = rand.nextDouble(); // 0..1 position along edge
    final edgeSpan = 0.2 + rand.nextDouble() * 0.5; // how much of the edge it covers
    final edgeStart = (edgePos - edgeSpan * 0.5).clamp(0.0, 1.0);
    final edgeEnd = (edgePos + edgeSpan * 0.5).clamp(0.0, 1.0);

    // Randomize the perpendicular reach
    final reachVar = reach * (0.7 + rand.nextDouble() * 0.6);

    for (final p in mask) {
      double along; // position along edge (0..1)
      double perp; // distance from edge (pixels)

      switch (edge) {
        case 0: // top — leak goes downward
          along = p.x / width;
          perp = p.y.toDouble();
          break;
        case 1: // right — leak goes leftward
          along = p.y / height;
          perp = (width - 1 - p.x).toDouble();
          break;
        case 2: // bottom — leak goes upward
          along = p.x / width;
          perp = (height - 1 - p.y).toDouble();
          break;
        default: // left — leak goes rightward
          along = p.y / height;
          perp = p.x.toDouble();
          break;
      }

      // Skip if perpendicular distance exceeds reach
      if (perp >= reachVar) continue;

      // Skip if outside the edge span
      if (along < edgeStart || along > edgeEnd) continue;

      // Smooth falloff along the edge (Gaussian-ish)
      final spanCenter = (edgeStart + edgeEnd) * 0.5;
      final spanHalf = (edgeEnd - edgeStart) * 0.5;
      final alongNorm = (along - spanCenter) / spanHalf; // -1..1
      final alongFade = exp(-2.0 * alongNorm * alongNorm); // Gaussian

      // Smooth falloff perpendicular (exponential)
      final perpFade = exp(-3.0 * perp / reachVar);

      final alpha = (alongFade * perpFade * 255.0 * opacity).clamp(0.0, 255.0).toInt();
      if (alpha < 1) continue;

      // Accumulate onto mask
      final existing = mask.getPixel(p.x, p.y);
      mask.setPixelRgba(
        p.x, p.y,
        min(255, existing.r.toInt() + (cr * alpha / 255.0).toInt()),
        min(255, existing.g.toInt() + (cg * alpha / 255.0).toInt()),
        min(255, existing.b.toInt() + (cb * alpha / 255.0).toInt()),
        min(255, existing.a.toInt() + alpha),
      );
    }
  }

  // ── Color palette ──

  /// Base glow color — wide soft wash
  static img.Color _leakBaseColor(String style, Random rand) {
    switch (style) {
      case 'COOL':
        return img.ColorRgb8(80 + rand.nextInt(30), 130 + rand.nextInt(30), 200 + rand.nextInt(55));
      case 'RED':
        return img.ColorRgb8(220 + rand.nextInt(35), 50 + rand.nextInt(40), 30 + rand.nextInt(30));
      case 'WARM':
      default:
        return img.ColorRgb8(255, 120 + rand.nextInt(60), 30 + rand.nextInt(40));
    }
  }

  /// Mid-range color band — the main visible leak color
  static img.Color _leakMidColor(String style, Random rand) {
    switch (style) {
      case 'COOL':
        return img.ColorRgb8(150 + rand.nextInt(30), 200 + rand.nextInt(30), 255);
      case 'RED':
        return img.ColorRgb8(255, 70 + rand.nextInt(50), 40 + rand.nextInt(40));
      case 'WARM':
      default:
        return img.ColorRgb8(255, 170 + rand.nextInt(50), 50 + rand.nextInt(40));
    }
  }

  /// Bright core — near-white overexposed look
  static img.Color _leakCoreColor(String style) {
    switch (style) {
      case 'COOL':
        return img.ColorRgb8(220, 240, 255);
      case 'RED':
        return img.ColorRgb8(255, 180, 140);
      case 'WARM':
      default:
        return img.ColorRgb8(255, 240, 200);
    }
  }

  /// Secondary highlight — adds depth
  static img.Color _leakHighlightColor(String style, Random rand) {
    switch (style) {
      case 'COOL':
        return img.ColorRgb8(180 + rand.nextInt(30), 220 + rand.nextInt(20), 255);
      case 'RED':
        return img.ColorRgb8(255, 120 + rand.nextInt(40), 80 + rand.nextInt(30));
      case 'WARM':
      default:
        return img.ColorRgb8(255, 200 + rand.nextInt(30), 100 + rand.nextInt(30));
    }
  }
}

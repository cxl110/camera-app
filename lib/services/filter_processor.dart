import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Applies film simulation filters to images.
///
/// Prototype: Uses color matrix + curve adjustments to approximate
/// Filter4Free neural network film simulations.
/// Production: Will be replaced by CoreML inference on iOS.
class FilterProcessor {
  /// Apply a named film filter to image bytes.
  static Uint8List apply(Uint8List input, String filterName) {
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
}

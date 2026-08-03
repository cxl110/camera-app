import 'package:flutter/material.dart';

/// Represents a neural network photo filter.
///
/// Each filter is a CoreML model converted from Filter4Free's PyTorch weights.
class PhotoFilter {
  final String id;
  final String name;
  final String brand;       // e.g., "Fuji", "Kodak", "Olympus"
  final String category;    // e.g., "film", "color", "bw"
  final String modelPath;   // path to .mlmodel file relative to assets/models/
  final String thumbnailUrl;
  final String description;
  final bool isFavorite;

  const PhotoFilter({
    required this.id,
    required this.name,
    required this.brand,
    required this.category,
    required this.modelPath,
    this.thumbnailUrl = '',
    this.description = '',
    this.isFavorite = false,
  });

  PhotoFilter copyWith({
    String? id,
    String? name,
    String? brand,
    String? category,
    String? modelPath,
    String? thumbnailUrl,
    String? description,
    bool? isFavorite,
  }) {
    return PhotoFilter(
      id: id ?? this.id,
      name: name ?? this.name,
      brand: brand ?? this.brand,
      category: category ?? this.category,
      modelPath: modelPath ?? this.modelPath,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      description: description ?? this.description,
      isFavorite: isFavorite ?? this.isFavorite,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'brand': brand,
        'category': category,
        'modelPath': modelPath,
        'thumbnailUrl': thumbnailUrl,
        'description': description,
        'isFavorite': isFavorite,
      };

  factory PhotoFilter.fromJson(Map<String, dynamic> json) => PhotoFilter(
        id: json['id'] as String,
        name: json['name'] as String,
        brand: json['brand'] as String,
        category: json['category'] as String,
        modelPath: json['modelPath'] as String,
        thumbnailUrl: json['thumbnailUrl'] as String? ?? '',
        description: json['description'] as String? ?? '',
        isFavorite: json['isFavorite'] as bool? ?? false,
      );

  /// All available Filter4Free filters.
  static List<PhotoFilter> allFilters() {
    return [
      // === Fuji ===
      const PhotoFilter(
        id: 'fuji-acros', name: 'ACROS', brand: 'Fuji', category: 'bw',
        modelPath: 'assets/models/fuji_acros.mlmodel',
        description: 'Classic Fuji B&W film tones with rich tonal detail',
      ),
      const PhotoFilter(
        id: 'fuji-classic-chrome', name: 'CLASSIC CHROME', brand: 'Fuji', category: 'film',
        modelPath: 'assets/models/fuji_classic_chrome.mlmodel',
        description: 'Muted colors, the go-to for documentary style',
      ),
      const PhotoFilter(
        id: 'fuji-eterna', name: 'ETERNA', brand: 'Fuji', category: 'film',
        modelPath: 'assets/models/fuji_eterna.mlmodel',
        description: 'Soft cinematic film colors with a narrative feel',
      ),
      const PhotoFilter(
        id: 'fuji-eterna-bleach', name: 'ETERNA BLEACH BYPASS', brand: 'Fuji', category: 'film',
        modelPath: 'assets/models/fuji_eterna_bleach.mlmodel',
        description: 'Low-saturation, high-contrast cinematic bleach bypass',
      ),
      const PhotoFilter(
        id: 'fuji-classic-neg', name: 'CLASSIC Neg.', brand: 'Fuji', category: 'film',
        modelPath: 'assets/models/fuji_classic_neg.mlmodel',
        description: 'High-contrast modern negative colors',
      ),
      const PhotoFilter(
        id: 'fuji-pro-neg-hi', name: 'PRO Neg.Hi', brand: 'Fuji', category: 'film',
        modelPath: 'assets/models/fuji_pro_neg_hi.mlmodel',
        description: 'Pro portrait negative with excellent skin tones',
      ),
      const PhotoFilter(
        id: 'fuji-nostalgic-neg', name: 'NOSTALGIC Neg.', brand: 'Fuji', category: 'film',
        modelPath: 'assets/models/fuji_nostalgic_neg.mlmodel',
        description: 'Nostalgic amber-toned negative colors',
      ),
      const PhotoFilter(
        id: 'fuji-pro-neg-std', name: 'PRO Neg.Std', brand: 'Fuji', category: 'film',
        modelPath: 'assets/models/fuji_pro_neg_std.mlmodel',
        description: 'Standard pro negative, natural and soft colors',
      ),
      const PhotoFilter(
        id: 'fuji-astia', name: 'ASTIA', brand: 'Fuji', category: 'film',
        modelPath: 'assets/models/fuji_astia.mlmodel',
        description: 'Soft reversal film, great for skin tones and flowers',
      ),
      const PhotoFilter(
        id: 'fuji-provia', name: 'PROVIA', brand: 'Fuji', category: 'film',
        modelPath: 'assets/models/fuji_provia.mlmodel',
        description: 'Standard reversal film with true-to-life colors',
      ),
      const PhotoFilter(
        id: 'fuji-velvia', name: 'VELVIA', brand: 'Fuji', category: 'film',
        modelPath: 'assets/models/fuji_velvia.mlmodel',
        description: 'Vivid landscape reversal film with high saturation',
      ),
      const PhotoFilter(
        id: 'fuji-pro400h', name: 'Pro 400H', brand: 'Fuji', category: 'film',
        modelPath: 'assets/models/fuji_pro400h.mlmodel',
        description: 'Pro color negative, fresh Japanese-style tones',
      ),
      const PhotoFilter(
        id: 'fuji-superia400', name: 'Superia 400', brand: 'Fuji', category: 'film',
        modelPath: 'assets/models/fuji_superia400.mlmodel',
        description: 'Everyday color negative with vivid colors',
      ),
      const PhotoFilter(
        id: 'fuji-reala', name: 'reala', brand: 'Fuji', category: 'film',
        modelPath: 'assets/models/fuji_reala.mlmodel',
        description: 'True color reproduction, low-contrast negative',
      ),

      // === Kodak ===
      const PhotoFilter(
        id: 'kodak-color-plus', name: 'Color Plus', brand: 'Kodak', category: 'film',
        modelPath: 'assets/models/kodak_color_plus.mlmodel',
        description: 'Classic Kodak consumer color negative, warm and nostalgic',
      ),
      const PhotoFilter(
        id: 'kodak-gold200', name: 'Gold 200', brand: 'Kodak', category: 'film',
        modelPath: 'assets/models/kodak_gold200.mlmodel',
        description: 'Golden warm-toned classic daylight negative',
      ),
      const PhotoFilter(
        id: 'kodak-portra400', name: 'Portra 400', brand: 'Kodak', category: 'film',
        modelPath: 'assets/models/kodak_portra400.mlmodel',
        description: 'Benchmark pro portrait negative, perfect skin tones',
      ),
      const PhotoFilter(
        id: 'kodak-portra160nc', name: 'Portra 160NC', brand: 'Kodak', category: 'film',
        modelPath: 'assets/models/kodak_portra160nc.mlmodel',
        description: 'Low-ISO pro negative with neutral colors',
      ),
      const PhotoFilter(
        id: 'kodak-ultramax400', name: 'UltraMax 400', brand: 'Kodak', category: 'film',
        modelPath: 'assets/models/kodak_ultramax400.mlmodel',
        description: 'High-saturation general-purpose negative, rich Kodak colors',
      ),

      // === Olympus ===
      const PhotoFilter(
        id: 'olympus-vivid', name: 'VIVID', brand: 'Olympus', category: 'color',
        modelPath: 'assets/models/olympus_vivid.mlmodel',
        description: 'Olympus vivid color mode',
      ),

      // === Polaroid ===
      const PhotoFilter(
        id: 'polaroid', name: 'Polaroid', brand: 'Polaroid', category: 'film',
        modelPath: 'assets/models/polaroid.mlmodel',
        description: 'Classic Polaroid instant-film tones',
      ),
    ];
  }

  /// Filters grouped by brand for UI display.
  static Map<String, List<PhotoFilter>> groupedByBrand() {
    final filters = allFilters();
    final brands = <String, List<PhotoFilter>>{};
    for (final f in filters) {
      brands.putIfAbsent(f.brand, () => []).add(f);
    }
    return brands;
  }
}

enum WatermarkStyle {
  text,
  logo,
  signature,
  border,
}

/// Watermark configuration.
class Watermark {
  final String id;
  final WatermarkStyle style;
  final String text;
  final String? logoPath;
  final double opacity;
  final Color color;
  final Alignment alignment;

  const Watermark({
    required this.id,
    required this.style,
    this.text = '',
    this.logoPath,
    this.opacity = 0.3,
    this.color = Colors.white,
    this.alignment = Alignment.bottomRight,
  });

  Watermark copyWith({
    String? id,
    WatermarkStyle? style,
    String? text,
    String? logoPath,
    double? opacity,
    Color? color,
    Alignment? alignment,
  }) {
    return Watermark(
      id: id ?? this.id,
      style: style ?? this.style,
      text: text ?? this.text,
      logoPath: logoPath ?? this.logoPath,
      opacity: opacity ?? this.opacity,
      color: color ?? this.color,
      alignment: alignment ?? this.alignment,
    );
  }
}

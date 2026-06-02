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
        description: '富士经典黑白胶片色调，丰富的细节层次',
      ),
      const PhotoFilter(
        id: 'fuji-classic-chrome', name: 'CLASSIC CHROME', brand: 'Fuji', category: 'film',
        modelPath: 'assets/models/fuji_classic_chrome.mlmodel',
        description: '低调色彩，纪实风格的首选',
      ),
      const PhotoFilter(
        id: 'fuji-eterna', name: 'ETERNA', brand: 'Fuji', category: 'film',
        modelPath: 'assets/models/fuji_eterna.mlmodel',
        description: '电影胶片柔和色彩，富有叙事感',
      ),
      const PhotoFilter(
        id: 'fuji-eterna-bleach', name: 'ETERNA BLEACH BYPASS', brand: 'Fuji', category: 'film',
        modelPath: 'assets/models/fuji_eterna_bleach.mlmodel',
        description: '低饱和度、高对比度的电影漂白效果',
      ),
      const PhotoFilter(
        id: 'fuji-classic-neg', name: 'CLASSIC Neg.', brand: 'Fuji', category: 'film',
        modelPath: 'assets/models/fuji_classic_neg.mlmodel',
        description: '高对比度的现代负片色彩',
      ),
      const PhotoFilter(
        id: 'fuji-pro-neg-hi', name: 'PRO Neg.Hi', brand: 'Fuji', category: 'film',
        modelPath: 'assets/models/fuji_pro_neg_hi.mlmodel',
        description: '专业人像负片，肤色还原出色',
      ),
      const PhotoFilter(
        id: 'fuji-nostalgic-neg', name: 'NOSTALGIC Neg.', brand: 'Fuji', category: 'film',
        modelPath: 'assets/models/fuji_nostalgic_neg.mlmodel',
        description: '怀旧琥珀色调的负片色彩',
      ),
      const PhotoFilter(
        id: 'fuji-pro-neg-std', name: 'PRO Neg.Std', brand: 'Fuji', category: 'film',
        modelPath: 'assets/models/fuji_pro_neg_std.mlmodel',
        description: '标准专业负片，自然柔和的色彩',
      ),
      const PhotoFilter(
        id: 'fuji-astia', name: 'ASTIA', brand: 'Fuji', category: 'film',
        modelPath: 'assets/models/fuji_astia.mlmodel',
        description: '柔和的反转片，肤色与花卉出色',
      ),
      const PhotoFilter(
        id: 'fuji-provia', name: 'PROVIA', brand: 'Fuji', category: 'film',
        modelPath: 'assets/models/fuji_provia.mlmodel',
        description: '标准反转片，色彩真实还原',
      ),
      const PhotoFilter(
        id: 'fuji-velvia', name: 'VELVIA', brand: 'Fuji', category: 'film',
        modelPath: 'assets/models/fuji_velvia.mlmodel',
        description: '鲜艳的风光反转片，饱和度极高',
      ),
      const PhotoFilter(
        id: 'fuji-pro400h', name: 'Pro 400H', brand: 'Fuji', category: 'film',
        modelPath: 'assets/models/fuji_pro400h.mlmodel',
        description: '专业彩色负片，日系清新风格',
      ),
      const PhotoFilter(
        id: 'fuji-superia400', name: 'Superia 400', brand: 'Fuji', category: 'film',
        modelPath: 'assets/models/fuji_superia400.mlmodel',
        description: '日常彩色负片，色彩鲜明',
      ),
      const PhotoFilter(
        id: 'fuji-reala', name: 'reala', brand: 'Fuji', category: 'film',
        modelPath: 'assets/models/fuji_reala.mlmodel',
        description: '真实色彩还原，低反差负片',
      ),

      // === Kodak ===
      const PhotoFilter(
        id: 'kodak-color-plus', name: 'Color Plus', brand: 'Kodak', category: 'film',
        modelPath: 'assets/models/kodak_color_plus.mlmodel',
        description: '柯达经典消费级彩色负片，暖调怀旧',
      ),
      const PhotoFilter(
        id: 'kodak-gold200', name: 'Gold 200', brand: 'Kodak', category: 'film',
        modelPath: 'assets/models/kodak_gold200.mlmodel',
        description: '金色暖调的经典日光负片',
      ),
      const PhotoFilter(
        id: 'kodak-portra400', name: 'Portra 400', brand: 'Kodak', category: 'film',
        modelPath: 'assets/models/kodak_portra400.mlmodel',
        description: '专业人像负片标杆，肤色调和完美',
      ),
      const PhotoFilter(
        id: 'kodak-portra160nc', name: 'Portra 160NC', brand: 'Kodak', category: 'film',
        modelPath: 'assets/models/kodak_portra160nc.mlmodel',
        description: '低感光度专业负片，中性色彩',
      ),
      const PhotoFilter(
        id: 'kodak-ultramax400', name: 'UltraMax 400', brand: 'Kodak', category: 'film',
        modelPath: 'assets/models/kodak_ultramax400.mlmodel',
        description: '高饱和度通用负片，浓郁柯达色彩',
      ),

      // === Olympus ===
      const PhotoFilter(
        id: 'olympus-vivid', name: 'VIVID', brand: 'Olympus', category: 'color',
        modelPath: 'assets/models/olympus_vivid.mlmodel',
        description: '奥林巴斯鲜艳色彩模式',
      ),

      // === Polaroid ===
      const PhotoFilter(
        id: 'polaroid', name: 'Polaroid', brand: 'Polaroid', category: 'film',
        modelPath: 'assets/models/polaroid.mlmodel',
        description: '宝丽来即影即有经典色调',
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

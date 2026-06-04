import 'package:flutter/material.dart';

/// Horizontal scrollable film preset filter list.
///
/// Shows 4 presets at a time, swipe left for more.
/// Each preset: representative image thumbnail + filter name.
/// Selected preset: yellow highlight border.
class FilmPresets extends StatelessWidget {
  final String selectedPreset;
  final ValueChanged<String> onPresetSelected;

  const FilmPresets({
    super.key,
    required this.selectedPreset,
    required this.onPresetSelected,
  });

  // Film presets with placeholder colors for representative images
  static const _presets = [
    _PresetData('ACROS', Color(0xFF2D2D2D)),
    _PresetData('CLASSIC CHROME', Color(0xFF4A6B8A)),
    _PresetData('ETERNA', Color(0xFF6B5B4F)),
    _PresetData('CLASSIC Neg.', Color(0xFF5A7A5A)),
    _PresetData('PRO Neg.Hi', Color(0xFF8B7D6B)),
    _PresetData('VELVIA', Color(0xFF4A8B3A)),
    _PresetData('ASTIA', Color(0xFFC4956A)),
    _PresetData('PROVIA', Color(0xFF6A8BAF)),
    _PresetData('Pro 400H', Color(0xFF7BA4B8)),
    _PresetData('Portra 400', Color(0xFFC4956B)),
    _PresetData('Gold 200', Color(0xFFD4A44A)),
    _PresetData('UltraMax 400', Color(0xFFC4783C)),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section title
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text(
            'FILM PRESETS',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 2,
            ),
          ),
        ),

        // Horizontal preset list
        SizedBox(
          height: 96,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: _presets.length,
            itemBuilder: (context, index) {
              final preset = _presets[index];
              final isSelected = preset.name == selectedPreset;
              return _PresetCard(
                preset: preset,
                isSelected: isSelected,
                onTap: () => onPresetSelected(preset.name),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PresetData {
  final String name;
  final Color sampleColor; // Placeholder for filter sample image
  const _PresetData(this.name, this.sampleColor);
}

class _PresetCard extends StatelessWidget {
  final _PresetData preset;
  final bool isSelected;
  final VoidCallback onTap;

  const _PresetCard({
    required this.preset,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 72,
        margin: const EdgeInsets.symmetric(horizontal: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected ? const Color(0xFFD89A0F) : Colors.white.withValues(alpha: 0.08),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            // Preview image placeholder
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: preset.sampleColor.withValues(alpha: 0.6),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(5)),
                ),
                child: Center(
                  child: Icon(
                    Icons.filter_vintage,
                    size: 18,
                    color: Colors.white.withValues(alpha: 0.3),
                  ),
                ),
              ),
            ),
            // Filter name
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 4),
              decoration: BoxDecoration(
                color: isSelected
                    ? const Color(0xFFD89A0F).withValues(alpha: 0.15)
                    : Colors.white.withValues(alpha: 0.03),
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(4)),
              ),
              child: Text(
                _abbreviate(preset.name),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isSelected ? const Color(0xFFD89A0F) : Colors.white54,
                  fontSize: 9,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _abbreviate(String name) {
    if (name.length <= 12) return name;
    return name
        .replaceAll('CLASSIC ', 'CL.')
        .replaceAll('NOSTALGIC ', 'NOST.');
  }
}

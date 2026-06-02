import 'package:flutter/material.dart';
import '../models/filter.dart';

/// Horizontal film strip showing filter preview cards.
///
/// Inspired by Kontax-Cam's film simulation picker.
/// Displays filter thumbnails as film-strip frames with brand labels.
class FilmStrip extends StatelessWidget {
  final List<PhotoFilter> filters;
  final String? selectedId;
  final ValueChanged<PhotoFilter> onSelected;

  const FilmStrip({
    super.key,
    required this.filters,
    this.selectedId,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    // Group by brand for the strip
    final brands = <String, List<PhotoFilter>>{};
    for (final f in filters) {
      brands.putIfAbsent(f.brand, () => []).add(f);
    }

    return ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: filters.length,
      itemBuilder: (context, index) {
        final filter = filters[index];
        final isSelected = filter.name == selectedId;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: _FilterFrame(
            filter: filter,
            isSelected: isSelected,
            onTap: () => onSelected(filter),
          ),
        );
      },
    );
  }
}

/// Individual film frame card.
class _FilterFrame extends StatelessWidget {
  final PhotoFilter filter;
  final bool isSelected;
  final VoidCallback onTap;

  const _FilterFrame({
    required this.filter,
    required this.isSelected,
    required this.onTap,
  });

  Color get _brandColor {
    switch (filter.brand) {
      case 'Fuji':
        return const Color(0xFF2E8B57);
      case 'Kodak':
        return const Color(0xFFFF6B35);
      case 'Olympus':
        return const Color(0xFF2196F3);
      case 'Polaroid':
        return const Color(0xFFE91E63);
      default:
        return Colors.white38;
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 72,
        decoration: BoxDecoration(
          color: isSelected
              ? _brandColor.withOpacity(0.15)
              : Colors.white.withOpacity(0.04),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? _brandColor : Colors.white.withOpacity(0.08),
            width: isSelected ? 1.5 : 1,
          ),
          // Film frame perforations on sides
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: _brandColor.withOpacity(0.2),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  )
                ]
              : [],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Brand indicator dot
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: isSelected ? _brandColor : Colors.white24,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(height: 8),
            // Filter name
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                _abbreviate(filter.name),
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.white54,
                  fontSize: 10,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
                  letterSpacing: isSelected ? 1.2 : 0.8,
                  fontFamily: 'monospace',
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 6),
            // Film perforation dots
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                3,
                (i) => Container(
                  margin: const EdgeInsets.symmetric(horizontal: 1.5),
                  width: 2.5,
                  height: 2.5,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? _brandColor.withOpacity(0.6)
                        : Colors.white10,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _abbreviate(String name) {
    if (name.length <= 10) return name;
    return name
        .replaceAll('CLASSIC ', 'CL.')
        .replaceAll('NOSTALGIC ', 'NOST.')
        .replaceAll('BLEACH BYPASS', 'BL.BYP')
        .replaceAll('ETERNA ', 'ET.');
  }
}

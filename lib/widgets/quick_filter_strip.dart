import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/filter_service.dart';
import '../models/filter.dart';

/// Vertical quick filter selector on the right side of viewfinder.
///
/// Shows a compact vertical strip of filter brand icons for one-tap switching.
/// Inspired by Kontax-Cam's quick FX selector.
class QuickFilterStrip extends StatelessWidget {
  const QuickFilterStrip({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<FilterService>(
      builder: (context, filterService, _) {
        final grouped = PhotoFilter.groupedByBrand();
        final brands = grouped.keys.toList();

        return Container(
          width: 44,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.3),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white.withOpacity(0.06)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: brands.map((brand) {
              final filter = grouped[brand]!.first;
              final isSelected = filterService.selectedFilter?.brand == brand;

              return GestureDetector(
                onTap: () => filterService.selectFilter(filter.id),
                child: Container(
                  width: 32,
                  height: 32,
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isSelected
                        ? _brandColor(brand).withOpacity(0.3)
                        : Colors.transparent,
                    border: Border.all(
                      color: isSelected
                          ? _brandColor(brand)
                          : Colors.white.withOpacity(0.1),
                      width: isSelected ? 1.5 : 0.5,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      brand[0],
                      style: TextStyle(
                        color: isSelected ? Colors.white : Colors.white38,
                        fontSize: 12,
                        fontWeight:
                            isSelected ? FontWeight.w700 : FontWeight.w400,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        );
      },
    );
  }

  Color _brandColor(String brand) {
    switch (brand) {
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
}

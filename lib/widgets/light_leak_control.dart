import 'package:flutter/material.dart';

/// Light leak effect control section.
///
/// Layout:
///   LIGHT LEAK      30%  [ON/OFF]
///   [NONE] [WARM] [COOL] [RED] [DOUBLE]  ← style selector
///   ──────●──────────── (slider)
class LightLeakControl extends StatelessWidget {
  final bool enabled;
  final double intensity;
  final String selectedStyle;
  final ValueChanged<bool> onToggle;
  final ValueChanged<double> onIntensityChanged;
  final ValueChanged<String> onStyleChanged;

  const LightLeakControl({
    super.key,
    required this.enabled,
    required this.intensity,
    required this.selectedStyle,
    required this.onToggle,
    required this.onIntensityChanged,
    required this.onStyleChanged,
  });

  static const _styles = ['NONE', 'WARM', 'COOL', 'RED', 'DOUBLE'];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Row 1: Label + Value + Switch
          Row(
            children: [
              // Label
              const Text(
                'LIGHT LEAK',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),

              const SizedBox(width: 8),

              // Intensity value (0% when disabled)
              Text(
                '${enabled ? intensity.round() : 0}%',
                style: TextStyle(
                  color: enabled ? const Color(0xFFD89A0F) : Colors.white38,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),

              const Spacer(),

              // ON/OFF switch
              SizedBox(
                height: 28,
                child: Switch(
                  value: enabled,
                  onChanged: onToggle,
                  activeColor: const Color(0xFFD89A0F),
                  activeTrackColor: const Color(0xFFD89A0F).withValues(alpha: 0.3),
                  inactiveThumbColor: Colors.white38,
                  inactiveTrackColor: Colors.white.withValues(alpha: 0.08),
                ),
              ),
            ],
          ),

          // Row 2: Style selector (always visible)
          const SizedBox(height: 8),
          SizedBox(
            height: 32,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _styles.length,
              itemBuilder: (context, index) {
                final style = _styles[index];
                final isSelected = style == selectedStyle;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _StyleChip(
                    label: style,
                    isSelected: isSelected,
                    enabled: enabled,
                    onTap: () => onStyleChanged(style),
                  ),
                );
              },
            ),
          ),

          // Row 3: Slider (always visible, at 0 when disabled)
          const SizedBox(height: 4),
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              activeTrackColor: const Color(0xFFD89A0F),
              inactiveTrackColor: Colors.white.withValues(alpha: 0.1),
              thumbColor: const Color(0xFFD89A0F),
              overlayColor: const Color(0xFFD89A0F).withValues(alpha: 0.1),
            ),
            child: Slider(
              value: enabled ? intensity : 0,
              min: 0,
              max: 100,
              onChanged: enabled ? onIntensityChanged : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// Style chip for light leak style selection.
class _StyleChip extends StatelessWidget {
  final String label;
  final bool isSelected;
  final bool enabled;
  final VoidCallback onTap;

  const _StyleChip({
    required this.label,
    required this.isSelected,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected && enabled
              ? const Color(0xFFD89A0F).withValues(alpha: 0.2)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected && enabled
                ? const Color(0xFFD89A0F)
                : Colors.white.withValues(alpha: 0.1),
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected && enabled
                ? const Color(0xFFD89A0F)
                : Colors.white.withValues(alpha: enabled ? 0.5 : 0.2),
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
            letterSpacing: 1.2,
          ),
        ),
      ),
    );
  }
}

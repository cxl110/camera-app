import 'package:flutter/material.dart';

/// Grain intensity control section.
///
/// Layout:
///   GRAIN          40%  [ON/OFF]
///   ──────●──────────── (slider)
class GrainControl extends StatelessWidget {
  final bool enabled;
  final double intensity;
  final ValueChanged<bool> onToggle;
  final ValueChanged<double> onIntensityChanged;

  const GrainControl({
    super.key,
    required this.enabled,
    required this.intensity,
    required this.onToggle,
    required this.onIntensityChanged,
  });

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
                'GRAIN',
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

          // Row 2: Slider (always visible, at 0 when disabled)
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

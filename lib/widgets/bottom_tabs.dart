import 'package:flutter/material.dart';

/// Bottom navigation tabs for the main camera screen.
///
/// Two tabs:
/// - CAMERA: Active by default (current view)
/// - EFFECTS: Switches to filter/effects page
class BottomTabs extends StatelessWidget {
  final String activeTab; // 'camera' or 'effects'
  final ValueChanged<String> onTabChanged;

  const BottomTabs({
    super.key,
    required this.activeTab,
    required this.onTabChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 70,
      padding: const EdgeInsets.only(bottom: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF0A0A0A),
        border: Border(
          top: BorderSide(color: Color(0xFF1A1A1A), width: 1),
        ),
      ),
      child: Row(
        children: [
          // CAMERA tab
          Expanded(
            child: _TabItem(
              icon: Icons.camera_alt_outlined,
              label: 'CAMERA',
              isActive: activeTab == 'camera',
              onTap: () => onTabChanged('camera'),
            ),
          ),
          // EFFECTS tab
          Expanded(
            child: _TabItem(
              icon: Icons.auto_fix_high_outlined,
              label: 'EFFECTS',
              isActive: activeTab == 'effects',
              onTap: () => onTabChanged('effects'),
            ),
          ),
        ],
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _TabItem({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final Color color = isActive
        ? const Color(0xFFD89A0F) // Gold accent when active
        : Colors.white.withValues(alpha: 0.35);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 4),
          if (isActive)
            Container(
              width: 24,
              height: 2,
              decoration: BoxDecoration(
                color: const Color(0xFFD89A0F),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
        ],
      ),
    );
  }
}

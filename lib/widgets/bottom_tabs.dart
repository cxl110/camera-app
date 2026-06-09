import 'package:flutter/material.dart';

/// Bottom navigation tabs — CAMERA / EFFECTS / BORDERS.
class BottomTabs extends StatelessWidget {
  final String activeTab;
  final ValueChanged<String> onTabChanged;

  const BottomTabs({
    super.key,
    required this.activeTab,
    required this.onTabChanged,
  });

  static const _tabs = [
    _TabData('CAMERA', Icons.camera_alt_outlined),
    _TabData('EFFECTS', Icons.auto_fix_high_outlined),
    _TabData('BORDERS', Icons.crop_free),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 70,
      padding: const EdgeInsets.only(bottom: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF0A0A0A),
        border: Border(top: BorderSide(color: Color(0xFF1A1A1A), width: 1)),
      ),
      child: Row(
        children: _tabs.map((tab) {
          final isActive = activeTab == tab.label;
          return Expanded(
            child: _TabItem(
              icon: tab.icon,
              label: tab.label,
              isActive: isActive,
              onTap: () => onTabChanged(tab.label),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _TabData {
  final String label;
  final IconData icon;
  const _TabData(this.label, this.icon);
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
        ? const Color(0xFFD89A0F)
        : Colors.white.withValues(alpha: 0.35);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 4),
          if (isActive)
            Container(
              width: 20,
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

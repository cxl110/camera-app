import 'package:flutter/material.dart';

/// Top toolbar with camera controls.
///
/// Flash, grid toggle, timer, and settings buttons.
class TopToolbar extends StatelessWidget {
  final bool hasFlash;
  final VoidCallback onFlashToggle;
  final VoidCallback onGridToggle;

  const TopToolbar({
    super.key,
    required this.hasFlash,
    required this.onFlashToggle,
    required this.onGridToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // Flash button
          _ToolbarButton(
            icon: hasFlash ? Icons.flash_on : Icons.flash_off,
            isActive: hasFlash,
            onTap: onFlashToggle,
            tooltip: '闪光灯',
          ),

          // Timer button
          _ToolbarButton(
            icon: Icons.timer_outlined,
            isActive: false,
            onTap: () {},
            tooltip: '定时',
          ),

          const Spacer(),

          // App title
          Text(
            'KONTAX',
            style: TextStyle(
              color: Colors.white.withOpacity(0.4),
              fontSize: 18,
              fontWeight: FontWeight.w300,
              letterSpacing: 6,
              fontFamily: 'monospace',
            ),
          ),

          const Spacer(),

          // Grid toggle
          _ToolbarButton(
            icon: Icons.grid_4x4,
            isActive: true,
            onTap: onGridToggle,
            tooltip: '网格',
          ),

          // Settings
          _ToolbarButton(
            icon: Icons.tune,
            isActive: false,
            onTap: () {},
            tooltip: '设置',
          ),
        ],
      ),
    );
  }
}

/// Individual toolbar icon button with active state.
class _ToolbarButton extends StatelessWidget {
  final IconData icon;
  final bool isActive;
  final VoidCallback onTap;
  final String tooltip;

  const _ToolbarButton({
    required this.icon,
    required this.isActive,
    required this.onTap,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: isActive
                ? Colors.white.withOpacity(0.1)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Icon(
            icon,
            color: isActive ? Colors.white : Colors.white38,
            size: 20,
          ),
        ),
      ),
    );
  }
}

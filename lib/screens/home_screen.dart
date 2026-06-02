import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'camera_connect_screen.dart';
import 'gallery_screen.dart';
import '../services/filter_service.dart';
import '../services/camera_service.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
              child: Row(
                children: [
                  const Icon(Icons.camera_alt, color: Colors.white70, size: 28),
                  const SizedBox(width: 12),
                  Text(
                    '相机伴侣',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.settings_outlined, color: Colors.white60),
                    onPressed: () {
                      // TODO: Settings screen
                    },
                  ),
                ],
              ),
            ),

            const Divider(height: 1, color: Colors.white10),

            // Main grid
            Expanded(
              child: GridView.count(
                crossAxisCount: 2,
                padding: const EdgeInsets.all(20),
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                children: [
                  _HomeCard(
                    icon: Icons.wifi,
                    title: '连接相机',
                    subtitle: 'WiFi传输照片',
                    color: const Color(0xFF2D5BD8),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ChangeNotifierProvider(
                          create: (_) => CameraService(),
                          child: const CameraConnectScreen(),
                        ),
                      ),
                    ),
                  ),
                  _HomeCard(
                    icon: Icons.photo_library_outlined,
                    title: '相册',
                    subtitle: '浏览 & 管理照片',
                    color: const Color(0xFF8B3DC1),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const GalleryScreen()),
                    ),
                  ),
                  _HomeCard(
                    icon: Icons.auto_fix_high,
                    title: '滤镜工坊',
                    subtitle: '${PhotoFilter.allFilters().length}款AI滤镜',
                    color: const Color(0xFFD44B8E),
                    onTap: () {
                      // TODO: Open filter workshop / quick edit
                    },
                  ),
                  _HomeCard(
                    icon: Icons.share_outlined,
                    title: '分享',
                    subtitle: '导出 & 水印',
                    color: const Color(0xFF2D9B67),
                    onTap: () {
                      // TODO: Share screen
                    },
                  ),
                ],
              ),
            ),

            // Recent section
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  Text(
                    '最近滤镜',
                    style: TextStyle(color: Colors.white54, fontSize: 14),
                  ),
                  Spacer(),
                  Text(
                    '查看全部',
                    style: TextStyle(color: Colors.white30, fontSize: 13),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 80,
              child: Consumer<FilterService>(
                builder: (context, filterService, _) {
                  final recents = filterService.recentFilters;
                  if (recents.isEmpty) {
                    return const Center(
                      child: Text(
                        '选择照片开始编辑',
                        style: TextStyle(color: Colors.white24, fontSize: 13),
                      ),
                    );
                  }
                  return ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemCount: recents.length,
                    itemBuilder: (context, index) {
                      final filter = recents[index];
                      return _FilterChip(filter: filter);
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _HomeCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _HomeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white10),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 24),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final PhotoFilter filter;
  const _FilterChip({required this.filter});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => context.read<FilterService>().selectFilter(filter.id),
      child: Container(
        width: 72,
        margin: const EdgeInsets.only(right: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              filter.brand,
              style: const TextStyle(color: Colors.white38, fontSize: 9),
            ),
            const SizedBox(height: 2),
            Text(
              filter.name,
              style: const TextStyle(color: Colors.white, fontSize: 12),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

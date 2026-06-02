import 'package:flutter/material.dart';

class GalleryScreen extends StatelessWidget {
  const GalleryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('相册'),
        actions: [
          IconButton(
            icon: const Icon(Icons.grid_view_outlined),
            onPressed: () {
              // TODO: Toggle grid/list view
            },
          ),
        ],
      ),
      body: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.photo_library_outlined, size: 64, color: Colors.white12),
            SizedBox(height: 16),
            Text(
              '还没有照片',
              style: TextStyle(color: Colors.white38, fontSize: 16),
            ),
            SizedBox(height: 8),
            Text(
              '连接相机后下载的照片会出现在这里',
              style: TextStyle(color: Colors.white20, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

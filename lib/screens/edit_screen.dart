import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../services/filter_service.dart';
import '../services/image_service.dart';
import '../models/filter.dart';

/// Photo editing screen with neural network filter application.
class EditScreen extends StatefulWidget {
  final File imageFile;
  final String imageName;

  const EditScreen({
    super.key,
    required this.imageFile,
    required this.imageName,
  });

  @override
  State<EditScreen> createState() => _EditScreenState();
}

class _EditScreenState extends State<EditScreen> {
  File? _filteredFile;
  bool _showOriginal = false;
  final double _intensity = 0.5;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(
          widget.imageName,
          style: const TextStyle(fontSize: 15),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.compare),
            onPressed: () => setState(() => _showOriginal = !_showOriginal),
            tooltip: '对比原图',
          ),
          IconButton(
            icon: const Icon(Icons.water_drop_outlined),
            onPressed: () {
              // TODO: Add watermark
            },
            tooltip: '水印',
          ),
          IconButton(
            icon: const Icon(Icons.save_outlined),
            onPressed: _saveImage,
            tooltip: '保存',
          ),
          IconButton(
            icon: const Icon(Icons.share_outlined),
            onPressed: _shareImage,
            tooltip: '分享',
          ),
        ],
      ),
      body: Column(
        children: [
          // Image display area
          Expanded(
            child: GestureDetector(
              onLongPressStart: (_) => setState(() => _showOriginal = true),
              onLongPressEnd: (_) => setState(() => _showOriginal = false),
              child: Center(
                child: _showOriginal
                    ? Image.file(widget.imageFile, fit: BoxFit.contain)
                    : (_filteredFile != null
                        ? Image.file(_filteredFile!, fit: BoxFit.contain)
                        : Image.file(widget.imageFile, fit: BoxFit.contain)),
              ),
            ),
          ),

          // Intensity slider
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              children: [
                const Icon(Icons.opacity, color: Colors.white38, size: 18),
                Expanded(
                  child: Slider(
                    value: _intensity,
                    onChanged: (v) {
                      // TODO: Adjust filter intensity
                    },
                    activeColor: const Color(0xFFD44B8E),
                    inactiveColor: Colors.white10,
                  ),
                ),
                Text(
                  '${(_intensity * 100).round()}%',
                  style: const TextStyle(color: Colors.white38, fontSize: 13),
                ),
              ],
            ),
          ),

          // Filter picker
          SizedBox(
            height: 140,
            child: Consumer<FilterService>(
              builder: (context, filterService, _) {
                final grouped = filterService.groupedFilters;
                final brands = grouped.keys.toList();

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Brand tabs
                    SizedBox(
                      height: 36,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: brands.length,
                        itemBuilder: (context, index) {
                          final brand = brands[index];
                          final isSelected = filterService.selectedFilter?.brand == brand;
                          return GestureDetector(
                            onTap: () {
                              final first = grouped[brand]!.first;
                              filterService.selectFilter(first.id);
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14),
                              margin: const EdgeInsets.only(right: 8),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? const Color(0xFFD44B8E).withOpacity(0.2)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(
                                  color: isSelected
                                      ? const Color(0xFFD44B8E)
                                      : Colors.white10,
                                ),
                              ),
                              child: Center(
                                child: Text(
                                  brand,
                                  style: TextStyle(
                                    color: isSelected ? Colors.white : Colors.white38,
                                    fontSize: 13,
                                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 10),
                    // Filter list for selected brand
                    Expanded(
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: grouped[filterService.selectedFilter?.brand]?.length ?? 0,
                        itemBuilder: (context, index) {
                          final filters = grouped[filterService.selectedFilter?.brand ?? brands.first]!;
                          final filter = filters[index];
                          final isActive = filterService.selectedFilter?.id == filter.id;

                          return GestureDetector(
                            onTap: () {
                              filterService.selectFilter(filter.id);
                              _applyFilter(context, filter);
                            },
                            child: Container(
                              width: 80,
                              margin: const EdgeInsets.only(right: 10),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isActive
                                      ? const Color(0xFFD44B8E)
                                      : Colors.white10,
                                  width: isActive ? 2 : 1,
                                ),
                                color: const Color(0xFF1A1A2E),
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    filter.category == 'bw'
                                        ? Icons.filter_b_and_w
                                        : Icons.filter_vintage,
                                    color: isActive ? Colors.white : Colors.white38,
                                    size: 28,
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    filter.name,
                                    style: TextStyle(
                                      color: isActive ? Colors.white : Colors.white60,
                                      fontSize: 10,
                                      fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                                    ),
                                    textAlign: TextAlign.center,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Future<void> _applyFilter(BuildContext context, PhotoFilter filter) async {
    final filterService = context.read<FilterService>();
    try {
      final result = await filterService.applyFilterPreview(widget.imageFile);
      if (mounted) {
        final tempDir = Directory.systemTemp;
        final tempFile = File('${tempDir.path}/filtered_preview.jpg');
        await tempFile.writeAsBytes(result);
        setState(() => _filteredFile = tempFile);
        filterService.markFilterUsed(filter.id);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('滤镜应用失败: $e')),
        );
      }
    }
  }

  Future<void> _saveImage() async {
    if (_filteredFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择滤镜')),
      );
      return;
    }

    try {
      final imageService = context.read<ImageService>();
      final bytes = await _filteredFile!.readAsBytes();
      await imageService.saveEditedImage(bytes, widget.imageName);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已保存'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _shareImage() async {
    // TODO: Implement share with share_plus
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('分享功能开发中')),
    );
  }
}

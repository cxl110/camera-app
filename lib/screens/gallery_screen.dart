import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image_gallery_saver/image_gallery_saver.dart';
import '../services/camera_protocol.dart';
import '../services/http_camera_protocol.dart';
import '../services/image_service.dart';
import '../services/coreml_bridge.dart';
import '../services/app_log.dart';

/// iOS-style photo gallery browser.
///
/// - Grid of thumbnails (3 columns)
/// - Long press to enter selection mode
/// - Multi-select for download / delete
/// - Single photo select → edit (EFFECTS)
/// - Download includes x2 CoreML upscale with progress bar
class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  List<CameraPhoto> _photos = [];
  bool _loading = true;
  String? _error;

  // Selection
  bool _selectMode = false;
  final Set<String> _selectedIds = {};

  // Download progress
  bool _downloading = false;
  int _downloadIndex = 0;
  int _downloadTotal = 0;
  double _currentProgress = 0.0; // 0..1 for current file

  CameraProtocol get _protocol => context.read<CameraProtocol>();

  @override
  void initState() {
    super.initState();
    _loadPhotos();
  }

  Future<void> _loadPhotos() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final result = await _protocol.listPhotos(limit: 200);
      if (!mounted) return;
      setState(() {
        _photos = result.photos;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '加载失败: $e';
        _loading = false;
      });
    }
  }

  void _toggleSelect(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
        if (_selectedIds.isEmpty) _selectMode = false;
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _enterSelectMode() {
    setState(() => _selectMode = true);
  }

  void _exitSelectMode() {
    setState(() {
      _selectMode = false;
      _selectedIds.clear();
    });
  }

  void _onTap(String id) {
    if (_selectMode) {
      _toggleSelect(id);
      return;
    }
    // Single tap → edit (only jpg)
    final photo = _photos.firstWhere((p) => p.id == id);
    if (photo.name.toUpperCase().startsWith('VID_')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('视频不支持编辑'), backgroundColor: Color(0xFF1A1A2E)),
      );
      return;
    }
    _editSingle(photo);
  }

  Future<void> _editSingle(CameraPhoto photo) async {
    // Download full image
    _showDownloadingSingle();
    try {
      Uint8List? bytes;
      if (_protocol is HttpCameraProtocol) {
        bytes = await (_protocol as HttpCameraProtocol).downloadPhotoBytes(photo.id);
      }
      if (bytes == null) {
        bytes = photo.fullImage ?? photo.thumbnail;
      }
      if (bytes == null || !mounted) return;

      // x2 upscale
      try {
        final upscaled = await CoreMLBridge.upscalePhoto(imageBytes: bytes);
        if (upscaled != null) {
          final isBlack = _isAllBlack(upscaled);
          if (!isBlack) bytes = upscaled;
        }
      } catch (_) {}

      if (!mounted) return;
      final finalBytes = bytes;
      if (finalBytes == null) return;
      Navigator.pop(context); // dismiss progress
      context.read<ImageService>().loadPhoto(finalBytes, name: photo.name);
      Navigator.pop(context); // back to home → user can go to EFFECTS
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context); // dismiss progress
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('下载失败: $e'), backgroundColor: Colors.red),
      );
    }
  }

  void _showDownloadingSingle() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: SizedBox(
          width: 48, height: 48,
          child: CircularProgressIndicator(strokeWidth: 3, color: Color(0xFFD89A0F)),
        ),
      ),
    );
  }

  Future<void> _downloadSelected() async {
    if (_selectedIds.isEmpty) return;

    final selected = _photos.where((p) => _selectedIds.contains(p.id)).toList();
    setState(() {
      _downloading = true;
      _downloadIndex = 0;
      _downloadTotal = selected.length;
      _currentProgress = 0.0;
    });

    final imageService = context.read<ImageService>();

    for (var i = 0; i < selected.length; i++) {
      if (!mounted) return;
      setState(() {
        _downloadIndex = i;
        _currentProgress = 0.0;
      });

      final photo = selected[i];

      try {
        // Download full image
        Uint8List? bytes;
        if (_protocol is HttpCameraProtocol) {
          bytes = await (_protocol as HttpCameraProtocol).downloadPhotoBytes(photo.id);
        }
        if (bytes == null) continue;

        // x2 upscale
        setState(() => _currentProgress = 0.5);
        try {
          final upscaled = await CoreMLBridge.upscalePhoto(imageBytes: bytes);
          if (upscaled != null && !_isAllBlack(upscaled)) {
            bytes = upscaled;
          }
        } catch (_) {}

        setState(() => _currentProgress = 0.8);

        // Save
        final saveBytes = bytes;
        if (saveBytes != null) {
          await imageService.saveWithUpscale(saveBytes, photo.name);
        }
      } catch (_) {
        // Continue with next photo
      }

      setState(() => _currentProgress = 1.0);
    }

    if (!mounted) return;
    setState(() {
      _downloading = false;
      _selectMode = false;
      _selectedIds.clear();
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已保存 $_downloadTotal 张照片'),
        backgroundColor: const Color(0xFF2E7D32),
      ),
    );
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('删除确认', style: TextStyle(color: Colors.white)),
        content: Text('确定要删除 ${_selectedIds.length} 张照片吗？\n此操作不可撤销。',
            style: const TextStyle(color: Colors.white60)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Colors.white38)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    for (final id in _selectedIds.toList()) {
      await _protocol.deletePhoto(id);
    }

    setState(() {
      _selectMode = false;
      _selectedIds.clear();
    });

    await _loadPhotos();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已删除'), backgroundColor: Color(0xFF2E7D32)),
    );
  }

  Future<void> _exportLogs() async {
    try {
      final logText = await AppLog.readAllLogs();
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/logs_export.txt');
      await file.writeAsString(logText);
      // Save to gallery so user can find it in Files app
      await ImageGallerySaver.saveFile(file.path, name: 'camera_app_logs.txt');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('日志已导出到文件'), backgroundColor: Color(0xFF2E7D32)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败: $e'), backgroundColor: Colors.red),
      );
    }
  }

  bool _isAllBlack(Uint8List bytes) {
    try {
      // Quick check: sample first 1000 pixels
      final view = bytes.buffer.asByteData();
      final len = bytes.length;
      for (var i = 0; i < 1000 && i * 3 + 2 < len; i++) {
        final r = view.getUint8(i * 3);
        final g = view.getUint8(i * 3 + 1);
        final b = view.getUint8(i * 3 + 2);
        if (r > 10 || g > 10 || b > 10) return false;
      }
      return true;
    } catch (_) {
      return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: _buildAppBar(),
      body: _buildBody(),
      bottomNavigationBar: (_selectMode && !_downloading) ? _buildBottomBar() : null,
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xFF0A0A0A),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, color: Colors.white70),
        onPressed: () => Navigator.pop(context),
      ),
      title: Text(
        _selectMode ? '已选 ${_selectedIds.length} 张' : '相机照片',
        style: const TextStyle(color: Colors.white, fontSize: 16),
      ),
      actions: [
        if (_selectMode)
          TextButton(
            onPressed: _exitSelectMode,
            child: const Text('取消', style: TextStyle(color: Color(0xFFD89A0F))),
          )
        else ...[
          TextButton(
            onPressed: _photos.isNotEmpty ? _enterSelectMode : null,
            child: const Text('选择', style: TextStyle(color: Color(0xFFD89A0F), fontSize: 14)),
          ),
          IconButton(
            icon: const Icon(Icons.bug_report_outlined, color: Colors.white54, size: 20),
            onPressed: _exportLogs,
            tooltip: '导出日志',
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white54, size: 22),
            onPressed: _loading ? null : _loadPhotos,
            tooltip: '刷新',
          ),
        ],
      ],
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFD89A0F)),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.white38)),
            const SizedBox(height: 16),
            FilledButton(onPressed: _loadPhotos, child: const Text('重试')),
          ],
        ),
      );
    }

    if (_photos.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.photo_library_outlined, size: 64,
                color: Colors.white.withValues(alpha: 0.12)),
            const SizedBox(height: 16),
            const Text('相机中没有照片', style: TextStyle(color: Colors.white38, fontSize: 16)),
            const SizedBox(height: 8),
            Text('使用相机快门拍摄照片',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.2), fontSize: 13)),
          ],
        ),
      );
    }

    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: _loadPhotos,
          child: GridView.builder(
            padding: const EdgeInsets.all(2),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 2,
              mainAxisSpacing: 2,
            ),
            itemCount: _photos.length,
            itemBuilder: (ctx, i) => _buildPhotoTile(_photos[i]),
          ),
        ),

        // Download progress overlay
        if (_downloading) _buildDownloadOverlay(),
      ],
    );
  }

  Widget _buildPhotoTile(CameraPhoto photo) {
    final isSelected = _selectedIds.contains(photo.id);
    final isVideo = photo.name.toUpperCase().startsWith('VID_');

    return GestureDetector(
      onTap: () => _onTap(photo.id),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Thumbnail
          if (photo.thumbnail != null)
            Image.memory(photo.thumbnail!, fit: BoxFit.cover)
          else
            Container(
              color: const Color(0xFF1A1A2E),
              child: Center(
                child: Icon(
                  isVideo ? Icons.videocam : Icons.image,
                  color: Colors.white.withValues(alpha: 0.2),
                  size: 32,
                ),
              ),
            ),

          // Video badge
          if (isVideo)
            Positioned(
              bottom: 4, right: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.play_arrow, color: Colors.white, size: 14),
                    Text('视频', style: TextStyle(color: Colors.white, fontSize: 10)),
                  ],
                ),
              ),
            ),

          // Selection checkmark
          if (_selectMode)
            Positioned(
              top: 4, right: 4,
              child: Container(
                width: 22, height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isSelected ? const Color(0xFFD89A0F) : Colors.black.withValues(alpha: 0.5),
                  border: Border.all(
                    color: isSelected ? const Color(0xFFD89A0F) : Colors.white38,
                    width: 2,
                  ),
                ),
                child: isSelected
                    ? const Icon(Icons.check, color: Colors.black, size: 14)
                    : null,
              ),
            ),

          // Dimming overlay when selected
          if (isSelected)
            Positioned.fill(
              child: Container(color: Colors.white.withValues(alpha: 0.15)),
            ),
        ],
      ),
    );
  }

  Widget _buildDownloadOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.85),
        child: Center(
          child: Container(
            width: 280,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A2E),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('正在保存',
                    style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text('${_downloadIndex + 1} / $_downloadTotal 张',
                    style: const TextStyle(color: Colors.white38, fontSize: 13)),
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: _currentProgress > 0 ? _currentProgress : null,
                    backgroundColor: Colors.white10,
                    color: const Color(0xFFD89A0F),
                    minHeight: 6,
                  ),
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: _downloadTotal > 0
                      ? (_downloadIndex + _currentProgress) / _downloadTotal
                      : null,
                  backgroundColor: Colors.white10,
                  color: const Color(0xFF2D5BD8),
                  minHeight: 3,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    final selected = _photos.where((p) => _selectedIds.contains(p.id)).toList();
    final hasVideo = selected.any((p) => p.name.toUpperCase().startsWith('VID_'));
    final canEdit = _selectedIds.length == 1 && !hasVideo;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      decoration: const BoxDecoration(
        color: Color(0xFF14141E),
        border: Border(top: BorderSide(color: Colors.white10)),
      ),
      child: Row(
        children: [
          // Download
          Expanded(
            child: FilledButton.icon(
              onPressed: _downloadSelected,
              icon: const Icon(Icons.download, size: 18),
              label: const Text('下载'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF2D5BD8),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          const SizedBox(width: 12),

          // Edit (single jpg only)
          Expanded(
            child: FilledButton.icon(
              onPressed: canEdit
                  ? () => _editSingle(selected.first)
                  : () {
                      if (_selectedIds.length > 1) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('编辑只能选择一张照片'),
                            backgroundColor: Color(0xFF1A1A2E),
                          ),
                        );
                      } else if (hasVideo) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('视频不支持编辑'),
                            backgroundColor: Color(0xFF1A1A2E),
                          ),
                        );
                      }
                    },
              icon: Icon(Icons.tune, size: 18,
                  color: canEdit ? Colors.white : Colors.white38),
              label: Text('编辑',
                  style: TextStyle(color: canEdit ? Colors.white : Colors.white38)),
              style: FilledButton.styleFrom(
                backgroundColor: canEdit
                    ? const Color(0xFF8B3DC1)
                    : const Color(0xFF3A3A4A),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          const SizedBox(width: 12),

          // Delete
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _deleteSelected,
              icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
              label: const Text('删除', style: TextStyle(color: Colors.red)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.red),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
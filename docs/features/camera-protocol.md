# 相机 WiFi 协议接口

> 状态: 接口定义阶段 | 最后更新: 2026-06-04

## 概览

相机伴侣 APP 通过 WiFi 与相机通信。不同品牌相机使用不同的 HTTP API。
本文档定义 APP 需要的**所有接口**，以及各品牌的实现映射。

## 页面 → 接口映射

| 页面 | 需要的接口 | 触发时机 |
|------|-----------|---------|
| **CAMERA 首页** | 连接状态、实时取景、拍照、录像、缩略图 | 持续 |
| **EFFECTS 滤镜页** | 照片列表、照片下载 | 点击文件夹、选择照片 |
| **相机连接页** | 设备发现、手动连接、照片浏览 | 进入页面 |

---

## 接口清单

### 1. 设备发现与连接

#### 1.1 探测相机 `discover()`
**用途**: 扫描当前 WiFi 网络中是否有相机设备  
**调用**: 进入连接页时自动触发，或点击"自动检测"

| 项目 | 说明 |
|------|------|
| 输入 | 无 |
| 输出 | `CameraDevice { brand, model, baseUrl, apiVersion }` |
| 超时 | 单次探测 3 秒，总扫描 15 秒 |
| 实现思路 | 依次探测已知 IP/端口组合 |

**各品牌实现**:
| 品牌 | 探测地址 | 探测方法 |
|------|---------|---------|
| Sony | `http://192.168.122.1:8080/` | GET `/sony/camera` |
| Fujifilm | `http://192.168.0.1/` | GET `/info` |
| Canon | `http://192.168.1.1/` | GET `/ccapi/ver100/contents` |
| Nikon | `http://192.168.1.1/` | GET `/v1/devices` |
| 通用 PTP/IP | `192.168.1.1:15740` | PTP/IP Init Command Request |

#### 1.2 获取设备信息 `getDeviceInfo()`
**用途**: 获取相机型号、固件版本、支持的功能列表  
**调用**: 连接成功后立即调用

| 项目 | 说明 |
|------|------|
| 输入 | 无 |
| 输出 | `DeviceInfo { model, firmwareVersion, supportedApis, batteryLevel, storageRemaining }` |

---

### 2. 实时取景 `startLiveView()` / `stopLiveView()`

**用途**: 获取相机实时画面流，显示在取景器中  
**调用**: CAMERA 页面激活且 WiFi 已连接时

| 项目 | 说明 |
|------|------|
| 输入 | 无 |
| 输出 | `Stream<Uint8List>` JPEG 帧流 |
| 帧率 | 目标 15-30 fps |
| 分辨率 | 640x480 或 1024x768（预览级） |
| 停止 | 页面退出或断开连接时调用 `stopLiveView()` |

**各品牌实现**:
| 品牌 | 端点 | 格式 |
|------|------|------|
| Sony | POST `/sony/camera` `startLiveview` | JSON 含 JPEG URL，轮询拉取 |
| Fujifilm | GET `/liveview` | MJPEG 流 |
| Canon | GET `/ccapi/ver100/liveview` | MJPEG 帧 |
| 通用 | GET `/liveview` | MJPEG 或 frame 轮询 |

---

### 3. 拍照 `capturePhoto()`

**用途**: 触发相机快门，拍摄照片  
**调用**: 用户点击快门按钮（白色圆形按钮）

| 项目 | 说明 |
|------|------|
| 输入 | 无（可选: `{ focusMode, exposureCompensation }`) |
| 输出 | `CapturedPhoto { photoId, thumbnailUrl?, downloadUrl, sizeBytes }` |
| 超时 | 10 秒 |
| 后续 | 拍摄完成后自动获取缩略图，显示在快门按钮左侧 |

**各品牌实现**:
| 品牌 | 端点 | 方法 |
|------|------|------|
| Sony | `/sony/camera` `actTakePicture` | POST JSON-RPC |
| Fujifilm | `/capture` | POST |
| Canon | `/ccapi/ver100/shoot` | POST |
| Nikon | `/v1/capture` | POST |

---

### 4. 录像 `startRecording()` / `stopRecording()`

**用途**: 开始/停止视频录制  
**调用**: 用户点击录像按钮（红色圆形按钮）

| 项目 | 说明 |
|------|------|
| `startRecording()` | 开始录制，返回 `{ status: "recording" }` |
| `stopRecording()` | 停止录制，返回 `{ videoId, downloadUrl, duration }` |
| 超时 | start 3 秒，stop 5 秒 |

---

### 5. 拍照缩略图 `getThumbnail(photoId)`

**用途**: 获取已拍照片的小尺寸预览图  
**调用**: 拍照完成后自动调用；浏览照片列表时

| 项目 | 说明 |
|------|------|
| 输入 | `photoId` (拍照返回的 ID) |
| 输出 | `Uint8List` JPEG 缩略图，约 160x120 |
| 超时 | 5 秒 |

---

### 6. 照片列表 `listPhotos(options?)`

**用途**: 获取相机存储卡上的照片列表  
**调用**: 点击 EFFECTS 页相册按钮；相机连接页浏览模式

| 项目 | 说明 |
|------|------|
| 输入 | `{ offset?, limit?, sortBy?, dateFrom?, dateTo? }` |
| 输出 | `List<CameraPhoto> [{ id, name, dateTaken, sizeBytes, thumbnailUrl, downloadUrl }]` |
| 分页 | 默认 50 张/页 |
| **EFFECTS 页使用场景** | 用户点击右上文件夹，选择照片进行滤镜编辑 |

**EFFECTS 页照片选择流程**:
```
[文件夹按钮] → listPhotos() → 展示照片列表 → 用户点击某张
→ downloadPhoto(id) → 显示在 EFFECTS 预览区 → 应用滤镜
```

---

### 7. 下载照片 `downloadPhoto(photoId, quality?)`

**用途**: 从相机下载全分辨率照片文件  
**调用**: EFFECTS 页用户选择照片后；传输页批量下载

| 项目 | 说明 |
|------|------|
| 输入 | `photoId`, `quality`: "original" (默认) / "medium" / "small" |
| 输出 | `Stream<DownloadProgress>` → 完成后 `File` |
| 超时 | 60 秒（大文件） |
| 进度 | 实时回调 `{ received, total }` |

**EFFECTS 页使用**: 用户选择照片后，先下载 medium 质量用于编辑预览，保存时下载 original。

---

### 8. 删除照片 `deletePhoto(photoId)`

**用途**: 删除相机上的照片  
**调用**: 照片列表页用户操作

| 项目 | 说明 |
|------|------|
| 输入 | `photoId` |
| 输出 | `{ success: bool }` |

---

### 9. 连接状态 `getConnectionStatus()`

**用途**: 检查 WiFi 连接状态和设备可达性  
**调用**: CAMERA 页面定期轮询（每 5 秒）

| 项目 | 说明 |
|------|------|
| 输出 | `ConnectionStatus { connected, ssid, signalStrength, cameraBrand, cameraModel }` |
| 影响 | 控制 WiFi 图标颜色、取景器显示、EFFECTS 页可访问性 |

---

## 数据模型

```dart
class CameraDevice {
  final String brand;       // "Sony" | "Fujifilm" | "Canon" | "Nikon" | "Unknown"
  final String model;       // "A7M4", "X-T5", "EOS R5"
  final String baseUrl;     // "http://192.168.122.1:8080"
  final String apiVersion;  // "1.0"
}

class DeviceInfo {
  final String model;
  final String firmwareVersion;
  final List<String> supportedApis;
  final int batteryLevel;      // 0-100
  final int storageRemaining;  // bytes
}

class CameraPhoto {
  final String id;
  final String name;           // "DSC00001.JPG"
  final DateTime dateTaken;
  final int sizeBytes;
  final String thumbnailUrl;
  final String downloadUrl;
}

class ConnectionStatus {
  final bool connected;
  final String? ssid;
  final int? signalStrength;   // 0-3
  final String? cameraBrand;
  final String? cameraModel;
}

class DownloadProgress {
  final int received;
  final int total;
  double get percent => total > 0 ? received / total : 0;
}
```

## 接口汇总表

| # | 接口 | 页面 | 优先级 |
|---|------|------|:--:|
| 1 | `discover()` | 连接页 | P0 |
| 2 | `getDeviceInfo()` | 连接页 | P1 |
| 3 | `startLiveView()` / `stopLiveView()` | CAMERA | P0 |
| 4 | `capturePhoto()` | CAMERA | P0 |
| 5 | `startRecording()` / `stopRecording()` | CAMERA | P1 |
| 6 | `getThumbnail(photoId)` | CAMERA | P0 |
| 7 | `listPhotos(options?)` | EFFECTS / 连接页 | P0 |
| 8 | `downloadPhoto(photoId, quality?)` | EFFECTS | P0 |
| 9 | `deletePhoto(photoId)` | (照片列表页) | P2 |
| 10 | `getConnectionStatus()` | CAMERA / EFFECTS | P0 |

## 品牌适配计划

| 品牌 | 实时取景 | 拍照 | 照片列表 | 下载 | 适配难度 |
|------|:--:|:--:|:--:|:--:|:--:|
| **Sony** | ✅ | ✅ | ✅ | ✅ | 中等（JSON-RPC 协议） |
| **Fujifilm** | ✅ | ✅ | ✅ | ✅ | 简单（RESTful HTTP） |
| **Canon** | ✅ | ✅ | ✅ | ✅ | 中等（CCAPI） |
| **Nikon** | ✅ | ✅ | ✅ | ✅ | 中等 |
| **GoPro** | ✅ | ✅ | ✅ | ✅ | 简单 |
| **DJI** | ✅ | ✅ | ✅ | ✅ | 中等 |

## 下一步

1. 选择一个品牌作为**首个适配目标**（推荐 Sony，文档最完善）
2. 定义抽象接口 `CameraProtocol` 抽象类
3. 实现 `SonyCameraProtocol` 作为参考实现
4. 开发阶段用 `MockCameraProtocol` 模拟相机响应

# DIY 相机 REST API 规范

> APP 通过 WiFi HTTP 调用相机。相机需实现以下端点。
> Base URL: `http://<相机IP>` （默认 192.168.4.1）

## 通用约定

- Content-Type: `application/json`
- 字符编码: UTF-8
- 时间格式: ISO 8601 `"2026-06-04T15:30:00Z"`
- 文件传输: `multipart/form-data` 或直接返回 binary `image/jpeg`

### 通用错误响应

```json
{
  "error": {
    "code": "STORAGE_FULL",
    "message": "存储空间不足"
  }
}
```

错误码: `CAMERA_BUSY` | `STORAGE_FULL` | `NOT_FOUND` | `INVALID_PARAM` | `NOT_CONNECTED`

---

## 1. 设备信息

```
GET /api/v1/info
```

**响应**:
```json
{
  "brand": "DIY",
  "model": "ESP32-CAM",
  "firmware": "1.0.0",
  "battery": 85,
  "storageTotal": 15931539456,
  "storageUsed": 2147483648,
  "supportedApis": ["liveview", "capture", "recording", "storage"]
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| brand | string | 固定 `"DIY"` |
| model | string | 相机型号 |
| firmware | string | 固件版本 |
| battery | int | 电量百分比 0-100，-1 表示不支持 |
| storageTotal | int | 总存储字节 |
| storageUsed | int | 已用存储字节 |
| supportedApis | string[] | 支持的功能列表 |

---

## 2. 实时取景

### 2.1 启动取景流

```
GET /api/v1/liveview
```

**响应**: `Content-Type: multipart/x-mixed-replace; boundary=--frame`

```
--frame
Content-Type: image/jpeg
Content-Length: 12345

<JPEG binary data>
--frame
Content-Type: image/jpeg
Content-Length: 12400

<JPEG binary data>
...
```

APP 持续读取这个 MJPEG 流，每帧解码显示在取景器中。
推荐分辨率: **640x480**，帧率: **15-30 fps**。

> 如果相机性能有限，可以用轮询模式代替 MJPEG 流，见 2.2。

### 2.2 单帧取景（轮询模式，备选）

```
GET /api/v1/liveview/frame
```

**响应**: `Content-Type: image/jpeg`，直接返回单帧 JPEG。

APP 每 50-100ms 轮询一次。

---

## 3. 拍照

```
POST /api/v1/capture
```

**请求体** (可选):
```json
{
  "flash": false
}
```

**响应**:
```json
{
  "id": "IMG_20260604_153000",
  "name": "IMG_20260604_153000.JPG",
  "size": 5242880,
  "timestamp": "2026-06-04T15:30:00Z",
  "thumbnailUrl": "/api/v1/photos/IMG_20260604_153000/thumbnail",
  "downloadUrl": "/api/v1/photos/IMG_20260604_153000/download"
}
```

---

## 4. 录像

### 4.1 开始录制

```
POST /api/v1/recording/start
```

**响应**:
```json
{
  "status": "recording",
  "startedAt": "2026-06-04T15:30:00Z"
}
```

### 4.2 停止录制

```
POST /api/v1/recording/stop
```

**响应**:
```json
{
  "id": "VID_20260604_153000",
  "name": "VID_20260604_153000.MP4",
  "size": 52428800,
  "duration": 15.5,
  "timestamp": "2026-06-04T15:30:15Z",
  "downloadUrl": "/api/v1/photos/VID_20260604_153000/download"
}
```

---

## 5. 照片列表

```
GET /api/v1/photos?offset=0&limit=50&sort=date_desc
```

| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| offset | int | 0 | 分页偏移 |
| limit | int | 50 | 每页数量，最大 100 |
| sort | string | date_desc | 排序: `date_desc` / `date_asc` / `name` |
| dateFrom | string | - | 起始日期 ISO 8601 |
| dateTo | string | - | 截止日期 ISO 8601 |

**响应**:
```json
{
  "total": 230,
  "offset": 0,
  "limit": 50,
  "photos": [
    {
      "id": "IMG_20260604_153000",
      "name": "IMG_20260604_153000.JPG",
      "size": 5242880,
      "timestamp": "2026-06-04T15:30:00Z",
      "width": 4000,
      "height": 3000,
      "thumbnailUrl": "/api/v1/photos/IMG_20260604_153000/thumbnail",
      "downloadUrl": "/api/v1/photos/IMG_20260604_153000/download"
    }
  ]
}
```

---

## 6. 缩略图

```
GET /api/v1/photos/{photoId}/thumbnail
```

**响应**: `Content-Type: image/jpeg`，推荐 160x120 像素。

---

## 7. 下载照片

```
GET /api/v1/photos/{photoId}/download?quality=original
```

| 参数 | 值 | 说明 |
|------|-----|------|
| quality | `original` | 全分辨率原图 |
| quality | `medium` | 最长边 2048px，用于编辑预览 |
| quality | `small` | 最长边 1024px |

**响应**: `Content-Type: image/jpeg`，binary 数据。
响应头包含 `Content-Length` 用于进度条。

---

## 8. 删除照片

```
DELETE /api/v1/photos/{photoId}
```

**响应**:
```json
{
  "success": true
}
```

---

## 接口总览

| 方法 | URI | 用途 | 页面 |
|------|-----|------|------|
| GET | `/api/v1/info` | 设备信息 | 连接页 |
| GET | `/api/v1/liveview` | MJPEG 实时取景 | CAMERA |
| GET | `/api/v1/liveview/frame` | 单帧取景(备选) | CAMERA |
| POST | `/api/v1/capture` | 拍照 | CAMERA |
| POST | `/api/v1/recording/start` | 开始录像 | CAMERA |
| POST | `/api/v1/recording/stop` | 停止录像 | CAMERA |
| GET | `/api/v1/photos` | 照片列表 | EFFECTS |
| GET | `/api/v1/photos/{id}/thumbnail` | 缩略图 | CAMERA/EFFECTS |
| GET | `/api/v1/photos/{id}/download` | 下载照片 | EFFECTS |
| DELETE | `/api/v1/photos/{id}` | 删除照片 | (照片列表页) |
| GET | `/api/v1/status` | 连接状态(心跳) | CAMERA 轮询 |

---

## 附加：心跳/状态端点

```
GET /api/v1/status
```

APP 每 5 秒调用一次，检测相机是否在线。

**响应**:
```json
{
  "status": "ready",
  "wifiSignal": 3,
  "battery": 85,
  "isRecording": false,
  "capturesRemaining": 1200
}
```

| 字段 | 说明 |
|------|------|
| status | `"ready"` / `"busy"` / `"error"` |
| wifiSignal | 0-3，WiFi 信号强度 |
| battery | 电量 0-100 |
| isRecording | 是否正在录制 |
| capturesRemaining | 剩余可拍张数（估算） |

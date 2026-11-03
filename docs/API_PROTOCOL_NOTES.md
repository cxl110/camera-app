# 相机 HTTP 协议适配说明

对应固件协议：`../HTTPAPI/V821CAM-HTTP-API.md`（当前 **v1.8**）

这份文档记录**协议里的哪些约定，在本 App 的哪段代码里被执行**。改协议时按这张表逐条对照，不要只改接口字段。

## v1.8：无 RTC 时间模型（影响最大）

硬件去掉了 RTC 供电（无纽扣电池、无超级电容、无 32.768kHz 晶振），**关机期间设备时钟停走**。由此产生一条铁律：

> **连上相机后的第一个业务请求必须是 `POST /rtc`，且在任何带 token 的请求之前完成。**

对应实现：

| 协议要求 | 代码位置 | 说明 |
|---|---|---|
| `/info` 新增 `timestamp` / `boot_id` / `clock_source` / `clock_synced` | `http_camera_protocol.dart` → `_applyClockFields()` | 统一解析，`/info`、`/list`、`/rtc` 三处共用 |
| `boot_id` 变化 = 设备重启 → 丢弃旧时钟偏移并重新校时 | `_applyClockFields()` | 置 `_timeBaseSynced = false`、`_deviceTimeOffsetSec = 0` |
| `clock_synced=false` → 绝对时间不可信，必须校时 | `getConnectionStatus()` | **在 `_emitStatus(connected)` 之前 `await syncRtc()`**，保证 UI 后续发出的请求不会打在未校时的设备上 |
| `/rtc` 响应新增 `prev_timestamp` / `delta` / `mtime_fixed` / `hwclock_ok` | `syncRtc()` | `hwclock_ok=false` 属正常（无 RTC 电池），**不能当失败**；`mtime_fixed>0` 表示设备刚回填了照片时间 |
| `/rtc` 的 `400 BadTimestamp` 不要重试 | `syncRtc()` | 手机时间超出设备接受范围，重试无意义 |
| `/list` 也带 `boot_id` → 会话中途重启要补一次校时 | `listPhotos()` | 触发一次异步 `syncRtc(attempts: 1)`，不阻塞列表 |

## v1.8：照片时间 = 拍摄时间，不是导出时间

协议明确：`/list` 的 `mtime` 就是拍摄时间，导出时**必须**写进文件 mtime 和 EXIF `DateTimeOriginal`，否则相册里所有照片会堆在导出那天。

对应实现：

| 环节 | 代码位置 |
|---|---|
| 从 `/list` 解析拍摄时间 | `http_camera_protocol.dart` → `_FileEntry.fromJson` → `CameraPhoto.timestamp` |
| 下载后带入编辑流程 | `gallery_screen.dart` → `loadPhoto(..., capturedAt: photo.timestamp)` |
| 拍完照带入 | `home_screen.dart` → `loadPhoto(..., capturedAt: result.timestamp)` |
| 保存时写回文件 mtime + EXIF | `image_service.dart` → `saveWithUpscale` / `saveEditedImage` |
| EXIF 注入器（无第三方依赖） | `jpeg_exif.dart` |

`jpeg_exif.dart` 的设计取舍：

- **只注入、不重写**。JPEG 已有 Exif APP1 时原样返回（相机原图的时间是准的，不该被动）。
- 编辑/滤镜/缩放会重新编码 JPEG，EXIF 全丢，这时才补一个最小 APP1 段，写 `DateTime`(0x0132) / `DateTimeOriginal`(0x9003) / `DateTimeDigitized`(0x9004)。
- 任何异常都返回原字节 —— **存照片不能因为这个失败**。

> 踩过的坑：Dart 字符串没有 `\0` 转义，`'Exif\0\0'` 会被当成 `"Exif00"`。测试里比较 APP1 头必须用字节数组。

## 固件侧实测结论（2026-10-30，读 v821 源码 + 会话记录）

来源：`platform/thirdparty/gui/lvgl-8/lv_camera/src/main.c`（固件侧 HTTP 服务）
与固件开发会话 `session-022dc403…`（标题「取消RTC并改用照片命名排序」）。

| 约定 | 固件实际行为 | APP 适配 |
|---|---|---|
| `/list` 顺序 | **文件名降序 = 最新在前**（插入排序，`strcmp < 0`） | 一致；不依赖它也能工作（见下） |
| `total` | 每次请求都返回，DCIM 有效文件名总数 | ✅ |
| `limit` 钳制 | **`<1` 或 `>50` 都回落到 20**（不是截断到 50！） | gallery 用 20，安全 |
| `offset` | 超过总数则夹到 `total` | ✅ |
| `boot_id` | `/proc/sys/kernel/random/boot_id`，每次开机变、同次稳定；无则 `boot-<开机时钟>` | ✅ 变化即丢弃时钟偏移并重校 |
| `clock_source` | `rtc`（热重启/RTC 有效）/ `flash`(.last_time) / `build`(编译日期) / `none` | ✅ |
| `clock_synced` | 热重启（RTC 分支）开机即为 `true`；冷启动 `flash` 播种时为 `false`；首次 `/rtc` 后置 `true` | ✅ 连上先 `await /rtc` 正确 |
| mtime 回填 | 仅本次开机、仅首次 `/rtc`、`|delta|≥2s`；过滤条件「文件名时间 ≥ 开机时钟-2s」，`utimensat` 保留 atime | ✅ 与推测一致 |
| `hwclock` 失败 | 只写日志，`status` 仍为 `ok` | ✅ 不当失败 |

### 文件名单调性的真实保证方式（唯一系统性风险）

固件**不是**用 `max(.last_time, 最新文件名)` 播种，而是靠**每次拍照后 `clock_persist()` 写 `.last_time`**，
下次开机从它恢复。所以：

- 正常使用：`.last_time` ≥ 最后一拍照片的名字时间 → 新照片名字一定更大 → 顺序稳定 ✅
- **`.last_time` 丢失/写失败**（手动删除、UDISK 满、换卡）→ 回退到**固件编译日期**（可能几个月前）
  → 之后拍的照片名字会**小于**已有照片 → **相册顺序会乱**

固件侧若要彻底消除这个风险，播种时取 `max(.last_time, 最新 DCIM 文件名时间)` 即可（一行）。

### 为什么 APP 仍然不靠"服务端顺序"

即便固件当前是降序，APP 也不该把正确性绑在它上面：

1. 老固件即便降序，也解决不了**跨页**问题；
2. 排序键必须取文件名里的**时间戳段**，不能取完整文件名——否则 `V` > `I`，
   所有 `VID_` 会排在所有 `IMG_` 前面（这是本项目实际踩过的 bug）；
3. 因此 `listPhotos` 把 `offset` 定义为"跳过最新的 N 张"，内部探测方向后翻译；
   排序统一走 `captureKeyOf()`，与固件互不假设。



| 行为 | 位置 |
|---|---|
| token 用**设备时钟**算，不用手机时钟 | `_computeToken()` + `_adoptDeviceTime()` |
| `403 Locked` → 记 60 秒临时锁定，期间不发 token 请求 | `_onAuthRejected()` |
| `403 Forbidden` → 重新 `/rtc` 学设备时间（10 秒节流） | `_onAuthRejected()` |
| 无永久锁定（L3 已移除） | 逻辑上不再有"设备被锁死"的终态 |
| `/heartbeat` 不再是蜜罐 | 心跳正常参与鉴权 |

## 图像水平镜像（结论：App 不翻）

**结论：App 侧不翻转任何相机图像，默认关闭。** 固件只镜像它自己的 LCD 预览
（`d545546` 的 LUT `hflip=1`，因为面板装配方向），`/stream` 的 MJPEG 和照片文件
（`/file`、`/thumb`）本来就是正的。

> 这一条踩过一次坑：早期判断"传感器镜像、固件修不了"，于是 App 在入口处统一翻转，
> 结果预览和照片**全部显示为镜像**（翻两次 = 和没翻一样）。用
> `--dart-define=MIRROR_CAMERA=false` 出包对照验证后确认是相机端已经正确。

保留的开关（默认全关，只给确实输出镜像像素的机器用）：

| 开关 | 作用 |
|---|---|
| `--dart-define=MIRROR_CAMERA=true` | 下载时像素翻转（照片/缩略图/导出） |
| `--dart-define=MIRROR_STREAM=true` | 实时预览渲染时翻转 |

下面的表格是**打开开关时**的处理方式，留作参考。

| 路径 | 处理方式 | 位置 |
|---|---|---|
| 实时预览（MJPEG） | **渲染时** Transform 翻转 | `widgets/camera_preview.dart` → `_mirrored()` |
| 相册缩略图 | 下载时像素翻转 | `http_camera_protocol.dart` → `_getThumbnailBytes` |
| 视频缩略图 | 同上（走 `/thumb`） | — |
| 照片下载 | 下载时像素翻转；大图走后台 isolate | `downloadPhotoBytes` |
| 拍照后立即编辑 | 走 `downloadPhotoBytes`，自动覆盖 | `capturePhoto` |
| 打开照片编辑 | 拿到的字节已翻转 | `ImageService.currentPhoto` |
| 导出到相册 / 分享 | 用已翻转的字节，无需二次处理 | `image_service.dart` |
| 视频下载 | 原生转码时逐帧翻转 | `ios/Runner/VideoTranscoder.swift` → `makePixelBuffer` |
| **试用演示（相册选图）** | **不翻转**（不经过相机路径） | — |

为什么实时预览例外：MJPEG 每秒好几帧，逐帧解码再编码会把电耗光，所以预览交给合成器翻转
（`Transform(scale(-1,1,1))`），零拷贝。

### 两个必须知道的坑

1. **EXIF 方向**：重新编码会丢 EXIF 块，若相机写了 `Orientation=6/8`，照片会歪 90°。
   所以翻转前先 `img.bakeOrientation()` 把方向烘焙进像素（`Orientation=1` 是 no-op）。
2. **固件修好后要关掉**：一旦相机端能自己纠正镜像，用
   `--dart-define=MIRROR_CAMERA=false` 关掉，否则会**双重翻转**。

## v1.6：音效开关

| 接口 | 位置 | 说明 |
|---|---|---|
| `GET /sound` | `getSoundEnabled()` | 404/501 → `SoundSetting.unsupported`（老固件） |
| `POST /sound` | `setSoundEnabled()` | 403 → `CameraAuthException`（不是"不支持"） |
| UI | `widgets/sound_toggle_icon.dart` | 顶栏文件夹图标左边的纯喇叭图形 |

## OTA 固件（`/update`）

代码保留（`uploadFirmware` / `ota_update_dialog.dart`），但**发布版不打包固件、按钮只在 `kDebugMode` 下出现**：

- 手机刷固件失败会变砖，属审核与售后双重风险
- `assets/firmware/` 已从 `pubspec.yaml` 移除

## 自检清单（协议升级时逐条过）

1. `GET /info` 的新字段是否解析？未知字段能否安全忽略？
2. 新字段是否影响**连接时序**（尤其是任何"先校时"的要求）？
3. `/list` / `/rtc` 响应结构变了没有？时间基是否一致？
4. 是否有新的**必须实现的客户端行为**（不是新接口，而是新约定，比如本版的时间回填）？
5. 失败分支的语义有没有变（例如 500 改成正常返回）？
6. 补一条对应测试，而不是只改代码。

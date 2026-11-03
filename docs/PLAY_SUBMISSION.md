# Google Play 上架清单

对照 2026-11 的 Play 政策整理。分三块：**已经做完的**（有验证证据）、**需要你去操作的**（我做不了）、**建议但非阻塞的**。

---

## 一、已经做完（技术侧全部打通）

| 项 | 状态 | 证据 |
|---|---|---|
| 上架载体 | AAB，不是 APK | `build/app/outputs/bundle/release/app-release.aab` |
| minSdk / targetSdk | 24 / **36** | merged manifest（Play 要求 targetSdk ≥ 35） |
| 64 位支持 | arm64-v8a + armeabi-v7a | 同上 |
| **16 KB 内存页** | 64 位库全部合规 | `scripts/inspect_play_readiness.py` |
| 包体积 | AAB 143.5 MB（含 ~50 MB 符号表，Play 会剔除；实际下载约 90 MB） | 同上 |
| **上传签名** | 已从 debug key 换成正式上传密钥 | `jarsigner -verify` 通过，证书 `CN=SQ Cam` |
| 权限 | 10 个减到 6 个 | 见下方说明 |
| 商店图 | 图标 512×512、特征图 1024×500、手机截图 5 张 1284×2568 | `store/play/` |
| 隐私政策 URL | 已有 | <https://sanqi-lab.cn/sqcam/privacy.html> |
| 支持页 URL | 已有 | <https://sanqi-lab.cn/sqcam/support.html> |

### 这次改掉的三个会直接被拒的问题

1. **debug 签名**。原来 `build.gradle.kts` 里写的是 `signingConfig = signingConfigs.getByName("debug")`。Play 对 debug 签名的包是硬拒（"signed in debug mode"）。
   现在：`android/key.properties` + `android/upload-keystore.jks`（都不入库），缺文件时自动回退 debug，不影响别人本地跑。

2. **16 KB 内存页**。Play 从 2025-11 起要求 targetSdk 35+ 的应用支持 16 KB 页，`targetSdk` 已是 36。TFLite 2.16.1 的 `libtensorflowlite_jni.so` 只按 4 KB 对齐（`p_align = 0x1000`），会被判不合规。
   现在：升到 **2.17.0**（arm64 已 16 KB 对齐），并顺手删掉没被引用的 `tensorflow-lite-support`（它会把 `tensorflow-lite-api:2.13.0` 拖进来，和 2.17.0 自带的 LiteRT API 撞重复类）。x86_64 只有模拟器用、且它的预编译库仍是 4 KB，上架包里排掉。

3. **照片和视频权限**。原来声明了 `READ_MEDIA_IMAGES` / `READ_MEDIA_VIDEO` / `READ_EXTERNAL_STORAGE` / `CAMERA`，会触发 Play 的「照片和视频权限」申报（要写用途说明、可能被人工复核）。
   实际全都不需要：
   - 选图走系统 Photo Picker（进程外，零权限）
   - 存图走 MediaStore（Android 10+ 零权限），只有 Android 9 及以下需要 `WRITE_EXTERNAL_STORAGE`（已限 `maxSdkVersion=29`）
   - `CAMERA` 在 Release 里根本没被调用（`ImageSource.camera` 只出现在仅供测试的 `mock_camera_protocol.dart`）

### 出包命令

```powershell
powershell -File scripts\build_play_bundle.ps1
```

脚本会：设 `PLAY_BUNDLE=1`（排掉 x86_64 原生库）→ `flutter build appbundle --target-platform android-arm,android-arm64` → 跑合规自检（64 位 .so 页对齐）→ 校验签名 → 打印产物路径。任一环节不过就报错退出。

---

## 二、需要你操作的（我做不了）

### 1. Play Console 账号（最耗时的一环）

- 一次性注册费 **25 美元**，需要身份验证（身份证/护照）和地址验证。
- **账号类型决定上架节奏**：
  - **个人账号**（2023-11-13 之后注册的）：正式发布前必须先在**封闭测试**轨道跑满 **12 名测试者、连续 14 天**，然后才能申请生产发布。这一条是日历上最大的变量。
  - **组织账号**：需要 **D-U-N-S 编号** 和组织验证（营业执照英文名、地址要一致），但没有 12×14 那条限制。
  - 我们是 `Shenzhen Beili Times Technology Co., Ltd.`——如果公司已有 D-U-N-S，走组织账号省 14 天。

> 建议：先用组织账号申请，等验证的同时把下面的材料都填好。

### 2. 应用条目信息

| 字段 | 限制 | 建议内容 |
|---|---|---|
| 应用名称 | 30 字 | `SQ Cam - Film Camera` |
| 简短说明 | 80 字 | `Transfer photos from your ZIVIGo camera and apply film looks.` |
| 完整说明 | 4000 字 | 可参考 `docs/APPSTORE_SUBMISSION.md` 里的英文文案改写 |
| 应用图标 | 512×512 | `store/play/icon-512.png` ✅ |
| 特征图 | 1024×500 | `store/play/feature-graphic-1024x500.png` ✅ |
| 手机截图 | 2–8 张 | `store/play/screenshots/`（5 张）✅ |
| 隐私政策 | URL | `https://sanqi-lab.cn/sqcam/privacy.html` ✅ |

iPhone 截图是 1284×2778（1:2.16），**超过 Play 的 2:1 上限会被拒**，`scripts/make_play_screenshots.py` 已经裁到 1284×2568（正好 2:1）。后续如果用 Android 真机重拍，直接出 1080×1920 更稳。

### 3. 各类申报表单

| 表单 | 怎么填 |
|---|---|
| **数据安全**（Data safety） | 全部选「不收集」「不共享」。无账号、无统计 SDK、无广告；照片只在设备本地处理，不上传任何服务器 |
| **内容分级**（IARC 问卷） | 摄影/图片编辑类，无暴力/性/赌博/毒品 → 通常拿「Everyone / 3+」 |
| **目标受众** | 13 岁以上（避免触发儿童类额外要求） |
| **广告声明** | 应用不含广告 |
| **应用访问说明**（App access） | **这里要写清楚**：完整体验需要 ZIVIGo 相机硬件（WiFi 连接）；没有相机时可用「试用模式」从相册选一张照片体验全部滤镜和边框 |
| 政府/新闻/金融/健康类 | 全部选「否」 |
| 美国出口合规（加密） | 只用标准 HTTPS，选常规豁免即可 |

### 4. 上传与发布

- 首次必须**手动**在 Play Console 建应用 + 上传第一个 AAB（之后可以接 API）。
- 上传时选「**使用 Google Play 应用签名**」——把这把 `upload-keystore.jks` 当 upload key 用，实际签名密钥由 Google 保管。这样将来 upload key 丢了可以申请重置，不会永久失去更新能力。
- **务必备份** `android/upload-keystore.jks` 和 `android/key.properties`（密码就在里面）。这两个文件不入库，现在只存在于这台机器上。

---

## 三、建议做但不会阻塞上架

1. **包体积**：`assets/frames/` 30 张 PNG 共 **83 MB**，占了安装包的大头。转成 WebP（质量 85）大约能压到 8–12 MB。对 4G 用户的首装体验影响很直接。
2. **安卓启动图**：`launch_background.xml` 还是纯白，iOS 那边有 LaunchScreen。建议换成米色底 + 产品图，保持一致。
3. **重拍安卓截图**：现在这 5 张是 iPhone 截图裁的，状态栏是 iOS 的。用安卓真机重拍会更自然（也顺便能展示安卓特有的表现）。
4. **Gradle 8.13 → 8.14+**：Flutter 已经警告该版本很快不再支持。

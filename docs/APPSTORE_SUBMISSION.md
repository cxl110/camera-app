# iOS 上架操作手册（相机伴侣 Camera Companion）

> 目标：从「爱思助手签名装不上」切换到「开发者账号正规签名 → TestFlight → App Store」。
> 文中的 `com.zivigo.cameraapp` / `1.2.0 (12)` 是当前工程里的真实值，改了要同步。

---

## 0. 一句话结论

爱思助手的「免费签名」用的是共享企业证书或 7 天个人证书，必然掉签、必然装不上、也永远上不了架。
有开发者账号后 **完全不需要爱思**：用 Xcode 自动签名打包，走 **TestFlight** 分发——不用连电脑、有效期 90 天、而且这条链路就是上架的同一条链路。

---

## 1. 爱思签名为什么会有问题

| 你看到的现象 | 真实原因 |
|---|---|
| 装完闪退 / 打开就退 | 签名后砸壳（重签）破坏了 entitlements，或证书被苹果吊销，App 启动即被系统杀 |
| 「无法验证 App」/ 描述文件失效 | 企业共享证书被苹果批量封禁（爱思这类平台常年被封），或 7 天免费证书到期 |
| 能装但隔几天要重装 | 免费账号签名有效期 7 天；企业证书随时可能被吊销 |
| 上传 App Store 被拒 | 重签过的包签名链不是你的账号，App Store Connect 根本不接受第三方签名 |

结论：**这条路和上架是互斥的**。既然有开发者账号，就别再花时间在爱思上。

---

## 2. 正规的四条安装/分发通道

| 方式 | 有效期 | 需要电脑 | 需要审核 | 适用 |
|---|---|---|---|---|
| **TestFlight** | 90 天/版本 | 否 | Beta 审核（通常几小时） | **推荐**，自己测 + 给同事测 |
| Xcode 真机调试 | 1 年（开发证书） | 是 | 否 | 开发阶段 |
| Ad Hoc | 1 年 | 是（首次要连设备注册 UDID） | 否 | 小范围固定设备 |
| App Store | 永久 | 否 | App 审核 | 正式上架 |

**建议路径**：先把 1.2.0(12) 传上 TestFlight 自己装一台真机验一遍，确认无误再提审。TestFlight 装的包和最终上架包是同一个构建产物，验过就等于上架包验过。

---

## 3. 代码侧我已经改好的（这部分你不用管）

| # | 问题 | 后果 | 改动 |
|---|---|---|---|
| 1 | Bundle ID 是 `com.example.cameraApp` | 占位命名空间，审核质疑品牌归属，且 App Store 上架后不可再改 | 改为 `com.zivigo.cameraapp`（与 Android `applicationId` 一致），脚本 `scripts/set_ios_signing.ps1` 可一键改 |
| 2 | 缺 `NSLocalNetworkUsageDescription` | **上传校验直接失败（ITMS-90683）**；且 iOS 14+ 访问相机热点时无系统授权弹窗 | `ios/Runner/Info.plist` 补上用途说明 |
| 3 | App 图标是 Flutter 默认蓝色 F | 审核认定为未完成品，必拒 | 重画：`scripts/make_app_icon.ps1` 输出 1024×1024 无 alpha 的钛金相机母版，`scripts/gen_app_icons.ps1` 铺满全尺寸 |
| 4 | `version: 1.1.0` 没有 build 号 | `CFBundleVersion` 为空，**上传校验失败（ITMS-90062）** | 改为 `1.2.0+12` |
| 5 | App 顶栏常驻「上传日志」调试按钮 | 面向用户收集日志 = 必须在 App 隐私里申报；审核也看着像测试包 | 代码保留，release 版隐藏（`kDebugMode` 判断） |
| 6 | 打包了 9.5 MB 相机固件、顶栏有「固件更新」按钮 | 手机刷固件失败会变砖，审核和售后双重风险 | release 版不再打包 `assets/firmware/`，按钮同样只在 debug 显示，安装包小 9.5 MB |
| 7 | 声明支持 iPad 但全局锁竖屏 | iPad 上体验是坏的，审核可能质疑 | `TARGETED_DEVICE_FAMILY = 1`（仅 iPhone，iPad 可跑 iPhone 版窗口） |
| 8 | 缺归档/上传脚本 | 手工点 Xcode 容易漏步骤 | `scripts/ios_archive_upload.sh`（Mac 上跑）+ `ios/ExportOptions.plist` |

自检命令（Windows 上就能跑）：

```powershell
pwsh scripts/set_ios_signing.ps1 -BundleId com.zivigo.cameraapp -TeamId <你的TeamID>
```

---

## 4. 你要按顺序做的事

### 4.1 账号与协议（Apple 侧，我做不了）

- [ ] Apple Developer Program 会员状态 **Active**（个人 $99/年 或 公司）
- [ ] App Store Connect → 协议、税务和银行业务：**Free Apps 协议** 点同意（免费 App 也必须签，否则 build 无法生效）
- [ ] 拿到 **Team ID**：developer.apple.com → Account → Membership，10 位字符（如 `A1B2C3D4E5`）

### 4.2 在 Xcode 里选团队（Mac 上必做一次）

Bundle ID 已经在工程里改成 `com.zivigo.cameraapp` 了，Mac 上只需要把**团队**选上：

```bash
open ios/Runner.xcworkspace     # 注意是 xcworkspace，不是 xcodeproj
```

Xcode → 左侧选中 **Runner** target → **Signing & Capabilities**：

- Team 选你的开发者团队
- 勾 **Automatically manage signing**
- 第一次会提示 "Register device" / "Create certificate"，全部同意

Xcode 会把 `DEVELOPMENT_TEAM` 写进工程文件，后面归档脚本会自己读取它。

> 想把 Team ID 也一次性写进工程（不用 Xcode GUI），在 **Windows** 上执行：
> ```powershell
> pwsh scripts/set_ios_signing.ps1 -BundleId com.zivigo.cameraapp -TeamId 你的TeamID
> ```
> 注意 macOS 默认没有 PowerShell，Mac 上走 Xcode GUI 就行。

### 4.3 建 App 记录（App Store Connect）

- [ ] App Store Connect → 我的 App → **＋** → 新建 App
- [ ] 平台 **iOS**；名称 `Camera Companion`（中文名可后续在「App 信息」里加本地化，如「相机伴侣」）
- [ ] 主要语言：简体中文
- [ ] Bundle ID：选 `com.zivigo.cameraapp`（下拉里出现说明 4.2 成功了）
- [ ] SKU：随便填唯一值，如 `camapp-001`
- [ ] 用户访问权限：完全访问

### 4.4 打签名包并上传

在 Mac 上：

```bash
./scripts/ios_archive_upload.sh --clean
```

产物在 `build/ios/ipa/*.ipa`。上传有三种，选一种：

1. 脚本已配置 `destination=upload`，`flutter build ipa` 结束时若签名正常会直接上传；
2. Xcode → Window → Organizer → 选中刚生成的 Archive → **Distribute App** → App Store Connect → Upload；
3. 用 **Transporter** App 拖入 IPA 上传（最稳，报错信息也最清楚）。

上传后 App Store Connect → TestFlight 等 10–60 分钟处理完成，加自己为内部测试员，手机装 TestFlight 扫码安装。
**这条就替代了爱思助手。**

### 4.5 截图（提审必需）

仅 iPhone 时至少准备 **6.9 寸** 一组（3–10 张）：

| 机型 | 尺寸（竖屏） |
|---|---|
| iPhone 16 Pro Max（6.9"） | **1320 × 2868** |
| iPhone 11 Pro Max（6.5"，可选） | 1242 × 2688 |

截图不要用模拟器空白页，要拍到：连接相机页、实时取景、胶片滤镜效果、相册/导出。没有相机就在真机连上相机拍。

### 4.6 App 隐私问卷（逐项答案）

App Store Connect → App 隐私 → 现在开始：

- **是否收集数据**：选 **否**（No, we do not collect data from this app）
  - 依据：照片只在设备本地处理（CoreML 本地推理 + Dart 本地色彩矩阵），不经过任何服务器；App 内无统计/广告/崩溃上报 SDK。
  - 注意：第 5 项那个「上传日志」必须在 release 里隐藏（已做），否则这里就得申报「设备诊断数据」。
- **是否用于追踪**：否
- **隐私政策 URL**：必填，需要你有网页。可以是 GitHub Pages / 语雀 / 任意公网页面，内容需覆盖：收集什么（无）、照片如何处理（本地）、联系方式、生效日期。

所需权限文案（Info.plist 已写好，审核会逐条对照）：
相机 / 相册读取 / 相册写入 / **本地网络**。

### 4.7 其他必填项

- **出口合规**：`ITSAppUsesNonExemptEncryption=false` 已写入 → 上传后不再追问加密问题
- **年龄分级**：4+（无用户生成内容、无广告、无社交）
- **类别**：摄影与录像（主）/ 工具（备）
- **版权**：填你自己的名称
- **价格**：免费（或自定）
- **供应情况**：见 4.9 中国大陆区备案

### 4.8 提交审核时必须写的 Review Notes

这是**最容易翻车的地方**：审核员手上没有你们的 ZIVIGo 相机，打开 App 连不上，只会看到一个空界面，然后按 **2.1（崩溃/功能不完整）** 或 **4.2（功能不足）** 驳回。

审核备注模板（直接贴，按实际改）：

```
This app is a companion app for a physical Wi-Fi camera (ZIVIGo / V821).

The camera broadcasts its own Wi-Fi hotspot (SSID starts with "ZIVIGO",
camera IP 192.168.5.1). The phone must join that hotspot before the app can
connect; there is no internet backend and no account/login.

Because the reviewer does not have the hardware, the app cannot show its
camera functions without the device. To review the photo-editing features
without hardware: on the camera screen tap "Try without a camera", then
choose any photo from the photo library. The same entry is offered when
tapping the EFFECTS or BORDERS tab while no camera is connected. The film
filters, grain, light leaks, borders and export all run fully on-device.

A short screen recording showing the full flow with the real camera:
<视频链接>

Local Network permission is used only to reach the camera on the camera's
own hotspot. No data leaves the device.
```

**强烈建议同时做一个「演示模式」入口**（见下一节），否则每次审核都可能被问一遍。

### 4.9 中国大陆区特别注意（如果要在国内上架）

- 中国大陆 App Store 上架需要 **工信部 App 备案**（在 App Store Connect 填备案号），个人开发者也要备案，流程约 1–4 周。
- 没有备案号时，可以先只勾选海外地区上架，验证审核流程；等备案下来再开中国区。
- 隐私政策里建议写明「不收集个人信息」，国内《个人信息保护法》口径比苹果更严。

---

## 5. 试用演示（无需相机）—— 已实现 v1

没有相机时，App 曾经是一块空屏，审核员无从判断功能。现在有两个入口：

| 入口 | 位置 | 行为 |
|---|---|---|
| 「Try without a camera」按钮 | 取景区未连接时的占位内容下方 | 打开系统相册选图 → 直接进滤镜页 |
| 点 EFFECTS / BORDERS 标签 | 底部导航 | 弹窗提示「相机未连接」，可选「用相册照片试用」或「先连相机」 |

实现要点：

- 用系统相册选择器（iOS 14+ 是 PHPicker，**进程外运行、不触发相册权限弹窗**，模拟器里也能用）——审核员手里一定有照片，不需要我们塞假样片。
- 选中后写进 `ImageService.originalPhoto`，然后以 `wifiConnected: true` 进入
  `EffectsScreen` / `BordersScreen`，所以滤镜、颗粒、漏光、边框、导出全部可用。
- 顶部显示蓝色「Trial mode」条 + Exit，明确告诉用户当前不是在用相机，避免误以为是相机坏了。
- `Trial mode` 只是 home 屏上的一个布尔值，编辑页本身不改逻辑，回归风险低。

**v2 还可以做**（按需）：内置 2–3 张官方样片（供完全不想授权相册的人一键体验）、演示模式下的「相册/传输」流程、把 Trial 入口放进首次启动引导。

---

## 6. 常见驳回理由与对策

| 驳回条文 | 触发点 | 对策 |
|---|---|---|
| 2.1 App 完成度 | 没有相机时是空界面 | 做演示模式 + Review Notes 提供录像 |
| 2.3.8 元数据不准确 | 截图与实际不符、图标是模板 | 已换正式图标；截图要用真实界面 |
| 4.2 最低功能 | 「就是个遥控器」 | Review Notes 强调本地 AI 胶片滤镜、边框、水印、导出为独立价值 |
| 5.1.1 权限用途不明 | 本地网络/相册弹窗没说清用途 | Info.plist 文案已写具体用途 |
| 2.5.1 私有 API | — | 无 |
| 加密合规 | 上传后追问 | `ITSAppUsesNonExemptEncryption=false` 已声明 |
| 4.3 垃圾应用 | 与已有 App 高度相似 | 强调自家硬件配套 |

---

## 7. 雷区清单（别再出现）

- ❌ 用 `com.example.*` 上架
- ❌ Flutter 默认图标 / 带透明的图标（App Store 拒绝 alpha 通道）
- ❌ release 包里留调试按钮（上传日志、固件刷机、IP 输入框）
- ❌ 只声明 iPhone 却给了 iPad 截图（或反之）
- ❌ `CFBundleVersion` 不递增：同一个 build 号第二次上传会被拒
- ❌ 隐私问卷填「不收集」但代码里有上报（会被静态扫描抓到）

### 已知工具坑：`flutter_launcher_icons`

`dart run flutter_launcher_icons` 会顺手改 `project.pbxproj`，而且会把
`ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS` 的值从 `YES`
误写成 `AppIcon`（和 `ASSETCATALOG_COMPILER_APPICON_NAME` 搞混了）。

**所以不要直接调它**，用包装脚本：

```powershell
pwsh scripts/gen_app_icons.ps1            # 重画母版 + 铺全尺寸 + 自动修复 + 校验
pwsh scripts/gen_app_icons.ps1 -SkipMaster  # 只重新铺尺寸
```

它会依次执行：生成母版 → `flutter_launcher_icons` → 把被改成 `AppIcon` 的键
修回 `YES` → 跑一遍签名脚本校验（签名脚本本身也会拦住这种污染）。

改图标风格：`scripts/make_app_icon.ps1 -Variant light|dark|metal -Zoom 1.25`。

---

## 8. 版本号规则

`pubspec.yaml` 的 `version: 1.2.0+12`：

- `1.2.0` = 展示版本（App Store 上的版本号，提审时和 App Store Connect 里填的一致）
- `12` = 构建号（每次上传必须 **比上一次大**，否则 ITMS-4238 重复构建号）

日常发版：`1.2.0+13`、`1.2.0+14`…；功能版本：`1.3.0+20`。

---

## 9. 现在就能执行的顺序

1. 打开 Mac：`open ios/Runner.xcworkspace` → Signing & Capabilities 选团队（4.2）
2. `./scripts/ios_archive_upload.sh --clean` → 自动生成 ExportOptions.plist 并归档上传
3. TestFlight 装到自己手机，真机验收：连接相机、实时取景、拍照、音效开关、滤镜、导出
4. 补演示模式（建议，见第 5 节）→ 再传一个 build
5. 填 App 记录、隐私问卷、截图 → 提审

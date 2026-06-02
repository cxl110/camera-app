# 📷 相机伴侣

iOS 相机伴侣 APP —— WiFi 连接相机下载照片，22 款 AI 神经网络胶片滤镜，水印编辑，一键分享。

## 功能

- 🔗 **WiFi 相机连接** — 支持 Sony、Fujifilm、Canon、Nikon 等主流品牌
- 🎨 **AI 胶片滤镜** — 22 款神经网络滤镜，模拟富士/柯达/奥林巴斯/宝丽来经典胶片
- 💧 **水印编辑** — 文字/logo/签名水印，可调透明度
- 📤 **分享导出** — 保存到相册或直接分享

## 技术架构

```
Flutter (Dart)  →  Provider 状态管理
                  →  CoreML (iOS原生) / ONNX (Android)
                  →  HTTP WiFi 相机通信

Filter4Free      →  PyTorch 模型 (80K-200K 参数)
                  →  coremltools 转换
                  →  .mlmodel 本地推理
```

## 开发

```bash
# 安装依赖
flutter pub get

# 运行 (需要 macOS + Xcode 或 Chrome)
flutter run

# 模型转换 (macOS only)
pip install coremltools
python scripts/convert_models.py --output-dir assets/models
```

## 滤镜列表

| 品牌 | 滤镜名称 | 数量 |
|------|---------|:--:|
| 🎌 Fuji | ACROS, CLASSIC CHROME, ETERNA, CLASSIC Neg., PRO Neg.Hi, NOSTALGIC Neg., PRO Neg.Std, ASTIA, PROVIA, VELVIA, Pro 400H, Superia 400, reala | 14 |
| 🎞️ Kodak | Color Plus, Gold 200, Portra 400, Portra 160NC, UltraMax 400 | 5 |
| 📸 Olympus | VIVID | 1 |
| 🖼️ Polaroid | Polaroid | 1 |

## 协议

- APP: Apache 2.0
- 滤镜模型: 基于 [Filter4Free](https://gitee.com/fg_slash/filter4free) (Apache 2.0)

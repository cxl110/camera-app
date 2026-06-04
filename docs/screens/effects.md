# EFFECTS 滤镜页

> 设计来源: 墨刀原型 `C:\H3\APP\PNG\effects.png`
> 最后更新: 2026-06-03

## 访问条件

**必须连接相机 WiFi 后才能进入此页面**。断开时显示 "请先连接相机WiFi" 提示。

## 布局

```
┌──────────────────────────────┐
│ [←返回]              [📁]   │ 顶栏 44px
├──────────────────────────────┤
│  [CLASSIC CHROME]  [B][A]   │ 滤镜名(左上) BEFORE/AFTER(右上)
│                              │
│      Image Preview           │ 预览区 ~1/3屏幕高度
│     (选中照片的滤镜预览)      │ 无照片时显示图标占位
│                              │
├──────────────────────────────┤
│  FILM PRESETS                │ 分区标题
│ ┌──┐ ┌──┐ ┌──┐ ┌──┐ →     │ 水平滚动，4个可见
│ │AC│ │CC│ │ET│ │CN│         │ 72x96px 卡片
│ └──┘ └──┘ └──┘ └──┘         │ 选中=黄色边框 #D89A0F
├──────────────────────────────┤
│  GRAIN           40%  [🔘]  │ 标签+值+开关
│  ──────●────────────         │ 滑块 (仅开启时显示)
├──────────────────────────────┤
│  LIGHT LEAK       30%  [🔘]  │ 标签+值+开关
│  [NONE][WARM][COOL][RED][DBL]│ 样式选择器
│  ──────●────────────         │ 滑块 (仅开启时显示)
├──────────────────────────────┤
│   CAMERA        EFFECTS      │ 底部标签 (EFFECTS激活)
└──────────────────────────────┘
```

## 控件规格

### 1. 顶栏
| 控件 | 位置 | 图标 | 行为 |
|------|------|------|------|
| 返回按钮 | 左上 | arrow_back | 返回 CAMERA 页面 |
| 相册按钮 | 右上 | folder_outlined | 打开相机照片列表 |

### 2. 图片预览区
| 属性 | 值 |
|------|-----|
| 高度 | MediaQuery 高度的 32% |
| 背景 | #1A1A1E，无照片时显示 image_outlined 图标 |
| 滤镜名 | 左上角，黑底金色文字 #D89A0F |
| BEFORE/AFTER | 右上角两个切换按钮，激活态金色背景 + 黑字 |

### 3. FILM PRESETS 滤镜列表
| 属性 | 值 |
|------|-----|
| 标题 | "FILM PRESETS"，白色38%，11px，letterSpacing 2 |
| 卡片尺寸 | 72x96px，圆角6px |
| 可见数量 | 4个，左滑查看更多 |
| 选中态 | 2px 金色边框 #D89A0F + 名称变金色 |
| 每张卡片 | 上方预览图（占位色块），下方滤镜名缩写 |

**预设列表**: ACROS, CLASSIC CHROME, ETERNA, CLASSIC Neg., PRO Neg.Hi, VELVIA, ASTIA, PROVIA, Pro 400H, Portra 400, Gold 200, UltraMax 400

### 4. GRAIN 颗粒度
| 属性 | 值 |
|------|-----|
| 标签 | "GRAIN"，白色13px，纯文本不可点击 |
| 强度值 | 金色 #D89A0F，仅开关打开时显示 |
| 开关 | Flutter Switch，金色激活态 |
| 滑块 | 0-100，仅开关打开时显示，金色轨道 |

### 5. LIGHT LEAK 漏光
| 属性 | 值 |
|------|-----|
| 标签 | "LIGHT LEAK"，白色13px |
| 强度值 | 金色，仅开关打开时显示 |
| 开关 | 同 GRAIN |
| 样式选择器 | 水平排列：NONE / WARM / COOL / RED / DOUBLE |
| 样式芯片 | 圆角16px，选中金色边框+背景，禁用时灰色 |
| 滑块 | 仅开关打开时显示 |

### 6. 底部标签
| 属性 | 值 |
|------|-----|
| CAMERA | 未激活，点击无反应 |
| EFFECTS | 当前激活 |

## 状态管理

| 状态 | 变量 | 影响 |
|------|------|------|
| WiFi连接 | `wifiConnected` | 控制能否进入页面 |
| BEFORE/AFTER | `_showBefore` | 预览图切换 |
| 当前预设 | `_selectedPreset` | 高亮 + 预览图滤镜名 |
| 颗粒开关 | `_grainEnabled` | 显示/隐藏强度值和滑块 |
| 颗粒强度 | `_grainIntensity` | 0-100 |
| 漏光开关 | `_lightLeakEnabled` | 显示/隐藏强度值和滑块 |
| 漏光样式 | `_lightLeakStyle` | 5种选项高亮 |
| 漏光强度 | `_lightLeakIntensity` | 0-100 |

## 文件映射

```
lib/screens/effects_screen.dart          # EFFECTS页面主体
lib/widgets/film_presets.dart            # FILM PRESETS 水平滤镜列表
lib/widgets/grain_control.dart           # GRAIN 颗粒度控制
lib/widgets/light_leak_control.dart      # LIGHT LEAK 漏光控制
lib/widgets/bottom_tabs.dart             # 底部标签 (复用)
```

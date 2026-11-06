# 鸿蒙（HarmonyOS / OpenHarmony）出包

## 一、环境准备

`flutter build hap` 需要三个环境变量，否则会报 `No Hmos SDK found`：

```powershell
$env:HOS_SDK_HOME    = "C:\Huawei\DevEco Studio\sdk"
$env:DEVECO_SDK_HOME = "C:\Huawei\DevEco Studio\sdk"
$env:Path = "C:\Huawei\DevEco Studio\tools\hvigor\bin;C:\Huawei\DevEco Studio\tools\ohpm\bin;C:\flutter_ohos\bin;" + $env:Path
```

工具链来源：

| 组件 | 路径 | 说明 |
|---|---|---|
| Flutter | `C:\flutter_ohos` | 3.27.4-ohos（Dart 3.6.2），鸿蒙分支因此把 `flutter_lints` 钉在 4.x |
| SDK | `C:\Huawei\DevEco Studio\sdk` | DevEco Studio 6.1 自带，API 12 / default |
| hvigor / ohpm | `C:\Huawei\DevEco Studio\tools\{hvigor,ohpm}\bin` | 不在 PATH 里，必须手动加 |

## 二、出未签名包

```powershell
flutter build hap --release
# → build/ohos/hap/entry-default-unsigned.hap
```

`ohos/build-profile.json5` 里 `signingConfigs` 是空数组，所以产物一定是 **unsigned**，Flutter 也会明确提示：

```
HAP will be unsigned (signingConfigs empty).
```

## 三、出签名包（OpenHarmony 测试链）

```powershell
powershell -File scripts\sign_ohos_hap.ps1
# → build/ohos/hap/entry-default-signed.hap   （约 27 MB）
```

脚本做四件事：生成 provision profile → 组装证书链 → `sign-profile` → `sign-app` → `verify-app`。
用到的材料全部来自 DevEco SDK 自带的 OpenHarmony 测试 PKI：

```
toolchains/lib/OpenHarmony.p12               # 根 CA / 中间 CA / 应用密钥 / profile 密钥（口令 123456）
toolchains/lib/OpenHarmonyProfileRelease.pem # profile 证书链
toolchains/lib/UnsgnedReleasedProfileTemplate.json
```

### 这里有个坑

keystore 里 `openharmony application release` 这个别名存的是**自签占位证书**，直接 `keytool -exportcert` 导出来喂给 `sign-app` 会报：

```
11013002 Certificate format is incorrect
verify certificate chain failed! Signature does not match.
```

真正的叶子证书是「由 OpenHarmony Application CA 签发」的那张，它被原样嵌在
`UnsgnedReleasedProfileTemplate.json` 的 `bundle-info.distribution-certificate` 字段里。
`scripts/build_ohos_cert_chain.py` 就是用这张 + CA + 根拼出三联链。

## 四、能不能装到真机

| 设备类型 | 自签包能否安装 |
|---|---|
| OpenHarmony 设备 / 模拟器 | ✅ 可以（信任 OpenHarmony 测试根） |
| 零售 HarmonyOS NEXT 手机 | ❌ 不行，只认华为对该账号签发、且绑定设备 UDID 的 profile |

**要在华为真机上跑，必须走华为账号这条路**：

1. 打开 `C:\Huawei\DevEco Studio\bin\devecostudio64.exe`，打开 `ohos/` 工程
2. 登录华为账号（需手机验证）
3. 连上真机 → `Project Structure` → `Signing Configs` → 勾 **Automatically generate signature**
4. DevEco 会把 `signingConfigs` 自动写进 `ohos/build-profile.json5`，之后 `flutter build hap --release` 直接出可装真机的签名包

安装命令：

```powershell
C:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe install build\ohos\hap\entry-default-signed.hap
```

## 五、踩过的坑

1. **`pub get` 会改锁文件**：鸿蒙 Flutter 是 3.27.4 / Dart 3.6，跑 `flutter build hap` 时它会自动 `pub get` 并把 `pubspec.lock` 里 57 个包降级。构建完记得还原：
   ```powershell
   git checkout -- pubspec.lock .flutter-plugins .flutter-plugins-dependencies ios/Runner/GeneratedPluginRegistrant.m
   ```
2. **`-outCertChain` 大小写敏感**：写成 `-outCertchain` 会报 `11011005 Param is not trusted`，很容易误判成证书问题。
3. **签名材料不在仓库里**：`build/ohos/signing/` 是构建产物，已被 `build/` 忽略。

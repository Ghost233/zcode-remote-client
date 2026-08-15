# zcode-remote-client

ZCode 远程终端跨平台客户端（iOS / Android / macOS / Windows），内核为完整功能的 WebView 浏览器（flutter_inappwebview），带悬浮控制栏、多会话保活、远程地址管理、应用内更新。

## 版本号规则（重要）

- **每次发版，版本号在上一次的基础上 +0.0.1**（patch 位递增），build number 同步 +1
- 例：`1.1.1+3` → 下一次发版为 `1.1.2+4`，再下一次 `1.1.3+5`
- 版本号写在 `pubspec.yaml` 的 `version:` 字段
- **Git tag 必须与 pubspec 版本一致**（带 `v` 前缀），如 `version: 1.1.1+3` 对应 tag `v1.1.1`——应用内更新依赖 tag 与 pubspec 匹配来比较版本

## 发版流程（GitHub Actions 自动出包，public 仓库免费）

流水线在 `.github/workflows/release.yml`。日常发版只需升版本 + 推 tag：

```bash
# 1. 升版本号（+0.0.1 / build +1）：编辑 pubspec.yaml，如 1.1.3+5 → 1.1.4+6
# 2. 提交并推送
git add pubspec.yaml && git commit -m "chore: 发布 v1.1.4" && git push origin main
# 3. 打带注释的 tag（注释会成为 Release 发布说明，支持多行），推送触发自动出包
git tag -a v1.1.4 -m "更新说明标题

- 修复 ...
- 新增 ..."
git push origin v1.1.4
```

Actions 自动完成：Android 三架构分包 + 混淆（正式签名）、macOS universal 剥
arm64 / x86_64 各打 DMG、Windows x64 zip、校验 tag 与 pubspec 版本一致
（不一致直接失败）、创建 Release 并按固定顺序上传附件（**arm64 APK 第一个**，
旧版本更新器固定取第一个 .apk）。在 Actions 页面可手动触发
（workflow_dispatch）做只构建不发布的验证跑。

## 注意事项

- **Android 从 v1.1.4 起为正式签名**（密钥在 GitHub Secrets
  `ANDROID_KEYSTORE_BASE64` / `ANDROID_KEYSTORE_PASSWORD`，本地副本在
  `~/.keystores/zcode-remote-client/`）。v1.1.3 及更早的 debug 签名包升级
  v1.1.4 需**卸载重装一次**，之后的版本可直接覆盖升级
- 本地 `flutter run` / 无密钥构建仍走 debug 签名；需要本地出正式签名包时：
  `KEYSTORE_PATH=~/.keystores/zcode-remote-client/zcode-release.keystore \
   KEYSTORE_PASSWORD=$(cat ~/.keystores/zcode-remote-client/password.txt) \
   flutter build apk --release ...`
- macOS 包未签名公证，首次打开需右键 → 打开
- Windows 产物为 zip（exe + dll + data 整套，未签名，SmartScreen 可能提示「仍要运行」）
- iOS 需个人证书在 Xcode 自行签名打包，不在 CI 产物范围内
- 应用内更新从 v1.1.1 起生效；更早版本需手动覆盖安装一次
- 更新源配置在 `lib/services/update_checker.dart` 顶部的 `kRepoOwner` / `kRepoName`
- 发布页同时挂三个架构的 APK；更新器按设备 `supportedAbis` 选包

# zcode-remote-client

ZCode 远程终端跨平台客户端（iOS / Android / macOS / Windows），内核为完整功能的 WebView 浏览器（flutter_inappwebview），带悬浮控制栏、多会话保活、远程地址管理、应用内更新。

## 版本号规则（重要）

- **每次发版，版本号在上一次的基础上 +0.0.1**（patch 位递增），build number 同步 +1
- 例：`1.1.1+3` → 下一次发版为 `1.1.2+4`，再下一次 `1.1.3+5`
- 版本号写在 `pubspec.yaml` 的 `version:` 字段
- **Git tag 必须与 pubspec 版本一致**（带 `v` 前缀），如 `version: 1.1.1+3` 对应 tag `v1.1.1`——应用内更新依赖 tag 与 pubspec 匹配来比较版本

## 发版流程（本地手动，不用 GitHub Actions）

```bash
# 1. 升版本号（+0.0.1 / build +1）
#    编辑 pubspec.yaml: version: X.Y.Z+N

# 2. 构建 release 产物
flutter build apk --release
flutter build macos --release

# 3. 打包 macOS（保留可执行权限）
cd build/macos/Build/Products/Release
zip -r -q -y zcode-remote-client-macos-vX.Y.Z.zip zcode_remote_client.app
cd -

# 4. 提交代码并推送
git add -A && git commit -m "..." && git push origin main

# 5. 发布 Release（tag 与 pubspec 版本一致）
gh release create vX.Y.Z \
  build/app/outputs/flutter-apk/app-release.apk \
  "build/macos/Build/Products/Release/zcode-remote-client-macos-vX.Y.Z.zip#zcode-remote-client-macos-vX.Y.Z.zip" \
  --title "vX.Y.Z" --notes "更新说明..."
```

## 注意事项

- Android 包目前是 debug 签名；换正式签名后老包需卸载重装
- macOS 包未签名公证，首次打开需右键 → 打开
- iOS 需个人证书在 Xcode 自行签名打包；Windows 需 Windows 机器 `flutter build windows`
- 应用内更新从 v1.1.1 起生效；更早版本需手动覆盖安装一次
- 更新源配置在 `lib/services/update_checker.dart` 顶部的 `kRepoOwner` / `kRepoName`

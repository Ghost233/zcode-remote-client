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

# 2. 构建 release 产物（单架构瘦身 + 混淆）
#    Android 只发 arm64 包（约 18MB；通用三架构包 53MB 没必要）
flutter build apk --release --split-per-abi --obfuscate \
  --split-debug-info=build/symbols-android
flutter build macos --release --obfuscate \
  --split-debug-info=build/symbols-macos

# 3. macOS 剥掉 Intel 架构（默认 universal 双架构，体积翻倍）
APP=build/macos/Build/Products/Release/zcode_remote_client.app
find "$APP" -type f \( -name 'zcode_remote_client' -o -name 'App' -o -name 'FlutterMacOS' \) |
  while read f; do
    lipo -info "$f" 2>/dev/null | grep -q x86_64 &&
      lipo -remove x86_64 -output /tmp/_thin "$f" && mv /tmp/_thin "$f"
  done
codesign --force --deep --sign - "$APP"
# 瘦身后务必 open "$APP" 验证能启动

# 4. 附件统一命名：zcode-remote-client-<平台>-vX.Y.Z.<ext>
for abi in arm64-v8a armeabi-v7a x86_64; do
  cp build/app/outputs/flutter-apk/app-$abi-release.apk \
     /tmp/zcode-remote-client-android-$abi-vX.Y.Z.apk
done
# 打 DMG（含拖拽安装的 Applications 符号链接）
DMGROOT=/tmp/dmgroot; rm -rf "$DMGROOT" && mkdir -p "$DMGROOT"
cp -R build/macos/Build/Products/Release/zcode_remote_client.app "$DMGROOT/"
ln -s /Applications "$DMGROOT/Applications"
hdiutil create -volname "ZCode远程客户端" -srcfolder "$DMGROOT" \
  -format UDZO -ov /tmp/zcode-remote-client-macos-vX.Y.Z.dmg

# 5. 提交代码并推送
git add -A && git commit -m "..." && git push origin main

# 6. 发布 Release（tag 与 pubspec 版本一致）
gh release create vX.Y.Z \
  /tmp/zcode-remote-client-android-arm64-v8a-vX.Y.Z.apk \
  /tmp/zcode-remote-client-android-armeabi-v7a-vX.Y.Z.apk \
  /tmp/zcode-remote-client-android-x86_64-vX.Y.Z.apk \
  /tmp/zcode-remote-client-macos-vX.Y.Z.dmg \
  --title "vX.Y.Z" --notes "更新说明...\
  （注意：gh release upload 不支持 # 改名语法，必须先物理改名再上传）"
```

## 注意事项

- Android 包目前是 debug 签名；换正式签名后老包需卸载重装
- macOS 包未签名公证，首次打开需右键 → 打开
- iOS 需个人证书在 Xcode 自行签名打包；Windows 需 Windows 机器 `flutter build windows`
- 应用内更新从 v1.1.1 起生效；更早版本需手动覆盖安装一次
- 更新源配置在 `lib/services/update_checker.dart` 顶部的 `kRepoOwner` / `kRepoName`
- 发布页同时挂三个架构的 APK；更新器按设备 `supportedAbis` 选包。**arm64 必须最先上传**（旧版本更新器固定取第一个 .apk，arm64 用户占绝对多数）

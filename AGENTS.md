# zcode-remote-client

ZCode 远程终端跨平台客户端（iOS / Android / macOS / Windows），内核为完整功能的 WebView 浏览器（flutter_inappwebview），带悬浮控制栏、多会话保活、远程地址管理、应用内更新。

## 版本号规则（重要）

- **版本号唯一来源是 `pubspec.yaml` 的 `version:`，只写 `X.Y.Z`，不写 build 号**
  （例：`1.1.4`）；每次发版在上一次基础上 +0.0.1（patch 递增）
- **build 号不手写**：CI 构建时用 `--build-number` 注入（提交数 + 1000，
  自动单调递增；+1000 余量保证永远高于旧手工方案的最大 +5）
- **提交短哈希（前 6 位）**：CI 用 `--dart-define=BUILD_HASH` 注入 app
  （设置页「当前版本」可见），并附加到产物文件名
  （如 `...-v1.1.4-a1b2c3.apk`），装了哪个包能精确对应到源码 commit
- **Release tag（`vX.Y.Z`）由 CI 按 pubspec 版本自动打**，不再手写 tag，
  也因此天然不会出现 tag 与版本不一致的问题；应用内更新比较的仍是
  tag 与 app 内置版本

## 发版流程（GitHub Actions 全自动，public 仓库免费）

流水线在 `.github/workflows/release.yml`。**只允许 main 分支触发，
不支持指定 commit 构建。** 日常发版只需两改一推：

```bash
# 1. pubspec.yaml 版本 +0.0.1
# 2. RELEASE_NOTES.md 写成这次的发布说明（它就是 Release 正文）
# 3. 提交推送到 main：
git add pubspec.yaml RELEASE_NOTES.md
git commit -m "chore: 发布 v1.1.4"
git push origin main
```

推送到 main 后 CI 自动：构建 Android 三架构 / macOS 双架构 / Windows x64
（版本、构建号、短哈希全部来自被编译的 commit）→ 在该 commit 上打
tag `vX.Y.Z` → 创建 Release（说明取 RELEASE_NOTES.md + 附带构建哈希行，
附件顺序 **arm64 APK 第一个**，兼容旧版本应用内更新器）。

- **手动触发（workflow_dispatch）= 只构建验证，不发布**（也只跑 main）
- pubspec 版本与最新 Release tag 相同时，push 触发的运行会自动跳过构建
  （改依赖等触碰 pubspec 的提交不会白白跑 20 分钟）
- RELEASE_NOTES.md 缺失或为空 → 发布直接失败（强制写说明）
- 应用内更新下载（Android）：分段并行（4 连接，迅雷式）+ 断点续传
  （分段粒度，ETag 校验防串包）+ 自动重试 + 可取消，弱网可靠

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

## v1.1.9

- 修复 macOS 上网页内完全无法输入的问题：Flutter 引擎会抢占 WebView 的键盘焦点且不归还（flutter_inappwebview #2380 / flutter #134906），已升级 WebView 组件至 6.2.0-beta.3（含官方鼠标按下时的焦点归还修复）
- 修复中文输入法组合态按回车误执行命令的问题（如输入 /com 组合中按回车直接执行了 /compact）：防护脚本重写，覆盖 WebKit「组合结束事件先于回车到达、且回车不带组合标记」的引擎缺陷（WebKit Bug 165004），并补充 keyCode 229 判定与一次性吞键窗口

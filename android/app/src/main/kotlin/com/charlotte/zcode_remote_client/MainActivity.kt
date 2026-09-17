package com.charlotte.zcode_remote_client

import android.app.ActivityManager
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Process
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    // 后台保活通道：双向使用——Dart 调 start/stop/setEnabled/pinRenderers，
    // 原生把 onTrimMemory 内存压力事件回调给 Dart（见 onTrimMemory）。
    private var keepAliveChannel: MethodChannel? = null

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        // 后台保活服务的启停通道（lib/services/keep_alive.dart 调用）。
        keepAliveChannel =
            MethodChannel(engine.dartExecutor.binaryMessenger, "app/keep_alive")
        keepAliveChannel?.setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val intent = Intent(this, KeepAliveService::class.java)
                        // text：常驻通知文案（下载更新/保持会话连接）。
                        intent.putExtra("text", call.argument<String>("text"))
                        if (Build.VERSION.SDK_INT >= 26) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(true)
                    }
                    "stop" -> {
                        stopService(Intent(this, KeepAliveService::class.java))
                        result.success(true)
                    }
                    "setEnabled" -> {
                        // Dart 侧「后台保活」开关同步，原生 onPause 挂
                        // 服务时读。默认值 true 与 Dart 侧缺省一致。
                        keepAlivePrefs.edit()
                            .putBoolean(
                                KEY_KEEP_ALIVE_ENABLED,
                                call.argument<Boolean>("enabled") ?: true,
                            )
                            .apply()
                        result.success(true)
                    }
                    "pinRenderers" -> {
                        // 把全部 WebView 的渲染进程钉成高优先级
                        // （lib/services/keep_alive.dart 调用）。
                        pinWebViewRenderers()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        // 内存占用查询通道（lib/services/process_memory.dart 调用）。
        // 加总同 UID 全部进程的 RSS——WebView 渲染进程是独立进程，
        // 只报主进程会严重低估；该口径与系统设置里显示的接近。
        MethodChannel(engine.dartExecutor.binaryMessenger, "app/memory")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "rss" -> result.success(totalRssKb())
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 保活服务的主挂点。onPause 是退后台路径上 Android 12+ 后台启动
     * 前台服务限制生效前最后的成功时机——等 Dart 的生命周期回调再经
     * MethodChannel 调回来，有落在 onStop 之后被系统拒绝的时序风险
     * （异常还会被静默吞掉，v1.6.4 的下载断连就是这么来的）。
     * 服务已在运行（下载中）则不动，通知文案由 Dart 侧 inactive 回调
     * 按需刷新。瞬态 onPause（权限弹窗等）会闪挂一下，Dart 侧
     * resumed 即撤。撤回的通知停掉无启动限制，留给 Dart 即可。
     */
    override fun onPause() {
        if (keepAlivePrefs.getBoolean(KEY_KEEP_ALIVE_ENABLED, true) &&
            !KeepAliveService.running
        ) {
            try {
                val intent = Intent(this, KeepAliveService::class.java)
                if (Build.VERSION.SDK_INT >= 26) {
                    startForegroundService(intent)
                } else {
                    startService(intent)
                }
            } catch (_: Exception) {
                // 极端 ROM 在 onPause 也可能拒绝：吞掉，Dart 侧 inactive
                // 还会补挂一次；绝不能崩在 onPause 里。
            }
        }
        super.onPause()
    }

    /**
     * 回前台补钉一次渲染进程优先级：Dart 在 onWebViewCreated 就调过来
     * 时 PlatformView 可能还没挂到视图树，那次扫描会漏钉，这里兜底。
     * 对已钉实例重复设置无副作用。
     */
    override fun onResume() {
        super.onResume()
        pinWebViewRenderers()
    }

    /**
     * 系统内存吃紧（onTrimMemory）：转发给 Dart 主动挂起后台会话。
     *
     * v1.7.0 修复后台闪退的一环：与其等系统内存耗尽把整个进程组（主
     * 进程 + 全部渲染进程）连根杀，不如在系统报 RUNNING_LOW/CRITICAL
     * 或后台回收级别的第一时间，让 Dart 把不可见会话的 WebView 主动
     * 销毁（页签保留），把内存还回去。UI_HIDDEN（20）只是退后台的
     * 常规通知、不代表内存压力，排除。
     */
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        val pressing = level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW &&
            level != ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN
        if (!pressing) return
        keepAliveChannel?.invokeMethod(
            "onTrimMemory", level,
            object : MethodChannel.Result {
                override fun success(result: Any?) {}
                override fun error(
                    errorCode: String,
                    errorMessage: String?,
                    errorDetails: Any?,
                ) {}
                override fun notImplemented() {}
            },
        )
    }

    /**
     * 把视图树里全部 WebView 的渲染进程优先级钉为 NORMAL 且后台不豁免。
     *
     * 前台服务只保住了主进程与网络；WebSocket 实际活在 WebView 独立
     * 的渲染进程里。默认策略下应用退后台渲染进程会被降到 WAIVED
     * （等于 cached），Android 11+ 的冻结器整个冻住它（定时器与套接
     * 字 I/O 全停），回前台就断连刷新——这是钉扎要解决的部分：NORMAL
     * 保持在冻结线之上（非 cached 不冻结），后台连接存活。
     *
     * 为什么不是 v1.6.9 的 IMPORTANT：IMPORTANT 把渲染进程钉成「前台
     * 级不可杀」，且比挂了前台服务的主进程还难杀；多会话下系统内存
     * 紧张时 LMK 杀不动这块几百兆，最终只能把整个应用进程组连根杀
     * （用户看到的就是后台闪退）。NORMAL 让系统在极端压力下可以
     * 「只回收单个渲染进程」软着陆——应用存活，渲染进程死亡由 Dart
     * 侧挂起会话、回前台再重建（见 home_page 的 onRenderProcessGone
     * 处理），比整 app 陪葬好得多。
     *
     * 视图树随会话增删变化，每次全树扫一遍；系统 WebView 不支持该
     * 特性（老旧设备）时整体哑火。
     */
    private fun pinWebViewRenderers() {
        sweepAndPinRenderers()
        // PlatformView 挂树可能晚于 Dart 侧的调用时点：补两次延迟
        // 扫描，覆盖创建时序竞态。
        val root = window.decorView.rootView
        root.postDelayed({ sweepAndPinRenderers() }, 500)
        root.postDelayed({ sweepAndPinRenderers() }, 3000)
    }

    private fun sweepAndPinRenderers() {
        // setRendererPriorityPolicy 是 API 26 加入的框架接口，更低版本
        // 系统整体哑火；不用 androidx 包装（WebViewCompat 对应 API 要
        // webkit 1.15+ 才有，依赖抬级不划算，框架直连已足够）。
        if (Build.VERSION.SDK_INT < 26) return
        val root = window.decorView.rootView ?: return
        val queue = ArrayDeque<View>()
        queue.add(root)
        while (queue.isNotEmpty()) {
            val v = queue.removeFirst()
            if (v is WebView) {
                try {
                    v.setRendererPriorityPolicy(
                        // BOUND = 中等优先级（IMPORTANT=0 / BOUND=1 /
                        // WAIVED=2 三档）：钉在冻结线之上、低于前台级。
                        WebView.RENDERER_PRIORITY_BOUND,
                        // 后台不豁免：退后台渲染进程不降到 WAIVED、
                        // 不进冻结区，但保留 LMK 单独回收它的可能。
                        false,
                    )
                } catch (_: Exception) {
                    // 个别实例失败不影响其余（如古老内核不支持、渲染器
                    // 尚未启动）。
                }
            }
            if (v is ViewGroup) {
                for (i in 0 until v.childCount) {
                    queue.add(v.getChildAt(i))
                }
            }
        }
    }

    private val keepAlivePrefs
        get() = getSharedPreferences(PREFS_KEEP_ALIVE, Context.MODE_PRIVATE)

    private companion object {
        const val PREFS_KEEP_ALIVE = "keep_alive"
        const val KEY_KEEP_ALIVE_ENABLED = "enabled"
    }

    private fun readRssKb(pid: Int): Long {
        return try {
            File("/proc/$pid/status").readLines()
                .firstOrNull { it.startsWith("VmRSS:") }
                ?.substringAfter(':')
                ?.trim()
                ?.split(' ')
                ?.firstOrNull()
                ?.toLongOrNull() ?: 0L
        } catch (e: Exception) {
            0L
        }
    }

    private fun totalRssKb(): Long {
        return try {
            val am = getSystemService(ActivityManager::class.java)
            val uid = Process.myUid()
            var rss = 0L
            var found = false
            for (p in am.runningAppProcesses.orEmpty()) {
                if (p.uid == uid) {
                    found = true
                    rss += readRssKb(p.pid)
                }
            }
            if (!found) readRssKb(Process.myPid()) else rss
        } catch (e: Exception) {
            readRssKb(Process.myPid())
        }
    }
}

package com.charlotte.zcode_remote_client

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Process
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        // 后台保活服务的启停通道（lib/services/keep_alive.dart 调用）。
        MethodChannel(engine.dartExecutor.binaryMessenger, "app/keep_alive")
            .setMethodCallHandler { call, result ->
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

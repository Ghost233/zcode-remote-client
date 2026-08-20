package com.charlotte.zcode_remote_client

import android.app.ActivityManager
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

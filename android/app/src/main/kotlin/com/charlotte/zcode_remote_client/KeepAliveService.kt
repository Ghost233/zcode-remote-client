package com.charlotte.zcode_remote_client

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * 后台保活前台服务。
 *
 * 应用退后台时由 Dart 侧启动（回前台停止）：挂一条最低优先级的常驻
 * 通知，进程与网络因此不受 Doze/后台联网限制——ZCode 会话的 WebSocket
 * 不会断开，回到前台就不会整页刷新重连。
 *
 * 无任何后台逻辑，纯粹"占住前台服务"这个身份。
 */
class KeepAliveService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val nm = getSystemService(NotificationManager::class.java)
        val notification: Notification
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "后台保活",
                    NotificationManager.IMPORTANCE_MIN,
                )
            )
            // 回到应用的点击意图。
            val contentIntent = PendingIntent.getActivity(
                this, 0,
                Intent(this, MainActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            notification = Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_download)
                .setContentTitle("ZCode 远程客户端")
                .setContentText("正在后台保持会话连接")
                .setOngoing(true)
                .setContentIntent(contentIntent)
                .build()
        } else {
            @Suppress("DEPRECATION")
            notification = Notification.Builder(this)
                .setSmallIcon(R.drawable.ic_stat_download)
                .setContentTitle("ZCode 远程客户端")
                .setContentText("正在后台保持会话连接")
                .setOngoing(true)
                .build()
        }
        // Android 14+ 必须带类型声明；specialUse 是"不属于既有类别的合法
        // 用途"，清单里已配 FOREGROUND_SERVICE_SPECIAL_USE 权限与子类型说明。
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        // 显式随生命周期启停，不需要被杀后自行复活。
        return START_NOT_STICKY
    }

    companion object {
        private const val CHANNEL_ID = "keep_alive"
        private const val NOTIFICATION_ID = 2001
    }
}

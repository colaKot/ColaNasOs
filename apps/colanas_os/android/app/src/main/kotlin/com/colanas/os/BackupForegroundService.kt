package com.colanas.os

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * 通知栏状态。MainActivity 与 Service 在同一个进程，直接共享这一份内存；
 * 刷新通知用 NotificationManager.notify，不用再 startService —— Android 12+
 * 从后台启动服务会被系统直接拦掉，那条路走不通。
 */
object BackupNotificationState {
    @Volatile var channelName: String = "相册备份"
    @Volatile var title: String = "相册备份"
    @Volatile var text: String = ""
    @Volatile var progress: Int = -1
    @Volatile var max: Int = 100
}

/**
 * 相册备份前台服务（dataSync）。
 *
 * 只做两件事：把进程保活、显示「备份中 + 进度」的常驻通知。
 * 枚举相册 / 内容去重 / 分片上传全在 Dart 主 isolate 里跑，这里不碰 IO，
 * 免得维护两套实现。没有它，App 一切后台 Android 就会冻结甚至回收进程，
 * 上传循环断掉、连回 WiFi 的广播也收不到。
 */
class BackupForegroundService : Service() {

    companion object {
        private const val CHANNEL_ID = "com.colanas.os.backup"
        private const val NOTIFICATION_ID = 4201

        @Volatile private var live: BackupForegroundService? = null

        fun start(ctx: Context, title: String, text: String, channelName: String) {
            BackupNotificationState.channelName = channelName
            BackupNotificationState.title = title
            BackupNotificationState.text = text
            BackupNotificationState.progress = -1
            BackupNotificationState.max = 100
            val cur = live
            if (cur != null) {
                cur.refresh()
                return
            }
            launch(ctx)
        }

        fun update(ctx: Context, title: String, text: String, progress: Int, max: Int) {
            BackupNotificationState.title = title
            BackupNotificationState.text = text
            BackupNotificationState.progress = progress
            BackupNotificationState.max = max.coerceAtLeast(1)
            val cur = live
            if (cur != null) {
                cur.refresh()
                return
            }
            // 服务被系统回收过：重新拉起，通知照常显示
            launch(ctx)
        }

        fun stop(ctx: Context) {
            live?.shutdown()
            try {
                ctx.stopService(Intent(ctx, BackupForegroundService::class.java))
            } catch (_: Exception) {
                // 服务本来就没在跑
            }
        }

        private fun launch(ctx: Context) {
            val i = Intent(ctx, BackupForegroundService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ctx.startForegroundService(i)
                else ctx.startService(i)
            } catch (_: Exception) {
                // 后台启动被系统拒绝：Dart 侧照常备份，只是这次没有通知栏
            }
        }
    }

    private var inForeground = false

    override fun onCreate() {
        super.onCreate()
        live = this
        createChannelIfNeeded()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // startForeground 必须在 startForegroundService 之后 5s 内调用。
        if (!inForeground) foreground()
        return START_STICKY
    }

    private fun refresh() {
        if (!inForeground) {
            foreground()
            return
        }
        try {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .notify(NOTIFICATION_ID, buildNotification())
        } catch (_: Exception) {
            // 通知权限被关掉时忽略；前台服务仍在保活
        }
    }

    private fun foreground() {
        try {
            val n = buildNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(NOTIFICATION_ID, n)
            }
            inForeground = true
        } catch (_: Exception) {
            // 主动收掉，避免系统 5s 后按 "did not call startForeground" 杀进程
            stopSelf()
        }
    }

    fun shutdown() {
        @Suppress("DEPRECATION")
        stopForeground(true)
        try {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .cancel(NOTIFICATION_ID)
        } catch (_: Exception) {
        }
        inForeground = false
        stopSelf()
    }

    override fun onDestroy() {
        live = null
        inForeground = false
        super.onDestroy()
    }

    private fun createChannelIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
        val ch = NotificationChannel(
            CHANNEL_ID,
            BackupNotificationState.channelName,
            NotificationManager.IMPORTANCE_LOW,
        )
        ch.description = "手机相册备份进度"
        ch.setShowBadge(false)
        mgr.createNotificationChannel(ch)
    }

    private fun buildNotification(): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        var pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            pendingFlags = pendingFlags or PendingIntent.FLAG_IMMUTABLE
        }
        val pi = PendingIntent.getActivity(this, 0, launch, pendingFlags)
        val st = BackupNotificationState
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(st.title)
            .setContentText(st.text)
            .setContentIntent(pi)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setProgress(st.max, st.progress.coerceAtLeast(0), st.progress < 0)
            .build()
    }
}

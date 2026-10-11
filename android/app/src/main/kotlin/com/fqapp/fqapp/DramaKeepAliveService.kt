package com.fqapp.fqapp

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
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * 短剧播放的后台保活服务（只保活、不后台放音）。
 *
 * 为什么需要它：短剧 feed 的播放没有前台服务保护，切到别的应用后进程很快被
 * MIUI / HyperOS 等厂商系统冻结或回收，切回来就是冷启动——播放器重建、进度
 * 丢失（表现为「从头播」）。这里在**有活跃短剧会话**期间挂一个 mediaPlayback
 * 前台服务把进程优先级提上去；切后台仍照旧暂停播放（不后台放音），返回时
 * 播放器实例与位置都还在，原位续播。
 *
 * 与 ListenKeepAliveService 分开实现：那个带「上一集 / 播放暂停 / 下一集」
 * 控制按钮，属于听书场景；这里只要一条安静的通知，不引入播放控制语义。
 */
class DramaKeepAliveService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE).orEmpty()
        val playing = intent?.getBooleanExtra(EXTRA_PLAYING, true) ?: true
        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            buildNotification(title, playing),
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            } else {
                0
            },
        )
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // 用户从最近任务里划掉应用：保活没有意义了。
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            stopForeground(true)
        }
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .cancel(NOTIFICATION_ID)
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        "短剧播放",
                        NotificationManager.IMPORTANCE_LOW,
                    ).apply { setShowBadge(false) },
                )
            }
        }
    }

    private fun buildNotification(title: String, playing: Boolean): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val contentIntent = launch?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title.ifEmpty { "短剧" })
            .setContentText(if (playing) "正在播放短剧" else "已暂停，返回可继续")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(contentIntent)
            .build()
    }

    companion object {
        const val EXTRA_TITLE = "drama_title"
        const val EXTRA_PLAYING = "drama_playing"
        private const val CHANNEL_ID = "fqapp_drama_keepalive"
        private const val NOTIFICATION_ID = 4202
    }
}

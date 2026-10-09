package com.fqapp.fqapp

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 应用内自更新安装桥（fqapp/updater 通道，Dart 侧见 lib/services/app_update.dart）。
 *
 * 只做一件事：把已下载到 cache/updates 的 APK 通过 FileProvider 以
 * content:// URI 交给系统安装器（ACTION_VIEW + package-archive MIME）。
 * 不监听安装结果——用户在系统安装器里确认或取消，App 侧不感知。
 */
class UpdaterPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var context: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "fqapp/updater")
        channel?.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "installApk") {
            result.notImplemented()
            return
        }
        val ctx = context
        val path = call.argument<String>("path")
        if (ctx == null || path == null) {
            result.error("bad_args", "installApk requires a live context and a path", null)
            return
        }
        try {
            val uri: Uri = FileProvider.getUriForFile(ctx, "${ctx.packageName}.updater", File(path))
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                // applicationContext 发起的 Intent 必须开新任务栈。
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            ctx.startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("install_failed", e.message, null)
        }
    }
}

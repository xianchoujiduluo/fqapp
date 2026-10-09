import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// 应用内自更新：GitHub Releases 检查 + 下载 + 拉起系统安装器。
///
/// 版本基准：CI 构建 tag 时注入 `FQAPP_BUILD_TAG`（如 v1.0.89）；本地构建
/// 没有该常量时由调用方传展示串（'1.0.88 (90)'）兜底解析。
///
/// 这里的 GitHub 请求直连公网，不走 `api_client.dart` 的后端漏斗——那条
/// 漏斗（设备签名/取消绑定/请求合并）是番茄上游协议专属，对 GitHub 无意义。
class AppUpdate {
  AppUpdate._();

  static const _channel = MethodChannel('fqapp/updater');

  /// CI 注入的构建 tag；空串表示本地构建（未注入）。
  static const buildTag = String.fromEnvironment('FQAPP_BUILD_TAG');

  /// 更新源仓库。跟随"打 v* tag 触发构建"的 origin fork；要切上游仓库改这里。
  static const _repo = 'xianchoujiduluo/fqapp';

  /// 从展示串解析语义化版本三元组：'v1.0.89' / '1.0.88 (90)' → [1, 0, 88]。
  /// 解析不了返回 null（视为无法比较，按"无更新"处理）。
  static List<int>? parseVersion(String raw) {
    var text = raw.trim();
    if (text.startsWith('v')) text = text.substring(1);
    final dash = text.indexOf('-');
    if (dash >= 0) text = text.substring(0, dash);
    final parts = text.split(RegExp(r'[^0-9]+')).where((p) => p.isNotEmpty).toList();
    if (parts.length < 2) return null;
    final nums = <int>[];
    for (final part in parts.take(3)) {
      final n = int.tryParse(part);
      if (n == null) return null;
      nums.add(n);
    }
    while (nums.length < 3) {
      nums.add(0);
    }
    return nums;
  }

  /// latest 的 tag 是否比 current 新（逐元组比较；任一侧解析失败返回 false）。
  static bool isNewer(String latestTag, String currentTag) {
    final a = parseVersion(latestTag);
    final b = parseVersion(currentTag);
    if (a == null || b == null) return false;
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] > b[i];
    }
    return false;
  }

  /// 拉最新 Release 信息。无 arm64 APK 资产或网络失败抛 [UpdateException]。
  static Future<ReleaseInfo> fetchLatest() async {
    http.Response resp;
    try {
      resp = await http
          .get(
            Uri.parse('https://api.github.com/repos/$_repo/releases/latest'),
            headers: {'Accept': 'application/vnd.github+json'},
          )
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      throw UpdateException('网络请求失败：$e');
    }
    if (resp.statusCode != 200) {
      throw UpdateException('GitHub 返回 ${resp.statusCode}（还没有 Release 或被限流）');
    }
    return ReleaseInfo.fromJson(_decodeJson(resp.body));
  }

  /// 流式下载 APK 到临时目录（cache/updates/），返回文件绝对路径。
  /// [onProgress] 回调 (已收字节, 总字节)，总字节未知时为 0。
  static Future<String> download(
    ReleaseInfo info,
    void Function(int received, int total) onProgress,
  ) async {
    final client = http.Client();
    try {
      final resp = await client.send(http.Request('GET', Uri.parse(info.apkUrl)));
      if (resp.statusCode != 200) {
        throw UpdateException('下载失败：HTTP ${resp.statusCode}');
      }
      final total = resp.contentLength ?? 0;
      final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
      await dir.create(recursive: true);
      final file = File('${dir.path}/${info.apkName}');
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in resp.stream) {
          sink.add(chunk);
          received += chunk.length;
          onProgress(received, total);
        }
      } finally {
        await sink.close();
      }
      if (total > 0 && received != total) {
        await file.delete();
        throw UpdateException('下载不完整（$received/$total），已清理');
      }
      return file.path;
    } finally {
      client.close();
    }
  }

  /// 拉起系统安装器。返回 false 表示原生侧无法发起（无上下文等）。
  static Future<bool> install(String apkPath) async {
    try {
      return await _channel.invokeMethod<bool>('installApk', {'path': apkPath}) ??
          false;
    } on PlatformException catch (e) {
      throw UpdateException('无法发起安装：${e.message}');
    }
  }

  static dynamic _decodeJson(String body) => jsonDecode(body);
}

/// 一条 GitHub Release 的最小信息。
class ReleaseInfo {
  const ReleaseInfo({
    required this.tag,
    required this.notes,
    required this.apkUrl,
    required this.apkName,
    required this.apkSize,
  });

  final String tag;
  final String? notes;
  final String apkUrl;
  final String apkName;
  final int apkSize;

  /// 从 Releases API 的 JSON 提取 arm64 APK 资产。
  static ReleaseInfo fromJson(dynamic json) {
    final tag = json['tag_name'] as String?;
    if (tag == null || tag.isEmpty) {
      throw UpdateException('Release 缺少 tag_name');
    }
    final assets = json['assets'] as List<dynamic>? ?? const [];
    dynamic apk;
    for (final asset in assets) {
      final name = (asset['name'] as String?) ?? '';
      final url = (asset['browser_download_url'] as String?) ?? '';
      if (name.toLowerCase().endsWith('.apk') &&
          (name.toLowerCase().contains('arm64') || url.toLowerCase().contains('arm64'))) {
        apk = asset;
        break;
      }
    }
    if (apk == null) {
      throw UpdateException('最新 Release（$tag）没有 arm64 APK 资产');
    }
    return ReleaseInfo(
      tag: tag,
      notes: json['body'] as String?,
      apkUrl: apk['browser_download_url'] as String,
      apkName: apk['name'] as String? ?? 'fqapp-update.apk',
      apkSize: (apk['size'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 更新流程里的可预期失败，message 直接可展示给用户。
class UpdateException implements Exception {
  UpdateException(this.message);
  final String message;

  @override
  String toString() => message;
}

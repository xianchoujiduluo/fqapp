import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'app_log.dart';

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

  /// 拉最新 Release 信息。
  ///
  /// 优先官方 API（数据最全）；**被匿名限流或网络不可达时回退 releases.atom**
  /// ——该端点不是 API，无鉴权也无每 IP 六十次/小时的配额，国内挂着共享出口
  /// VPN 时 API 几乎必然 403（实测），而 atom 正常（实测）。两条通道都失败才
  /// 抛 [UpdateException]，错误里同时带上两边的原因。
  static Future<ReleaseInfo> fetchLatest() async {
    try {
      return await _fetchLatestViaApi();
    } on UpdateException catch (apiError) {
      AppLog.w('update', 'GitHub API 不可用（${apiError.message}），回退 releases.atom');
      try {
        return await _fetchLatestViaAtom();
      } on UpdateException catch (atomError) {
        throw UpdateException('检查更新失败：${apiError.message}；备用通道：${atomError.message}');
      }
    }
  }

  static Future<ReleaseInfo> _fetchLatestViaApi() async {
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
    if (resp.statusCode == 403) {
      throw UpdateException('GitHub API 限流（匿名 60 次/小时/IP）');
    }
    if (resp.statusCode == 404) {
      throw UpdateException('还没有发布 Release');
    }
    if (resp.statusCode != 200) {
      throw UpdateException('GitHub API 返回 HTTP ${resp.statusCode}');
    }
    return ReleaseInfo.fromJson(_decodeJson(resp.body));
  }

  /// 备用通道：`releases.atom`（无鉴权、无 API 配额）。
  ///
  /// atom 不含资产信息，所以下载地址按本仓库发布资产的固定命名约定构造
  /// （`fqapp-<版本>-arm64.apk`），并用 HEAD 验证确实存在、顺带取字节数。
  ///
  /// 字段提取不依赖 HTML/XML 解析器对非标准标签的宽容度：feed 是 GitHub
  /// 机器生成的稳定结构（`<entry>` 无属性、首块即最新），按块取字段更可预测。
  static Future<ReleaseInfo> _fetchLatestViaAtom() async {
    http.Response resp;
    try {
      resp = await http
          .get(Uri.parse('https://github.com/$_repo/releases.atom'))
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      throw UpdateException('网络请求失败：$e');
    }
    if (resp.statusCode != 200) {
      throw UpdateException('HTTP ${resp.statusCode}');
    }
    final blocks = resp.body.split('<entry>');
    if (blocks.length < 2) {
      throw UpdateException('解析不到版本号（可能还没发布 Release）');
    }
    final latest = blocks[1];
    final tag =
        RegExp(
          r'<title>([^<]+)</title>',
        ).firstMatch(latest)?.group(1)?.trim() ??
        '';
    if (tag.isEmpty) {
      throw UpdateException('解析不到版本号（可能还没发布 Release）');
    }
    final rawNotes =
        RegExp(
          r'<content[^>]*>([\s\S]*?)</content>',
        ).firstMatch(latest)?.group(1) ??
        '';
    final version = tag.startsWith('v') ? tag.substring(1) : tag;
    final apkUrl =
        'https://github.com/$_repo/releases/download/$tag/fqapp-$version-arm64.apk';
    var apkSize = 0;
    try {
      final head = await http
          .head(Uri.parse(apkUrl))
          .timeout(const Duration(seconds: 15));
      if (head.statusCode != 200) {
        throw UpdateException('$tag 没有可下载的 arm64 安装包（HTTP ${head.statusCode}）');
      }
      apkSize = int.tryParse(head.headers['content-length'] ?? '') ?? 0;
    } on UpdateException {
      rethrow;
    } catch (e) {
      throw UpdateException('校验安装包失败：$e');
    }
    return ReleaseInfo(
      tag: tag,
      notes: _plainText(rawNotes),
      apkUrl: apkUrl,
      apkName: 'fqapp-$version-arm64.apk',
      apkSize: apkSize,
    );
  }

  /// atom 的 `content` 是**转义后**的 HTML，必须先反转义再剥标签，否则
  /// `&lt;h2&gt;` 洗不掉（`&amp;` 放最后，避免二次解码）。
  static String _plainText(String html) {
    if (html.trim().isEmpty) return '';
    var text = html;
    const entities = {
      '&lt;': '<',
      '&gt;': '>',
      '&quot;': '"',
      '&#39;': "'",
      '&nbsp;': ' ',
    };
    for (final entity in entities.entries) {
      text = text.replaceAll(entity.key, entity.value);
    }
    text = text
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(
          RegExp(r'</(p|li|h[1-6]|div|ul|ol)>', caseSensitive: false),
          '\n',
        )
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&amp;', '&');
    return text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join('\n');
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

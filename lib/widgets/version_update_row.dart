import 'package:flutter/material.dart';

import '../services/app_update.dart';

/// 关于页的「当前版本」行：展示构建版本（CI 注入 tag 优先），点击触发
/// GitHub 更新检查——有新版时弹窗展示说明并支持下载后拉起系统安装器。
///
/// 状态机：idle → checking → (已是最新 | 发现新版 → 确认 → downloading → 安装)。
class VersionUpdateRow extends StatefulWidget {
  const VersionUpdateRow({super.key, required this.fallbackVersionText});

  /// 本地构建（未注入 FQAPP_BUILD_TAG）时展示的兜底版本串，
  /// 来自 AboutPage.versionText（与 pubspec 锁步同步）。
  final String fallbackVersionText;

  @override
  State<VersionUpdateRow> createState() => _VersionUpdateRowState();
}

class _VersionUpdateRowState extends State<VersionUpdateRow> {
  bool _checking = false;

  /// 当前版本串：tag（v1.0.89）优先，否则用完整展示串（'1.0.89 (91)'，
  /// 含构建号后缀——widget 测试 review_fix_b07 会直接找这个文本，不能截断）。
  /// 版本比较用的 AppUpdate.parseVersion 能吃下带后缀的串，无需预先拆分。
  String get _currentVersion =>
      AppUpdate.buildTag.isNotEmpty
          ? AppUpdate.buildTag
          : widget.fallbackVersionText;

  void _snack(String text) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
  }

  Future<void> _onTap() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final release = await AppUpdate.fetchLatest();
      if (!mounted) return;
      if (!AppUpdate.isNewer(release.tag, _currentVersion)) {
        _snack('已是最新版本（${release.tag}）');
        return;
      }
      final confirmed = await _confirmDialog(context, release);
      if (confirmed == true) {
        await _downloadAndInstall(release);
      }
    } on UpdateException catch (e) {
      if (mounted) _snack(e.message);
    } catch (e) {
      if (mounted) _snack('检查更新失败：$e');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<bool?> _confirmDialog(BuildContext context, ReleaseInfo release) {
    final theme = Theme.of(context);
    final outline = theme.colorScheme.outline;
    final sizeText =
        release.apkSize > 0
            ? '（${(release.apkSize / 1024 / 1024).toStringAsFixed(1)} MB）'
            : '';
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('发现新版本 ${release.tag}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '当前 $_currentVersion → ${release.tag} $sizeText',
              style: TextStyle(fontSize: 13, color: outline),
            ),
            if ((release.notes ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: SingleChildScrollView(
                  child: Text(
                    release.notes!,
                    style: const TextStyle(fontSize: 13, height: 1.4),
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('稍后再说')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('下载并安装')),
        ],
      ),
    );
  }

  Future<void> _downloadAndInstall(ReleaseInfo release) async {
    final progress = ValueNotifier<(int, int)>((0, 0));
    // 关闭动作绑定弹窗自身的 context：下载中用户离开页面也不会误弹页面路由。
    void Function()? closeDialog;
    final dialogFuture = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        closeDialog = () => Navigator.of(dialogContext).pop();
        return ValueListenableBuilder<(int, int)>(
          valueListenable: progress,
          builder: (context, value, _) {
            final (received, total) = value;
            final ratio = total > 0 ? received / total : null;
            final text =
                total > 0
                    ? '${(received / 1024 / 1024).toStringAsFixed(1)} / '
                        '${(total / 1024 / 1024).toStringAsFixed(1)} MB'
                    : '${(received / 1024 / 1024).toStringAsFixed(1)} MB';
            return AlertDialog(
              title: const Text('正在下载'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(value: ratio?.clamp(0.0, 1.0)),
                  const SizedBox(height: 10),
                  Text(text, style: const TextStyle(fontSize: 13)),
                ],
              ),
            );
          },
        );
      },
    );
    try {
      final path = await AppUpdate.download(
        release,
        (received, total) => progress.value = (received, total),
      );
      await AppUpdate.install(path);
    } finally {
      progress.dispose();
      // 下载结束（无论成败）关掉进度框；安装器已在系统侧接管。
      closeDialog?.call();
      await dialogFuture.catchError((_) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outline = theme.colorScheme.outline;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      onTap: _onTap,
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          Icons.commit_outlined,
          size: 20,
          color: theme.colorScheme.primary,
        ),
      ),
      title: const Text('当前版本', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
      subtitle: Text('点击检查更新', style: theme.textTheme.labelMedium?.copyWith(color: outline)),
      trailing:
          _checking
              ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
              : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_currentVersion, style: TextStyle(fontSize: 13, color: outline)),
                  const SizedBox(width: 4),
                  Icon(Icons.update, size: 16, color: outline),
                ],
              ),
    );
  }
}

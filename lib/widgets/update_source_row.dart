import 'package:flutter/material.dart';

import '../services/app_update.dart';

/// 关于页的「更新源」行：**始终把当前地址摆出来**（默认是仓库的 GitHub 地址），
/// 点击可改成任意地址——内网环境改成自建更新源后，检查更新读该地址下的
/// `update.json`，不再依赖 GitHub 可达。
class UpdateSourceRow extends StatefulWidget {
  const UpdateSourceRow({super.key});

  @override
  State<UpdateSourceRow> createState() => _UpdateSourceRowState();
}

class _UpdateSourceRowState extends State<UpdateSourceRow> {
  String _source = AppUpdate.defaultSource;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final source = await AppUpdate.getSource();
    if (!mounted) return;
    setState(() => _source = source);
  }

  Future<void> _edit() async {
    final controller = TextEditingController(text: _source);
    final theme = Theme.of(context);
    final outline = theme.colorScheme.outline;
    final entered = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('更新源地址'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(hintText: 'https://…'),
            ),
            const SizedBox(height: 10),
            Text(
              'GitHub 仓库地址，或自建更新源地址（其下需有 update.json）',
              style: TextStyle(fontSize: 12, color: outline),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, AppUpdate.defaultSource),
            child: const Text('恢复默认'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (entered == null) return;
    await AppUpdate.setSource(entered);
    if (!mounted) return;
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('更新源已设为 $_source'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outline = theme.colorScheme.outline;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      onTap: _edit,
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          Icons.cloud_outlined,
          size: 20,
          color: theme.colorScheme.primary,
        ),
      ),
      title: const Text(
        '更新源',
        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      ),
      // 地址可能很长：单行省略，完整值点进去在输入框里看。
      subtitle: Text(
        _source,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelMedium?.copyWith(color: outline),
      ),
      trailing: Icon(Icons.edit_outlined, size: 16, color: outline),
    );
  }
}

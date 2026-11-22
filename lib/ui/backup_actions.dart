// ignore_for_file: deprecated_member_use
// Flutter 3.50 将 material.dart 标记为 deprecated，Material 组件本版本仍可用。
import 'dart:convert';

import 'package:flutter/material.dart';

import '../data/backup_gateway.dart';
import '../data/inventory_repository.dart';

/// 备份/恢复操作块（可复用）。
///
/// 承载导出（系统分享面板）与恢复（文件选择器 + 确认框 + 覆盖还原）的
/// 全部交互逻辑，业务逻辑与 V3.1 完全一致；只改承载方式：
/// - [compact] = true：横向两个按钮，供明细页底部固定操作区；
/// - [compact] = false：纵向两个全宽按钮，供独立备份页主体。
///
/// 恢复成功后回调 [onRestored]（调用方刷新列表）。
class BackupActions extends StatefulWidget {
  const BackupActions({
    super.key,
    required this.repository,
    this.gateway,
    this.onRestored,
    this.compact = true,
  });

  final InventoryRepository repository;

  /// 备份交互网关；生产默认系统实现，测试注入假网关。
  final BackupGateway? gateway;

  /// 恢复完成（成功）后的回调，例如刷新明细列表。
  final Future<void> Function()? onRestored;

  /// true = 底部操作区横排；false = 独立页纵排全宽。
  final bool compact;

  @override
  State<BackupActions> createState() => _BackupActionsState();
}

class _BackupActionsState extends State<BackupActions> {
  BackupGateway get _gateway => widget.gateway ?? SystemBackupGateway();

  bool _busy = false;

  // ---------- 备份导出 ----------

  Future<void> _exportBackup() async {
    setState(() => _busy = true);
    try {
      final backup = await widget.repository.exportBackup();
      final path = await _gateway
          .writeBackupFile(const JsonEncoder.withIndent('  ').convert(backup));
      await _gateway.shareFile(path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          // 路径分隔符双兼容（Windows \ 与 POSIX /），只取文件名展示。
          content: Text('备份已生成：${path.split('/').last.split('\\').last}'),
        ),
      );
    } on Exception catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败：$e')),
      );
    }
    if (!mounted) return;
    setState(() => _busy = false);
  }

  // ---------- 备份恢复 ----------

  Future<void> _startRestore() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复备份'),
        content: const Text(
          '将从备份文件覆盖当前全部数据。\n\n'
          '建议先点「导出备份」留存当前数据，'
          '再选择要恢复的 .json 文件。',
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('restore_cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('restore_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('选择文件并恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final path = await _gateway.pickBackupFile();
    if (path == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final raw = await _gateway.readBackupFile(path);
      final data = jsonDecode(raw) as Map<String, dynamic>;
      await widget.repository.restoreBackup(data);
      await widget.onRestored?.call();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('恢复完成。')),
      );
    } on FormatException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('恢复失败：不是有效的备份 JSON（${e.message}）')),
      );
    } on ArgumentError catch (e) {
      // 仓储校验（非本应用备份/缺表/版本过高）抛 ArgumentError（Error 非
      // Exception），必须单独接住，否则真机选到非法备份会崩页。
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('恢复失败：${e.message ?? e}')),
      );
    } on Exception catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('恢复失败：$e')),
      );
    }
    if (!mounted) return;
    setState(() => _busy = false);
  }

  // ---------- 界面 ----------

  @override
  Widget build(BuildContext context) {
    final exportButton = FilledButton.tonalIcon(
      key: const Key('export_backup'),
      onPressed: _busy ? null : _exportBackup,
      icon: const Icon(Icons.ios_share),
      label: const Text('导出备份'),
    );
    final restoreButton = OutlinedButton.icon(
      key: const Key('restore_backup'),
      onPressed: _busy ? null : _startRestore,
      icon: const Icon(Icons.restore),
      label: const Text('恢复备份'),
    );
    if (widget.compact) {
      return Row(
        children: <Widget>[
          Expanded(child: exportButton),
          const SizedBox(width: 12),
          Expanded(child: restoreButton),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        exportButton,
        const SizedBox(height: 12),
        restoreButton,
      ],
    );
  }
}

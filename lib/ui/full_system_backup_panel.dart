// ignore_for_file: deprecated_member_use
// Flutter 3.50 将 material.dart 标记为 deprecated，Material 组件本版本仍可用。
import 'dart:convert';

import 'package:flutter/material.dart';

import '../data/backup_gateway.dart';
import '../domain/backup_archiver.dart';
import '../domain/full_system_backup.dart';

/// V4.2.1（+34）：全系统备份操作块——生活区 + 工作区**一份文件**。
///
/// 交互模式与 [BackupActions] 完全对齐（点击=保存到手机 / 长按=分享、
/// 恢复走确认框+文件选择器、失败明确提示），只是操作对象从一本账
/// 变成两本账。业务编排全部在 [FullSystemBackup]，本组件只管交互。
///
/// 恢复成功后回调 [onRestored]（调用方刷新界面——V4.1.7 铁律：
/// 恢复=清空重灌，首页内存态全部陈旧）。
class FullSystemBackupPanel extends StatefulWidget {
  const FullSystemBackupPanel({
    super.key,
    required this.service,
    this.gateway,
    this.onRestored,
    this.archiver,
  });

  final FullSystemBackup service;

  /// 备份交互网关；生产默认系统实现，测试注入假网关。
  final BackupGateway? gateway;

  /// 恢复完成（成功）后的回调，例如刷新首页。
  final Future<void> Function()? onRestored;

  /// V4.3.1（+38 P0-1）：内档轮转器；null = 不轮转（仅测试/旧链路），
  /// 生产组合根必须注入 [BackupArchiver] 实例。
  final BackupArchiver? archiver;

  @override
  State<FullSystemBackupPanel> createState() => _FullSystemBackupPanelState();
}

class _FullSystemBackupPanelState extends State<FullSystemBackupPanel> {
  BackupGateway get _gateway => widget.gateway ?? SystemBackupGateway();

  bool _busy = false;

  String _backupFileName(DateTime now) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '小本本-全系统-'
        '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}.json';
  }

  /// 点击导出 = 保存到手机（与分区导出同口径）；长按 = 分享。
  /// V4.3.1（+38 P0-1）：导出成功后同步写一份内档并轮转（本地留最近 3 份），
  /// 轮转发生时在回执里报一行「备份轮转，删除最旧备份 xxx」。
  Future<void> _saveBackup() async {
    setState(() => _busy = true);
    try {
      final backup = await widget.service.exportAll();
      final json =
          const JsonEncoder.withIndent('  ').convert(backup);
      final bytes = utf8.encode(json);
      final fileName = _backupFileName(DateTime.now());
      final saved = await _gateway.saveBytesToDevice(fileName, bytes);
      if (!mounted) return;
      if (saved == null) {
        setState(() => _busy = false);
        return;
      }
      // archiver 为 null = 不轮转（测试/旧链路）；生产组合根注入实例。
      final archiver = widget.archiver;
      final rotated = archiver == null
          ? null
          : await archiver.archiveAndRotate(json);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(rotated == null
              ? '已保存：$fileName（含生活区+工作区）'
              : '已保存：$fileName · 备份轮转，删除最旧备份 $rotated（本地保留最近 ${widget.archiver?.keepCount ?? 3} 份）'),
        ),
      );
    } on ArgumentError catch (e) {
      // P0-2：完整性校验不通过——坏数据绝不写进备份文件。
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message is String
              ? e.message
              : '数据异常，暂不备份，请联系排查'),
        ),
      );
    } catch (_) {
      // 兜住 Error + Exception（口径同分区导出：失败必须明确提示）。
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法保存，请改用分享（长按导出按钮）')),
      );
    }
    if (!mounted) return;
    setState(() => _busy = false);
  }

  Future<void> _shareBackup() async {
    setState(() => _busy = true);
    try {
      final backup = await widget.service.exportAll();
      final json =
          const JsonEncoder.withIndent('  ').convert(backup);
      final path = await _gateway.writeBackupFile(json);
      await _gateway.shareFile(path);
      if (!mounted) return;
      final archiver = widget.archiver;
      final rotated = archiver == null
          ? null
          : await archiver.archiveAndRotate(json);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(rotated == null
              ? '备份已生成：${path.split('/').last.split('\\').last}'
              : '备份已生成：${path.split('/').last.split('\\').last}'
                  ' · 备份轮转，删除最旧备份 $rotated（本地保留最近 ${widget.archiver?.keepCount ?? 3} 份）'),
        ),
      );
    } on ArgumentError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message is String
              ? e.message
              : '数据异常，暂不备份，请联系排查'),
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

  Future<void> _startRestore() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('全系统恢复'),
        content: const Text(
          '将从备份文件覆盖生活区和工作区的全部数据（两本账一起被覆盖）。\n\n'
          '建议先点「导出全系统备份」留存当前数据，'
          '再选择要恢复的 .json 文件。\n'
          '分区备份（单个区域的文件）不能在这里恢复。',
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('full_restore_cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('full_restore_confirm'),
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
      await widget.service.restoreAll(data);
      await widget.onRestored?.call();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          content: Text(widget.service.restoreResultText(data)),
        ),
      );
    } on FormatException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('恢复失败：不是有效的备份 JSON（${e.message}）')),
      );
    } on ArgumentError catch (e) {
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

  @override
  Widget build(BuildContext context) {
    final exportButton = GestureDetector(
      key: const Key('full_export_backup'),
      onLongPress: _busy ? null : _shareBackup,
      child: FilledButton.tonalIcon(
        onPressed: _busy ? null : _saveBackup,
        icon: const Icon(Icons.import_contacts),
        label: const Text('导出全系统备份'),
      ),
    );
    final restoreButton = OutlinedButton.icon(
      key: const Key('full_restore_backup'),
      onPressed: _busy ? null : _startRestore,
      icon: const Icon(Icons.settings_backup_restore),
      label: const Text('全系统恢复'),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        exportButton,
        const SizedBox(height: 12),
        restoreButton,
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
            '长按可分享给好友',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
      ],
    );
  }
}

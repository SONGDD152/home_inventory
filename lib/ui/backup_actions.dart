// ignore_for_file: deprecated_member_use
// Flutter 3.50 将 material.dart 标记为 deprecated，Material 组件本版本仍可用。
import 'dart:convert';

import 'package:flutter/material.dart';

import '../data/backup_gateway.dart';
import '../data/domain.dart';
import '../data/inventory_repository.dart';

/// 备份/恢复/Excel 导出操作块（可复用）。
///
/// 承载导出（系统分享面板）与恢复（文件选择器 + 确认框 + 覆盖还原）的
/// 全部交互逻辑，业务逻辑与 V3.1 完全一致；只改承载方式：
/// - [compact] = true：横向按钮排，供明细页底部固定操作区；
/// - [compact] = false：纵向全宽按钮，供独立备份页主体。
/// - [onExportExcel] 非 null 时追加「导出Excel」按钮（V3.6 明细页）。
///
/// 恢复成功后回调 [onRestored]（调用方刷新列表）。
class BackupActions extends StatefulWidget {
  const BackupActions({
    super.key,
    required this.repository,
    this.gateway,
    this.onRestored,
    this.onExportExcel,
    this.onShareExcel,
    this.compact = true,
    this.domain = InventoryDomain.life,
  });

  /// V4.0：这一份备份属于哪个域（文件名带域标识）。
  final InventoryDomain domain;

  final InventoryRepository repository;

  /// 备份交互网关；生产默认系统实现，测试注入假网关。
  final BackupGateway? gateway;

  /// 恢复完成（成功）后的回调，例如刷新明细列表。
  final Future<void> Function()? onRestored;

  /// V3.6.1：Excel「点击=保存到手机」回调；null 表示不显示该按钮（备份页不受影响）。
  /// 导出与保存的全部逻辑在调用方（明细页持有 exporter 与数据）。
  final Future<void> Function()? onExportExcel;

  /// V3.6.1：Excel「长按=分享给好友」回调。生产必传（与 onExportExcel 配套）；
  /// null 时 Excel 按钮仍可点击保存，仅长按无分享。
  final Future<void> Function()? onShareExcel;

  /// true = 底部操作区横排；false = 独立页纵排全宽。
  final bool compact;

  @override
  State<BackupActions> createState() => _BackupActionsState();
}

class _BackupActionsState extends State<BackupActions> {
  BackupGateway get _gateway => widget.gateway ?? SystemBackupGateway();

  bool _busy = false;

  // ---------- 备份导出 ----------

  /// 备份文件名（V4.0 起带域标识：分库后一份备份就是一个域，
  /// 文件名必须能分清是哪本账）。
  String _backupFileName(DateTime now) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '家庭仓储-${widget.domain.storageLabel}-'
        '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}.json';
  }

  /// V3.6.1：点击导出 = 直接保存到手机（系统 SAF 保存对话框）。
  /// null（用户取消）静默无提示；异常（磁盘满/权限/ROM 拒绝）明确提示。
  Future<void> _saveBackup() async {
    setState(() => _busy = true);
    try {
      final backup = await widget.repository.exportBackup();
      final bytes = utf8.encode(
        const JsonEncoder.withIndent('  ').convert(backup),
      );
      final fileName = _backupFileName(DateTime.now());
      final saved = await _gateway.saveBytesToDevice(fileName, bytes);
      if (!mounted) return;
      if (saved == null) {
        // 用户取消：SAF 对话框自带取消，这里静默、不提示、不报错。
        setState(() => _busy = false);
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已保存：$fileName')),
      );
    } catch (_) {
      // 兜住 Error + Exception：file_picker 失败可能抛 PlatformException，
      // 也可能抛 Error（磁盘满/ROM 拒绝）。元宝 b 条：失败必须明确提示。
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法保存，请改用分享（长按导出按钮）')),
      );
    }
    if (!mounted) return;
    setState(() => _busy = false);
  }

  /// V3.6.1：长按导出 = 走原系统分享面板（发微信/邮箱等）。
  Future<void> _shareBackup() async {
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

  /// V3.6.1：Excel 长按 = 走原分享链路（回调交给明细页）。
  Future<void> _shareExcel() async {
    final callback = widget.onShareExcel;
    if (callback == null) return;
    setState(() => _busy = true);
    try {
      await callback();
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
        // 注意：首句保持 V3.6 原文（旧测试按这句话定位弹窗正文），
        // 域信息追加在后面，不改既有口径。
        content: Text(
          '将从备份文件覆盖当前全部数据（${widget.domain.label}）。\n\n'
          '建议先点「导出备份」留存当前数据，'
          '再选择要恢复的 .json 文件。\n'
          '别的区域的备份不能恢复到这里。',
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
    // V3.6.1：点击 = 保存到手机；长按 = 分享给好友。
    // 用 GestureDetector 包住按钮接长按，按钮 onPressed 仍走点击（互不冲突）。
    final exportButton = GestureDetector(
      key: const Key('export_backup'),
      onLongPress: _busy ? null : _shareBackup,
      child: FilledButton.tonalIcon(
        onPressed: _busy ? null : _saveBackup,
        icon: const Icon(Icons.ios_share),
        label: const Text('导出备份'),
      ),
    );
    final restoreButton = OutlinedButton.icon(
      key: const Key('restore_backup'),
      onPressed: _busy ? null : _startRestore,
      icon: const Icon(Icons.restore),
      label: const Text('恢复备份'),
    );
    final excelButton = widget.onExportExcel == null
        ? null
        : GestureDetector(
            key: const Key('export_excel'),
            onLongPress: _busy ? null : _shareExcel,
            child: FilledButton.tonalIcon(
              onPressed: _busy ? null : widget.onExportExcel,
              icon: const Icon(Icons.table_view),
              label: const Text('导出Excel'),
            ),
          );
    // 元宝修订①：提示文案「长按可分享给好友」，12sp，灰字不抢按钮。
    const hint = Padding(
      padding: EdgeInsets.only(top: 6),
      child: Text(
        '长按可分享给好友',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, color: Colors.grey),
      ),
    );
    if (widget.compact) {
      final children = <Widget>[
        Expanded(child: exportButton),
        const SizedBox(width: 12),
        Expanded(child: restoreButton),
      ];
      if (excelButton != null) {
        children
          ..add(const SizedBox(width: 12))
          ..add(Expanded(child: excelButton));
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[Row(children: children), hint],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        exportButton,
        const SizedBox(height: 12),
        restoreButton,
        if (excelButton != null) ...<Widget>[
          const SizedBox(height: 12),
          excelButton,
        ],
        hint,
      ],
    );
  }
}

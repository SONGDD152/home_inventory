// ignore_for_file: deprecated_member_use
// Flutter 3.50 将 material.dart 标记为 deprecated，Material 组件本版本仍可用。
import 'package:flutter/material.dart';

import '../data/backup_gateway.dart';
import '../data/domain.dart';
import '../data/inventory_repository.dart';
import '../domain/full_system_backup.dart';
import 'backup_actions.dart';
import 'full_system_backup_panel.dart';

/// 数据备份与恢复页：抽屉直达的独立入口。
///
/// 业务逻辑与 V3.1 完全一致（BackupActions 承载），本页只负责
/// 说明文案与页面承载——导出走系统分享面板，恢复走文件选择器
/// 并在确认后覆盖还原。
class BackupPage extends StatelessWidget {
  const BackupPage({
    super.key,
    required this.repository,
    this.gateway,
    this.domain = InventoryDomain.life,
    this.onRestored,
    this.fullSystem,
  });

  final InventoryRepository repository;

  /// V4.0：本页备份/恢复的是哪个域。
  final InventoryDomain domain;

  /// 备份交互网关；生产默认系统实现，测试注入假网关。
  final BackupGateway? gateway;

  /// V4.1.7（演练打回）：恢复成功后的回调——**必须让首页刷新**。
  ///
  /// 演练真机打回的根因之一：恢复=清空重灌整本账，但首页的概览/日程签
  /// 数据只在 initState 读一次，恢复完返回首页看到的还是**恢复前的
  /// 内存数据**（新装包=空库），体感就是「导入后数据丢了」。
  /// 生活区「正常」只是因为切域走了 _switchSection 的全量刷新。
  final Future<void> Function()? onRestored;

  /// V4.2.1（+34）：全系统备份服务（生活+工作一份文件）。
  ///
  /// null = 不显示全系统区（单测注入单域仓储时的旧行为）；
  /// 非空 = 页面顶部追加「全系统备份」区。分区备份/恢复**原样保留**：
  /// 旧单域备份文件仍然只从分区入口恢复。
  final FullSystemBackup? fullSystem;

  @override
  Widget build(BuildContext context) {
    final fullSystem = this.fullSystem;
    return Scaffold(
      appBar: AppBar(title: const Text('数据备份与恢复')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // V4.2.1（+34）：全系统区置顶——一份文件管两本账，迁移场景
            // 这是首选入口；分区备份下沉为「进阶」用途。
            if (fullSystem != null) ...<Widget>[
              const Text('全系统备份（推荐）',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text(
                '把生活区和工作区两本账打包成一份 JSON 文件，'
                '一次导出、一次恢复，迁移不用来回切区域。',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              FullSystemBackupPanel(
                service: fullSystem,
                gateway: gateway,
                onRestored: onRestored,
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 16),
              const Text('分区备份（单个区域）',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
            ] else ...<Widget>[
              const Text('备份与恢复',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
            ],
            const Text(
              '备份会把全部物品和位置打包成一个 JSON 文件。'
              '导出文件将通过系统对话框保存到您选择的位置（如下载、文档等）；'
              '长按导出按钮可分享给好友。'
              '恢复会从所选文件覆盖当前全部数据。',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            BackupActions(
              repository: repository,
              gateway: gateway,
              compact: false,
              domain: domain,
              onRestored: onRestored,
            ),
          ],
        ),
      ),
    );
  }
}

// ignore_for_file: deprecated_member_use
// Flutter 3.50 将 material.dart 标记为 deprecated，Material 组件本版本仍可用。
import 'package:flutter/material.dart';

import '../data/backup_gateway.dart';
import '../data/domain.dart';
import '../data/inventory_repository.dart';
import 'backup_actions.dart';

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('数据备份与恢复')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text('备份与恢复',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
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

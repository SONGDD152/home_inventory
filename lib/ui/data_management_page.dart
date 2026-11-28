// ignore_for_file: deprecated_member_use
// Flutter 3.50 将 material.dart 标记为 deprecated，Material 组件本版本仍可用。
import 'package:flutter/material.dart';

import '../data/backup_gateway.dart';
import '../data/domain.dart';
import '../data/inventory_repository.dart';
import '../domain/full_system_backup.dart';
import 'backup_page.dart';
import 'full_system_backup_panel.dart';
import 'item_list_page.dart';
import 'trash_page.dart';

/// V4.2.2（+35）：数据管理页签（PM 拍板边界）。
///
/// 把抽屉里「数据备份与恢复」单页收拢升级为数据管理页签，承载
/// 备份/恢复/导出/清理四类数据操作。分块口径（PM 2026-11-28 拍板）：
///
/// 1. **全系统备份（推荐）**——+34 的全系统区原样搬入
///    （[FullSystemBackupPanel]，行为一字不改：导出/恢复一份 JSON、
///    逐域分行提示、误装互拒指路、校验前置不半截落库）；
/// 2. **分区备份**——原 BackupPage 分区主体（[BackupPageBody]
///    fullSystem=null 形态）原样搬入，老单域备份文件兼容；
/// 3. **导出 Excel**——只做入口跳转（物品明细页底部导出按钮），
///    **不重写取数逻辑**（物品明细+回收站双表+废弃流水链路原样）；
/// 4. **回收站与清理**——只做入口跳转（[TrashPage]），
///    恢复/彻底删除/全部清空逻辑原样。
///
/// 红线（PM 拍板）：不建知识域表、不改备份 JSON 格式、
/// 不新增 SharedPreferences 落盘、不虚增范围。
class DataManagementPage extends StatefulWidget {
  const DataManagementPage({
    super.key,
    required this.repository,
    this.gateway,
    this.domain = InventoryDomain.life,
    this.onRestored,
    this.fullSystem,
  });

  final InventoryRepository repository;

  /// 当前域：分区备份/恢复的对象、Excel 导出入口指向的明细页归属。
  final InventoryDomain domain;

  /// 备份交互网关；生产默认系统实现，测试注入假网关。
  final BackupGateway? gateway;

  /// 恢复成功后的回调（V4.1.7 铁律：恢复=清空重灌，首页必须刷新）。
  final Future<void> Function()? onRestored;

  /// V4.2.1（+34）：全系统备份服务；null = 全系统页签显示提示
  /// （单测注入单域仓储时的行为，与 BackupPage 同口径）。
  final FullSystemBackup? fullSystem;

  @override
  State<DataManagementPage> createState() => _DataManagementPageState();
}

class _DataManagementPageState extends State<DataManagementPage>
    with TickerProviderStateMixin {
  late final TabController _tab = TabController(length: 4, vsync: this);

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _openItemList() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ItemListPage(
          repository: widget.repository,
          domain: widget.domain,
          gateway: widget.gateway,
        ),
      ),
    );
    // 导出不改库，返回无需刷新。
  }

  Future<void> _openTrash() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => TrashPage(repository: widget.repository),
      ),
    );
    // 回收站内恢复/彻底删除/全部清空都会改库——返回数据管理页签
    // 本身无列表态，兜底刷新由首页（抽屉入口 push 后 await）负责，
    // 这里不重复实现（与 ItemListPage._openTrash 同款思路）。
  }

  @override
  Widget build(BuildContext context) {
    final fullSystem = widget.fullSystem;
    return Scaffold(
      appBar: AppBar(
        title: const Text('数据管理'),
        bottom: TabBar(
          controller: _tab,
          isScrollable: true,
          tabs: const <Tab>[
            Tab(text: '全系统备份'),
            Tab(text: '分区备份'),
            Tab(text: '导出 Excel'),
            Tab(text: '回收站与清理'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: <Widget>[
          // ---- 签①：全系统备份（推荐）——+34 区块原样搬入 ----
          if (fullSystem != null)
            SingleChildScrollView(
              key: const Key('data_mgmt_tab_full_system'),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const Text('全系统备份（推荐）',
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text(
                    '把生活区和工作区两本账打包成一份 JSON 文件，'
                    '一次导出、一次恢复，迁移不用来回切区域。',
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  FullSystemBackupPanel(
                    service: fullSystem,
                    gateway: widget.gateway,
                    onRestored: widget.onRestored,
                  ),
                ],
              ),
            )
          else
            Center(
              key: const Key('data_mgmt_tab_full_system'),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '当前未提供全系统备份（需生活区+工作区双域一起启用）。\n'
                  '分区备份请切到「分区备份」页签。',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
              ),
            ),
          // ---- 签②：分区备份——原 BackupPage 分区主体原样搬入 ----
          BackupPageBody(
            key: const Key('data_mgmt_tab_domain_backup'),
            repository: widget.repository,
            gateway: widget.gateway,
            domain: widget.domain,
            onRestored: widget.onRestored,
            // 分区页签只承载分区备份；全系统在签①（原页签结构拆分）。
            fullSystem: null,
          ),
          // ---- 签③：导出 Excel——入口跳转，不重写逻辑 ----
          SingleChildScrollView(
            key: const Key('data_mgmt_tab_excel'),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const Text('导出 Excel',
                    style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text(
                  '导出物品明细 + 回收站双表 Excel（含废弃流水与借出明细）。'
                  '点击下方按钮打开物品明细页，用底部「导出Excel」按钮'
                  '保存到手机；长按导出按钮可分享给好友。',
                  style: TextStyle(fontSize: 13, color: Colors.grey),
                ),
                const SizedBox(height: 16),
                FilledButton.tonalIcon(
                  key: const Key('data_mgmt_open_items'),
                  onPressed: _openItemList,
                  icon: const Icon(Icons.list_alt),
                  label: const Text('打开物品明细页导出'),
                ),
              ],
            ),
          ),
          // ---- 签④：回收站与清理——入口跳转，不重写逻辑 ----
          SingleChildScrollView(
            key: const Key('data_mgmt_tab_trash'),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const Text('回收站与清理',
                    style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text(
                  '删除的物品与借出记录都在回收站留底，可恢复或彻底删除；'
                  '「全部清空」会物理清除回收站全部条目（二次确认，不可恢复）。',
                  style: TextStyle(fontSize: 13, color: Colors.grey),
                ),
                const SizedBox(height: 16),
                FilledButton.tonalIcon(
                  key: const Key('data_mgmt_open_trash'),
                  onPressed: _openTrash,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('打开回收站'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

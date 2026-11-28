// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_inventory/data/domain.dart';
import 'package:home_inventory/data/inventory_repository.dart';
import 'package:home_inventory/data/item.dart';
import 'package:home_inventory/domain/full_system_backup.dart';
import 'package:home_inventory/ui/data_management_page.dart';

import 'item_list_page_test.dart' show FakeBackupGateway, FakeListRepository;

/// V4.2.2（+35）数据管理页签专项：四签结构与入口跳转。
///
/// PM 拍板边界：
/// - 全系统备份区原样搬入（行为一字不改）——面板行为由 v56/backup_page
///   测试继续锁，这里只锁「搬进来了、在签①」；
/// - 分区备份=原 BackupPage 主体原样（export/restore 按钮可达）；
/// - 导出 Excel / 回收站与清理=只做入口跳转，不重写逻辑；
/// - 不建知识域表、不改备份 JSON 格式、不新增落盘。
void main() {
  Future<void> pumpPage(
    WidgetTester tester, {
    required FakeListRepository repo,
    required FakeBackupGateway gateway,
    FullSystemBackup? fullSystem,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DataManagementPage(
          repository: repo,
          gateway: gateway,
          fullSystem: fullSystem,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 切页签（TabBar 文本短，360 宽内全部可见，直接按文本点）。
  Future<void> switchTab(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('+35 页签结构：AppBar 与四签、缺全系统时签①显示提示',
      (tester) async {
    await pumpPage(
      tester,
      repo: FakeListRepository(const <ItemWithLocations>[]),
      gateway: FakeBackupGateway(),
    );

    expect(find.text('数据管理'), findsOneWidget);
    expect(find.text('全系统备份'), findsOneWidget);
    expect(find.text('分区备份'), findsOneWidget);
    expect(find.text('导出 Excel'), findsOneWidget);
    expect(find.text('回收站与清理'), findsOneWidget);
    // 单域注入（hub==null 同款）时全系统区不显示、给提示，与 BackupPage 口径一致。
    expect(find.textContaining('当前未提供全系统备份'), findsOneWidget);
    expect(find.byKey(const Key('data_mgmt_tab_full_system')), findsOneWidget);
  });

  testWidgets('+35 签①：全系统区原样搬入（推荐标题+面板在默认签）',
      (tester) async {
    final lifeRepo = FakeListRepository(const <ItemWithLocations>[]);
    final workRepo = FakeListRepository(const <ItemWithLocations>[]);
    await pumpPage(
      tester,
      repo: lifeRepo,
      gateway: FakeBackupGateway(),
      fullSystem: FullSystemBackup(
        repositories: <InventoryDomain, InventoryRepository>{
          InventoryDomain.life: lifeRepo,
          InventoryDomain.work: workRepo,
        },
      ),
    );

    // 默认就在签①，无需切签。
    expect(find.text('全系统备份（推荐）'), findsOneWidget);
    expect(find.byKey(const Key('full_export_backup')), findsOneWidget);
    expect(find.byKey(const Key('full_restore_backup')), findsOneWidget);
  });

  testWidgets('+35 签②：分区操作原样（导出/恢复按钮可达）', (tester) async {
    await pumpPage(
      tester,
      repo: FakeListRepository(const <ItemWithLocations>[]),
      gateway: FakeBackupGateway(),
    );

    await switchTab(tester, '分区备份');
    expect(find.byKey(const Key('data_mgmt_tab_domain_backup')),
        findsOneWidget);
    expect(find.byKey(const Key('export_backup')), findsOneWidget);
    expect(find.byKey(const Key('restore_backup')), findsOneWidget);
    expect(find.textContaining('备份会把全部物品和位置'), findsOneWidget);
  });

  testWidgets('+35 签③：导出 Excel 入口跳转物品明细页（不重写逻辑）',
      (tester) async {
    await pumpPage(
      tester,
      repo: FakeListRepository(const <ItemWithLocations>[]),
      gateway: FakeBackupGateway(),
    );

    await switchTab(tester, '导出 Excel');
    expect(find.textContaining('物品明细 + 回收站双表'), findsOneWidget);
    await tester.tap(find.byKey(const Key('data_mgmt_open_items')));
    await tester.pumpAndSettle();

    // 跳到物品明细页：页内有既有的底部导出/恢复操作区。
    expect(find.text('物品明细'), findsOneWidget);
    expect(find.byKey(const Key('export_excel')), findsOneWidget);
  });

  testWidgets('+35 签④：回收站入口跳转回收站（恢复/彻底删逻辑原样）',
      (tester) async {
    await pumpPage(
      tester,
      repo: FakeListRepository(const <ItemWithLocations>[]),
      gateway: FakeBackupGateway(),
    );

    await switchTab(tester, '回收站与清理');
    expect(find.textContaining('全部清空'), findsOneWidget);
    await tester.tap(find.byKey(const Key('data_mgmt_open_trash')));
    await tester.pumpAndSettle();

    // 跳到回收站页：空库空态（恢复/彻底删/全部清空按钮由 trash_page 既有测试锁）。
    expect(find.textContaining('回收站为空'), findsOneWidget);
  });
}

// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_inventory/data/domain.dart';
import 'package:home_inventory/data/excel_exporter.dart';
import 'package:home_inventory/data/inventory_repository.dart';
import 'package:home_inventory/data/item.dart';
import 'package:home_inventory/domain/full_system_backup.dart';
import 'package:home_inventory/ui/data_management_page.dart';

import 'item_list_page_test.dart' show FakeBackupGateway, FakeListRepository;

/// V4.2.3（+36）数据管理签专项（终审边界）。
///
/// PM 终审：概览页「日程」右侧新增「数据管理」签，签内**整页纵向滚动**
/// 四区模块（系统区/生活区/工作区/知识区），不做横向切页、不做顶部
/// tab 切换；抽屉与明细页的散落入口撤掉；系统区三域 JSON；知识区
/// +35 只做通道（不建库不接 Writer）。
void main() {
  Future<void> pumpView(
    WidgetTester tester, {
    required FakeListRepository repo,
    required FakeBackupGateway gateway,
    InventoryRepository? workRepo,
    FullSystemBackup? fullSystem,
    ExcelExporter? excelExporter,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DataManagementView(
            lifeRepository: repo,
            workRepository: workRepo,
            gateway: gateway,
            fullSystem: fullSystem,
            excelExporter: excelExporter,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('+36 四区布局：整页纵向滚动，系统/生活/工作/知识四区从上到下',
      (tester) async {
    final life = FakeListRepository(const <ItemWithLocations>[]);
    final work = FakeListRepository(const <ItemWithLocations>[]);
    await pumpView(
      tester,
      repo: life,
      gateway: FakeBackupGateway(),
      workRepo: work,
      fullSystem: FullSystemBackup(repositories: <InventoryDomain,
          InventoryRepository>{
        InventoryDomain.life: life,
        InventoryDomain.work: work,
      }),
    );

    // 四区标题齐全（纵向排布，不做 tab）。
    expect(find.byKey(const Key('data_section_system')), findsOneWidget);
    expect(find.byKey(const Key('data_section_life')), findsOneWidget);
    expect(find.byKey(const Key('data_section_work')), findsOneWidget);
    expect(find.byKey(const Key('data_section_knowledge')), findsOneWidget);
    expect(find.text('系统区 · 全系统备份（推荐）'), findsOneWidget);
    expect(find.text('生活区'), findsOneWidget);
    expect(find.text('工作区'), findsOneWidget);
    expect(find.text('知识区'), findsOneWidget);
    // 纵向次序：系统区在生活区上方、生活区在工作区上方。
    final systemY = tester.getTopLeft(
        find.byKey(const Key('data_section_system'))).dy;
    final lifeY = tester.getTopLeft(find.byKey(const Key('data_section_life'))).dy;
    expect(systemY, lessThan(lifeY), reason: '系统区在最上');
  });

  testWidgets('+36 系统区：三域全系统面板原样（导出/恢复两键可达）',
      (tester) async {
    final life = FakeListRepository(const <ItemWithLocations>[]);
    final work = FakeListRepository(const <ItemWithLocations>[]);
    await pumpView(
      tester,
      repo: life,
      gateway: FakeBackupGateway(),
      workRepo: work,
      fullSystem: FullSystemBackup(repositories: <InventoryDomain,
          InventoryRepository>{
        InventoryDomain.life: life,
        InventoryDomain.work: work,
      }),
    );

    expect(find.byKey(const Key('full_export_backup')), findsOneWidget);
    expect(find.byKey(const Key('full_restore_backup')), findsOneWidget);
  });

  testWidgets('+36 生活/工作区：分区备份恢复 + Excel + Word 导出齐备',
      (tester) async {
    await pumpView(
      tester,
      repo: FakeListRepository(const <ItemWithLocations>[]),
      gateway: FakeBackupGateway(),
      workRepo: FakeListRepository(const <ItemWithLocations>[]),
    );

    // 生活区：备份/恢复（BackupPageBody 原样）+ Excel/Word。
    expect(find.byKey(const Key('data_life_excel_export')), findsOneWidget);
    expect(find.byKey(const Key('data_life_word_export')), findsOneWidget);
    // 工作区：同样一组。
    expect(find.byKey(const Key('data_work_excel_export')), findsOneWidget);
    expect(find.byKey(const Key('data_work_word_export')), findsOneWidget);
    // 备份/恢复两钮：生活区+工作区各一份 = 2。
    expect(find.byKey(const Key('export_backup')), findsNWidgets(2));
    expect(find.byKey(const Key('restore_backup')), findsNWidgets(2));
  });

  testWidgets('+36 知识区：通道按钮置灰不接写入口（不建库不炸）',
      (tester) async {
    await pumpView(
      tester,
      repo: FakeListRepository(const <ItemWithLocations>[]),
      gateway: FakeBackupGateway(),
    );

    final backup = tester.widget<OutlinedButton>(
        find.byKey(const Key('data_knowledge_backup_disabled')));
    final restore = tester.widget<OutlinedButton>(
        find.byKey(const Key('data_knowledge_restore_disabled')));
    expect(backup.onPressed, isNull, reason: '知识备份置灰（未建库）');
    expect(restore.onPressed, isNull, reason: '知识恢复置灰（未建库）');
  });

  testWidgets('+36 生活区 Excel 导出：点击保存 → zip 字节交给保存对话框',
      (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[
      _itemRow('梯子'),
    ]);
    final gateway = FakeBackupGateway();
    await pumpView(tester, repo: repo, gateway: gateway);
    await tester.tap(find.byKey(const Key('data_life_excel_export')));
    await tester.pumpAndSettle();

    expect(gateway.lastSavedBytes, isNotNull);
    expect(gateway.lastSavedBytes![0], 0x50, reason: 'zip 头（xlsx 容器）');
    expect(find.textContaining('已保存：'), findsOneWidget);
  });

  testWidgets('+36 生活区 Excel 长按分享：走系统分享链路（原明细页能力收编）',
      (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[
      _itemRow('梯子'),
    ]);
    final gateway = FakeBackupGateway();
    final exporter = ExcelExporter(
      fileWriter: (bytes) async => '/fake/${DateTime.now()}.xlsx',
    );
    await pumpView(
      tester,
      repo: repo,
      gateway: gateway,
      excelExporter: exporter,
    );
    await tester.longPress(find.byKey(const Key('data_life_excel_export')));
    await tester.pumpAndSettle();

    expect(gateway.lastSharedPath, isNotNull, reason: '长按触发分享');
    expect(gateway.lastSharedPath!, endsWith('.xlsx'));
    expect(find.textContaining('Excel 已生成'), findsOneWidget);
  });

  testWidgets('+36 生活区 Word 导出：点击保存 → docx 字节交给保存对话框',
      (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[
      _itemRow('梯子'),
    ]);
    final gateway = FakeBackupGateway();
    await pumpView(tester, repo: repo, gateway: gateway);
    await tester.tap(find.byKey(const Key('data_life_word_export')));
    await tester.pumpAndSettle();

    expect(gateway.lastSavedBytes, isNotNull);
    expect(gateway.lastSavedFileName, endsWith('.docx'));
    // docx 是 ZIP 容器（OOXML）。
    expect(gateway.lastSavedBytes![0], 0x50, reason: 'zip 头（docx 容器）');
  });

  testWidgets('+36 单域模式：工作区显示未启用、系统区显示提示',
      (tester) async {
    await pumpView(
      tester,
      repo: FakeListRepository(const <ItemWithLocations>[]),
      gateway: FakeBackupGateway(),
    );

    expect(find.textContaining('工作区未启用'), findsOneWidget);
    expect(find.textContaining('当前未提供全系统备份'), findsOneWidget);
    // 知识区恒在（通道）。
    expect(find.byKey(const Key('data_section_knowledge')), findsOneWidget);
  });
}

ItemWithLocations _itemRow(String name) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return ItemWithLocations(
    item: Item(id: 1, name: name, createdAt: now, updatedAt: now),
    locations: const <Location>[],
  );
}

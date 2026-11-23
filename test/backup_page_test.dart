// ignore_for_file: deprecated_member_use
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_inventory/data/inventory_repository.dart';
import 'package:home_inventory/data/item.dart';
import 'package:home_inventory/ui/backup_page.dart';

import 'item_list_page_test.dart' show FakeBackupGateway, FakeListRepository;

import 'fake_loan_mixin.dart';

/// 备份页测试：独立入口承载导出/恢复（逻辑同 BackupActions，走真流程）。
void main() {
  Future<void> pumpPage(
    WidgetTester tester, {
    required InventoryRepository repo,
    required FakeBackupGateway gateway,
  }) async {
    await tester.pumpWidget(
      MaterialApp(home: BackupPage(repository: repo, gateway: gateway)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('渲染：标题、说明与两个全宽操作按钮（纵排）', (tester) async {
    await pumpPage(
      tester,
      repo: FakeListRepository(const <ItemWithLocations>[]),
      gateway: FakeBackupGateway(),
    );

    expect(find.text('数据备份与恢复'), findsOneWidget);
    expect(find.textContaining('备份会把全部物品和位置'), findsOneWidget);
    expect(find.byKey(const Key('export_backup')), findsOneWidget);
    expect(find.byKey(const Key('restore_backup')), findsOneWidget);
    // 抽屉入口独立成页，操作按钮在主体，不在 AppBar。
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byKey(const Key('export_backup')),
      ),
      findsNothing,
    );
  });

  testWidgets('V3.6.1 导出备份：点击→保存到手机→提示已保存', (tester) async {
    final repo = FakeListRepository(const <ItemWithLocations>[]);
    final gateway = FakeBackupGateway();
    await pumpPage(tester, repo: repo, gateway: gateway);

    await tester.tap(find.byKey(const Key('export_backup')));
    await tester.pumpAndSettle();

    expect(repo.exportCalls, 1);
    expect(gateway.lastSavedBytes, isNotNull);
    expect(jsonDecode(utf8.decode(gateway.lastSavedBytes!)),
        isA<Map<String, Object?>>());
    expect(find.textContaining('已保存：'), findsOneWidget);
  });

  testWidgets('V3.6.1 长按导出备份：分享给好友（保留原分享链路）', (tester) async {
    final repo = FakeListRepository(const <ItemWithLocations>[]);
    final gateway = FakeBackupGateway();
    await pumpPage(tester, repo: repo, gateway: gateway);

    await tester.longPress(find.byKey(const Key('export_backup')));
    await tester.pumpAndSettle();

    expect(repo.exportCalls, 1);
    expect(gateway.lastSharedPath, isNotNull);
    expect(find.textContaining('备份已生成'), findsOneWidget);
  });

  testWidgets('V3.6.1 跨版本恢复：V3.6 旧结构备份（schemaVersion=5）能成功恢复',
      (tester) async {
    final repo = FakeListRepository(const <ItemWithLocations>[]);
    final gateway = FakeBackupGateway();
    // V3.6 及更早导出的备份结构：schemaVersion=5，无 deleted_at 字段。
    // 新版（库版本 6）恢复时不得因缺字段/版本旧而失败。
    gateway.registerFile(jsonEncode(<String, Object?>{
      'app': 'home_inventory',
      'schemaVersion': 5,
      'exportedAt': 1700000000000,
      'items': <Object?>[],
      'locations': <Object?>[],
      'item_locations': <Object?>[],
    }));
    await pumpPage(tester, repo: repo, gateway: gateway);

    await tester.tap(find.byKey(const Key('restore_backup')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('restore_confirm')));
    await tester.pumpAndSettle();

    expect(repo.restoreCalls, 1);
    expect(find.textContaining('恢复完成'), findsOneWidget);
    expect(find.textContaining('恢复失败'), findsNothing);
  });

  testWidgets('恢复备份：确认 → 选文件 → 调仓储 → 提示完成', (tester) async {
    final repo = FakeListRepository(const <ItemWithLocations>[]);
    final gateway = FakeBackupGateway();
    gateway.registerFile(jsonEncode(<String, Object?>{
      'app': 'home_inventory',
      'schemaVersion': 5,
      'items': <Object?>[],
      'locations': <Object?>[],
      'item_locations': <Object?>[],
    }));
    await pumpPage(tester, repo: repo, gateway: gateway);

    await tester.tap(find.byKey(const Key('restore_backup')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('restore_confirm')));
    await tester.pumpAndSettle();

    expect(repo.restoreCalls, 1);
    expect(find.textContaining('恢复完成'), findsOneWidget);
  });

  testWidgets('恢复校验拒绝：仓储抛 ArgumentError 时提示失败且不炸页', (tester) async {
    final repo = ThrowingRepo();
    final gateway = FakeBackupGateway();
    gateway.registerFile(jsonEncode(<String, Object?>{'app': '别的应用'}));
    await pumpPage(tester, repo: repo, gateway: gateway);

    await tester.tap(find.byKey(const Key('restore_backup')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('restore_confirm')));
    await tester.pumpAndSettle();

    expect(find.textContaining('恢复失败'), findsOneWidget);
    expect(find.byKey(const Key('restore_backup')), findsOneWidget,
        reason: '页面仍在，未崩溃');
  });
}

/// 校验拒绝模拟：restoreBackup 抛 ArgumentError（与生产仓储校验一致）。
class ThrowingRepo with FakeLoanMixin implements InventoryRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} 未在本测试使用');

  @override
  Future<void> restoreBackup(Map<String, Object?> data) async {
    throw ArgumentError('不是本应用备份');
  }
}

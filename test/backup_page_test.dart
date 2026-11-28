// ignore_for_file: deprecated_member_use
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_inventory/data/domain.dart';
import 'package:home_inventory/data/inventory_repository.dart';
import 'package:home_inventory/data/item.dart';
import 'package:home_inventory/domain/full_system_backup.dart';
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

  // ── V54（V4.1.7 演练打回）：恢复提示带行数、缺表点名、onRestored 必达 ──

  testWidgets('V54 恢复完成提示带行数明细（核对清单直接有数字可对）', (tester) async {
    final repo = FakeListRepository(const <ItemWithLocations>[]);
    final gateway = FakeBackupGateway();
    gateway.registerFile(jsonEncode(<String, Object?>{
      'app': 'home_inventory',
      'domain': 'work',
      'schemaVersion': 13,
      'items': <Object?>[<String, Object?>{}, <String, Object?>{}],
      'locations': <Object?>[<String, Object?>{}],
      'item_locations': <Object?>[],
      'borrowers': <Object?>[],
      'loans': <Object?>[<String, Object?>{}],
      'item_discards': <Object?>[],
      'reminders': <Object?>[
        <String, Object?>{},
        <String, Object?>{},
        <String, Object?>{},
      ],
      'daily_reports': <Object?>[],
      'todo_states': <Object?>[<String, Object?>{}],
    }));
    await pumpPage(tester, repo: repo, gateway: gateway);

    await tester.tap(find.byKey(const Key('restore_backup')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('restore_confirm')));
    await tester.pumpAndSettle();

    expect(find.textContaining('物品 2 条'), findsOneWidget);
    expect(find.textContaining('日程 3 条'), findsOneWidget);
    expect(find.textContaining('催办状态 1 条'), findsOneWidget);
    // 全表齐 → 不出「缺表」提醒。
    expect(find.textContaining('导出较早'), findsNothing);
  });

  testWidgets('V54 老备份缺表：恢复成功但明确点名缺什么（不许静默）', (tester) async {
    final repo = FakeListRepository(const <ItemWithLocations>[]);
    final gateway = FakeBackupGateway();
    // 低版本结构：没有 reminders / daily_reports / todo_states 键。
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
    expect(find.textContaining('导出较早'), findsOneWidget);
    expect(find.textContaining('日程'), findsOneWidget);
    expect(find.textContaining('催办状态'), findsOneWidget);
    expect(find.textContaining('无法从这份备份找回'), findsOneWidget);
  });

  testWidgets('V54 恢复成功必调 onRestored（首页刷新链路的关键一跳）', (tester) async {
    final repo = FakeListRepository(const <ItemWithLocations>[]);
    final gateway = FakeBackupGateway();
    gateway.registerFile(jsonEncode(<String, Object?>{
      'app': 'home_inventory',
      'domain': 'work',
      'schemaVersion': 13,
      'items': <Object?>[],
      'locations': <Object?>[],
      'item_locations': <Object?>[],
      'reminders': <Object?>[],
      'todo_states': <Object?>[],
    }));
    var restored = 0;
    await tester.pumpWidget(MaterialApp(
      home: BackupPage(
        repository: repo,
        gateway: gateway,
        onRestored: () async => restored++,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('restore_backup')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('restore_confirm')));
    await tester.pumpAndSettle();

    expect(restored, 1, reason: '恢复成功必须通知调用方刷新（首页内存态全陈旧）');
  });

  // ══════════ V4.2.1（+34）全系统备份 ══════════

  testWidgets('V56 渲染：传 fullSystem 时显示全系统区（导出/恢复两键）', (tester) async {
    final repo = FakeListRepository(const <ItemWithLocations>[]),
        lifeRepo = FakeListRepository(const <ItemWithLocations>[]),
        workRepo = FakeListRepository(const <ItemWithLocations>[]);
    final gateway = FakeBackupGateway();
    await tester.pumpWidget(MaterialApp(
      home: BackupPage(
        repository: repo,
        gateway: gateway,
        fullSystem: FullSystemBackup(
          repositories: <InventoryDomain, InventoryRepository>{
            InventoryDomain.life: lifeRepo,
            InventoryDomain.work: workRepo,
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('全系统备份（推荐）'), findsOneWidget);
    expect(find.byKey(const Key('full_export_backup')), findsOneWidget);
    expect(find.byKey(const Key('full_restore_backup')), findsOneWidget);
    // 分区备份原样保留（旧单域备份文件仍从分区入口恢复）。
    expect(find.byKey(const Key('export_backup')), findsOneWidget);
    expect(find.byKey(const Key('restore_backup')), findsOneWidget);
  });

  testWidgets('V56 全系统导出：两域 exportBackup 各调一次，合成一份 kind=full_system',
      (tester) async {
    final repo = FakeListRepository(const <ItemWithLocations>[]),
        lifeRepo = FakeListRepository(const <ItemWithLocations>[]),
        workRepo = FakeListRepository(const <ItemWithLocations>[]);
    final gateway = FakeBackupGateway();
    await tester.pumpWidget(MaterialApp(
      home: BackupPage(
        repository: repo,
        gateway: gateway,
        fullSystem: FullSystemBackup(
          repositories: <InventoryDomain, InventoryRepository>{
            InventoryDomain.life: lifeRepo,
            InventoryDomain.work: workRepo,
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('full_export_backup')));
    await tester.pumpAndSettle();

    expect(lifeRepo.exportCalls, 1, reason: '生活区导出一次');
    expect(workRepo.exportCalls, 1, reason: '工作区导出一次');
    final written = jsonDecode(utf8.decode(gateway.lastSavedBytes!))
        as Map<String, Object?>;
    expect(written['kind'], 'full_system');
    expect((written['domains']! as Map<String, Object?>).keys.toSet(),
        <String>{'life', 'work'});
    expect(find.textContaining('含生活区+工作区'), findsOneWidget);
  });

  testWidgets('V56 全系统恢复：合法文件 → 两域各恢复一次 + 行数提示 + onRestored',
      (tester) async {
    final repo = FakeListRepository(const <ItemWithLocations>[]),
        lifeRepo = FakeListRepository(const <ItemWithLocations>[]),
        workRepo = FakeListRepository(const <ItemWithLocations>[]);
    final gateway = FakeBackupGateway();
    gateway.registerFile(jsonEncode(<String, Object?>{
      'app': 'home_inventory',
      'kind': 'full_system',
      'formatVersion': 1,
      'domains': <String, Object?>{
        'life': <String, Object?>{
          'app': 'home_inventory',
          'domain': 'life',
          'schemaVersion': 13,
          'items': <Object?>[
            <String, Object?>{'id': 1, 'name': '梯子', 'quantity': 4},
          ],
          'locations': <Object?>[],
          'item_locations': <Object?>[],
        },
        'work': <String, Object?>{
          'app': 'home_inventory',
          'domain': 'work',
          'schemaVersion': 13,
          'items': <Object?>[],
          'locations': <Object?>[],
          'item_locations': <Object?>[],
        },
      },
    }));
    var restored = 0;
    await tester.pumpWidget(MaterialApp(
      home: BackupPage(
        repository: repo,
        gateway: gateway,
        fullSystem: FullSystemBackup(
          repositories: <InventoryDomain, InventoryRepository>{
            InventoryDomain.life: lifeRepo,
            InventoryDomain.work: workRepo,
          },
        ),
        onRestored: () async => restored++,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('full_restore_backup')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('full_restore_confirm')));
    await tester.pumpAndSettle();

    expect(lifeRepo.restoreCalls, 1, reason: '生活区恢复一次');
    expect(workRepo.restoreCalls, 1, reason: '工作区恢复一次');
    expect(lifeRepo.lastRestored?['domain'], 'life',
        reason: '恢复内容按域分发，不许串库');
    expect(workRepo.lastRestored?['domain'], 'work');
    expect(restored, 1, reason: '全系统恢复成功同样必须触发首页刷新');
    expect(find.textContaining('生活区：物品 1 条'), findsOneWidget,
        reason: '行数提示逐域分行（页面说明文案不含冒号，不会误匹配）');
  });

  testWidgets('V56 全系统恢复：单域文件误入 → 明确报错不落库', (tester) async {
    final repo = FakeListRepository(const <ItemWithLocations>[]),
        lifeRepo = FakeListRepository(const <ItemWithLocations>[]),
        workRepo = FakeListRepository(const <ItemWithLocations>[]);
    final gateway = FakeBackupGateway();
    gateway.registerFile(jsonEncode(<String, Object?>{
      'app': 'home_inventory',
      'domain': 'life',
      'schemaVersion': 13,
      'items': <Object?>[],
      'locations': <Object?>[],
      'item_locations': <Object?>[],
    }));
    await tester.pumpWidget(MaterialApp(
      home: BackupPage(
        repository: repo,
        gateway: gateway,
        fullSystem: FullSystemBackup(
          repositories: <InventoryDomain, InventoryRepository>{
            InventoryDomain.life: lifeRepo,
            InventoryDomain.work: workRepo,
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('full_restore_backup')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('full_restore_confirm')));
    await tester.pumpAndSettle();

    expect(lifeRepo.restoreCalls, 0, reason: '校验拒绝时不得落库');
    expect(workRepo.restoreCalls, 0);
    expect(find.textContaining('恢复失败'), findsOneWidget);
    expect(find.textContaining('请到对应区域的「数据管理 → 分区备份」页签恢复'),
        findsOneWidget, reason: '指路分区入口');
    expect(find.byKey(const Key('full_restore_backup')), findsOneWidget,
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

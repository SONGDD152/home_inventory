// ignore_for_file: deprecated_member_use
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_inventory/data/backup_gateway.dart';
import 'package:home_inventory/data/inventory_repository.dart';
import 'package:home_inventory/data/item.dart';
import 'package:home_inventory/ui/item_list_page.dart';

/// 内存假仓储：明细页只读，预置 ItemWithLocations 列表；
/// 导出/恢复只记录调用，供断言。
class FakeListRepository implements InventoryRepository {
  FakeListRepository(this.rows);

  final List<ItemWithLocations> rows;
  int restoreCalls = 0;
  Map<String, Object?>? lastRestored;
  int exportCalls = 0;
  int reloads = 0;

  @override
  Future<List<ItemWithLocations>> getAllItemsWithLocations() async {
    reloads++;
    return List<ItemWithLocations>.unmodifiable(rows);
  }

  @override
  Future<Map<String, Object?>> exportBackup() async {
    exportCalls++;
    return <String, Object?>{
      'app': 'home_inventory',
      'schemaVersion': 5,
      'items': <Object?>[],
      'locations': <Object?>[],
      'item_locations': <Object?>[],
    };
  }

  @override
  Future<void> restoreBackup(Map<String, Object?> data) async {
    restoreCalls++;
    lastRestored = data;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} 未在本测试使用');
}

/// 假备份网关：全内存实现（widget 测试假异步环境禁止真实文件 IO）。
class FakeBackupGateway implements BackupGateway {
  FakeBackupGateway();

  final Map<String, String> files = <String, String>{};
  int _nextId = 0;

  /// 预置一个"用户选中的备份文件"。
  String registerFile(String content) {
    final path = 'fake://backup_${_nextId++}.json';
    files[path] = content;
    _pickedPath = path;
    return path;
  }

  String? _pickedPath;
  String? lastWrittenJson;
  String? lastWrittenPath;
  String? lastSharedPath;

  @override
  Future<String> writeBackupFile(String json) async {
    lastWrittenJson = json;
    lastWrittenPath = 'fake://export_${_nextId++}.json';
    files[lastWrittenPath!] = json;
    return lastWrittenPath!;
  }

  @override
  Future<void> shareFile(String path) async {
    lastSharedPath = path;
  }

  @override
  Future<String?> pickBackupFile() async => _pickedPath;

  @override
  Future<String> readBackupFile(String path) async {
    final content = files[path];
    if (content == null) {
      throw StateError('假网关中没有文件：$path');
    }
    return content;
  }
}

ItemWithLocations _row(String name, List<String> locationNames) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return ItemWithLocations(
    item: Item(name: name, createdAt: now, updatedAt: now),
    locations: <Location>[
      for (final loc in locationNames)
        Location(name: loc, createdAt: now, updatedAt: now),
    ],
  );
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required FakeListRepository repo,
  required FakeBackupGateway gateway,
}) async {
  await tester.pumpWidget(
    MaterialApp(home: ItemListPage(repository: repo, gateway: gateway)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('渲染：物品名 + 位置拼接 + 数量统计', (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[
      _row('梯子', <String>['阳台', '车库']),
      _row('充电器', <String>['书房']),
    ]);
    final gateway = FakeBackupGateway();
    await _pumpPage(tester, repo: repo, gateway: gateway);

    expect(find.text('梯子'), findsOneWidget);
    expect(find.text('阳台、车库'), findsOneWidget);
    expect(find.text('充电器'), findsOneWidget);
    expect(find.byKey(const Key('detail_item_梯子')), findsOneWidget);
    expect(find.text('共 2 件物品 · 3 条存放记录'), findsOneWidget);
    expect(find.byKey(const Key('detail_list')), findsOneWidget);
  });

  testWidgets('搜索：按物品名片段过滤', (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[
      _row('梯子', <String>['阳台']),
      _row('充电器', <String>['书房']),
    ]);
    await _pumpPage(
      tester,
      repo: repo,
      gateway: FakeBackupGateway(),
    );

    await tester.enterText(find.byKey(const Key('detail_search')), '梯');
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('detail_item_梯子')), findsOneWidget);
    expect(find.byKey(const Key('detail_item_充电器')), findsNothing);
    expect(find.text('共 1 件物品 · 1 条存放记录'), findsOneWidget);
  });

  testWidgets('搜索：按位置名过滤（梯子→车库 命中）', (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[
      _row('梯子', <String>['车库']),
      _row('充电器', <String>['书房']),
    ]);
    await _pumpPage(tester, repo: repo, gateway: FakeBackupGateway());

    await tester.enterText(find.byKey(const Key('detail_search')), '车库');
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('detail_item_梯子')), findsOneWidget);
    expect(find.byKey(const Key('detail_item_充电器')), findsNothing);
  });

  testWidgets('空库空态文案', (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[]);
    await _pumpPage(tester, repo: repo, gateway: FakeBackupGateway());

    expect(find.byKey(const Key('detail_empty')), findsOneWidget);
    expect(find.textContaining('还没有记录'), findsOneWidget);
  });

  testWidgets('搜索无匹配文案', (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[
      _row('梯子', <String>['阳台']),
    ]);
    await _pumpPage(tester, repo: repo, gateway: FakeBackupGateway());

    await tester.enterText(find.byKey(const Key('detail_search')), '不存在的东西');
    await tester.pumpAndSettle();

    expect(find.textContaining('没有匹配的物品'), findsOneWidget);
  });

  testWidgets('导出备份：生成文件 → 唤起分享 → 提示文件名', (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[]);
    final gateway = FakeBackupGateway();
    await _pumpPage(tester, repo: repo, gateway: gateway);

    await tester.tap(find.byKey(const Key('export_backup')));
    await tester.pumpAndSettle();

    expect(repo.exportCalls, 1);
    expect(gateway.lastWrittenJson, isNotNull);
    expect(jsonDecode(gateway.lastWrittenJson!), isA<Map<String, Object?>>());
    expect(gateway.lastSharedPath, gateway.lastWrittenPath);
    expect(find.textContaining('备份已生成'), findsOneWidget);
  });

  testWidgets('恢复备份：确认 → 选文件 → 调仓储 → 提示完成 → 重载列表', (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[]);
    final gateway = FakeBackupGateway();

    // 预置一个合法备份文件作为"用户选中的文件"。
    gateway.registerFile(jsonEncode(<String, Object?>{
      'app': 'home_inventory',
      'schemaVersion': 5,
      'items': <Object?>[],
      'locations': <Object?>[],
      'item_locations': <Object?>[],
    }));

    await _pumpPage(tester, repo: repo, gateway: gateway);
    final reloadsBefore = repo.reloads;

    await tester.tap(find.byKey(const Key('restore_backup')));
    await tester.pumpAndSettle();
    // 确认对话框出现，先取消一回落空。
    expect(find.text('恢复备份'), findsOneWidget);
    await tester.tap(find.byKey(const Key('restore_cancel')));
    await tester.pumpAndSettle();
    expect(repo.restoreCalls, 0);

    await tester.tap(find.byKey(const Key('restore_backup')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('restore_confirm')));
    await tester.pumpAndSettle();

    expect(repo.restoreCalls, 1);
    expect((repo.lastRestored!)['app'], 'home_inventory');
    expect(find.textContaining('恢复完成'), findsOneWidget);
    expect(repo.reloads, reloadsBefore + 1, reason: '恢复后应重载列表');
  });

  testWidgets('恢复失败：坏 JSON 文件提示恢复失败且不炸页面', (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[]);
    final gateway = FakeBackupGateway();

    gateway.registerFile('不是json{{{');

    await _pumpPage(tester, repo: repo, gateway: gateway);

    await tester.tap(find.byKey(const Key('restore_backup')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('restore_confirm')));
    await tester.pumpAndSettle();

    expect(repo.restoreCalls, 0);
    expect(find.textContaining('恢复失败'), findsOneWidget);
    expect(find.byKey(const Key('detail_search')), findsOneWidget,
        reason: '页面仍在，未崩溃');
  });

  testWidgets('恢复取消选择文件：不调仓储', (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[]);
    final gateway = FakeBackupGateway(); // pickedPath = null → 用户取消
    await _pumpPage(tester, repo: repo, gateway: gateway);

    await tester.tap(find.byKey(const Key('restore_backup')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('restore_confirm')));
    await tester.pumpAndSettle();

    expect(repo.restoreCalls, 0);
  });
}

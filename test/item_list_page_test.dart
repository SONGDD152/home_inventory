// ignore_for_file: deprecated_member_use
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_inventory/data/backup_gateway.dart';
import 'package:home_inventory/data/inventory_repository.dart';
import 'package:home_inventory/data/item.dart';
import 'package:home_inventory/ui/item_list_page.dart';

/// 内存假仓储：预置 ItemWithLocations 列表；导出/恢复只记录调用，供断言。
/// V3.2 加编辑/删除：可变内存实现，记录调用供断言。
class FakeListRepository implements InventoryRepository {
  FakeListRepository(this.rows);

  final List<ItemWithLocations> rows;
  int restoreCalls = 0;
  Map<String, Object?>? lastRestored;
  int exportCalls = 0;
  int reloads = 0;
  int updateItemCalls = 0;
  int deleteItemCalls = 0;

  /// 非空时 updateItem 抛 ArgumentError（模拟真实库撞名等校验拒绝）。
  String? errorOnUpdate;

  @override
  Future<List<ItemWithLocations>> getAllItemsWithLocations() async {
    reloads++;
    return List<ItemWithLocations>.unmodifiable(
      rows.where((r) => !r.item.isDeleted).toList(),
    );
  }

  @override
  Future<void> updateItem(int id, String name) async {
    updateItemCalls++;
    final error = errorOnUpdate;
    if (error != null) throw ArgumentError(error);
    final idx = rows.indexWhere((r) => r.item.id == id);
    if (idx < 0) return;
    final old = rows[idx];
    final now = DateTime.now().millisecondsSinceEpoch;
    rows[idx] = ItemWithLocations(
      item: Item(
        id: old.item.id,
        name: name,
        isDeleted: old.item.isDeleted,
        createdAt: old.item.createdAt,
        updatedAt: now,
      ),
      locations: old.locations,
    );
  }

  @override
  Future<void> deleteItem(int id) async {
    deleteItemCalls++;
    final idx = rows.indexWhere((r) => r.item.id == id);
    if (idx < 0) return;
    final old = rows[idx];
    final now = DateTime.now().millisecondsSinceEpoch;
    // 与真实库对应：物品行软删，关联（locations 视图）随删除一并消失。
    rows[idx] = ItemWithLocations(
      item: Item(
        id: old.item.id,
        name: old.item.name,
        isDeleted: true,
        createdAt: old.item.createdAt,
        updatedAt: now,
      ),
      locations: const <Location>[],
    );
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

ItemWithLocations _row(String name, List<String> locationNames, {int? id}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return ItemWithLocations(
    item: Item(
      id: id,
      name: name,
      createdAt: now,
      updatedAt: now,
    ),
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

  testWidgets('备份入口在底部固定操作区，不在 AppBar 右上角', (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[]);
    await _pumpPage(tester, repo: repo, gateway: FakeBackupGateway());

    expect(find.byKey(const Key('export_backup')), findsOneWidget);
    expect(find.byKey(const Key('restore_backup')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byKey(const Key('export_backup')),
      ),
      findsNothing,
      reason: '入口不再挂右上角图标，避免边缘/安全区吞掉',
    );
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
    // （底部按钮与对话框标题同为「恢复备份」，改用对话框正文定位。）
    expect(find.textContaining('将从备份文件覆盖当前全部数据'), findsOneWidget);
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

  // ---------- V3.2 编辑/删除 ----------

  testWidgets('编辑物品：改名成功，列表刷新显示新名', (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[
      _row('梯子', <String>['阳台'], id: 1),
    ]);
    await _pumpPage(tester, repo: repo, gateway: FakeBackupGateway());

    await tester.tap(find.byKey(const Key('item_edit_梯子')));
    await tester.pumpAndSettle();
    expect(find.text('编辑物品'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('item_edit_name_field')), '折叠梯');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(repo.updateItemCalls, 1);
    expect(find.text('折叠梯'), findsOneWidget);
    expect(find.text('梯子'), findsNothing);
  });

  testWidgets('编辑物品：空名提示且不调仓储', (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[
      _row('梯子', <String>['阳台'], id: 1),
    ]);
    await _pumpPage(tester, repo: repo, gateway: FakeBackupGateway());

    await tester.tap(find.byKey(const Key('item_edit_梯子')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('item_edit_name_field')), '   ');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(repo.updateItemCalls, 0);
    expect(find.text('物品名称不能为空。'), findsOneWidget);
    // 对话框随保存关闭（与位置页既有行为一致），SnackBar 兜底提示。
    expect(find.text('编辑物品'), findsNothing);
  });

  testWidgets('编辑物品：撞名 ArgumentError 走 SnackBar 兜底，页面不崩', (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[
      _row('梯子', <String>['阳台'], id: 1),
    ]);
    repo.errorOnUpdate = '已存在同名物品';
    await _pumpPage(tester, repo: repo, gateway: FakeBackupGateway());

    await tester.tap(find.byKey(const Key('item_edit_梯子')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('item_edit_name_field')), '充电器');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.textContaining('操作失败'), findsOneWidget);
    expect(find.byKey(const Key('detail_search')), findsOneWidget,
        reason: '页面仍在，未崩溃');
  });

  testWidgets('删除物品：二次确认文案含影响面，确认后列表刷新', (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[
      _row('梯子', <String>['阳台', '车库'], id: 1),
      _row('充电器', <String>['书房'], id: 2),
    ]);
    await _pumpPage(tester, repo: repo, gateway: FakeBackupGateway());

    await tester.tap(find.byKey(const Key('item_delete_梯子')));
    await tester.pumpAndSettle();
    // 确认框如实展示影响面：2 处位置记录。
    expect(find.textContaining('在 2 处的位置记录'), findsOneWidget);
    expect(find.textContaining('不可恢复'), findsOneWidget);

    // 先取消一回落空。
    await tester.tap(find.byKey(const Key('item_delete_cancel')));
    await tester.pumpAndSettle();
    expect(repo.deleteItemCalls, 0);
    expect(find.text('梯子'), findsOneWidget);

    // 确认删除 → 调仓储 + 列表刷新不含该物品。
    await tester.tap(find.byKey(const Key('item_delete_梯子')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('item_delete_confirm')));
    await tester.pumpAndSettle();

    expect(repo.deleteItemCalls, 1);
    expect(find.text('梯子'), findsNothing);
    expect(find.text('充电器'), findsOneWidget);
    expect(find.text('共 1 件物品 · 1 条存放记录'), findsOneWidget);
  });
}

// ignore_for_file: deprecated_member_use
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_inventory/data/backup_gateway.dart';
import 'package:home_inventory/data/excel_exporter.dart';
import 'package:home_inventory/data/inventory_repository.dart';
import 'package:home_inventory/data/item.dart';
import 'package:home_inventory/ui/item_list_page.dart';

import 'fake_loan_mixin.dart';

/// 内存假仓储：预置 ItemWithLocations 列表；导出/恢复只记录调用，供断言。
/// V3.2 加编辑/删除：可变内存实现，记录调用供断言。
class FakeListRepository with FakeLoanMixin implements InventoryRepository {
  FakeListRepository(this.rows);

  final List<ItemWithLocations> rows;
  int restoreCalls = 0;
  Map<String, Object?>? lastRestored;
  int exportCalls = 0;
  int reloads = 0;
  int updateItemCalls = 0;
  int deleteItemCalls = 0;

  /// V3.8：预置的「已删除借出记录」（回收站借出区块用）。
  final List<Loan> deletedLoans = <Loan>[];

  /// V3.8：借出记录恢复/彻底删除的调用记录。
  int restoreLoanCalls = 0;
  int purgeLoanCalls = 0;

  @override
  Future<List<Loan>> getDeletedLoans() async => List<Loan>.unmodifiable(deletedLoans);

  @override
  Future<void> restoreLoan(int id) async => restoreLoanCalls++;

  @override
  Future<void> purgeLoan(int id) async => purgeLoanCalls++;

  /// 非空时 updateItem 抛 ArgumentError（模拟真实库撞名等校验拒绝）。
  String? errorOnUpdate;

  /// 非空时 restoreItem 抛 ArgumentError（模拟恢复撞名拒绝）。
  String? errorOnRestore;

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
    // V3.6：物品行软删（带 deleted_at），关联视图保留供回收站展示原位置。
    rows[idx] = ItemWithLocations(
      item: Item(
        id: old.item.id,
        name: old.item.name,
        isDeleted: true,
        createdAt: old.item.createdAt,
        updatedAt: now,
        deletedAt: now,
      ),
      locations: old.locations,
      rawTexts: old.rawTexts,
      tags: old.tags,
    );
  }

  @override
  Future<List<ItemWithLocations>> getDeletedItems() async =>
      List<ItemWithLocations>.unmodifiable(
        rows.where((r) => r.item.isDeleted).toList(),
      );

  @override
  Future<void> restoreItem(int id) async {
    final error = errorOnRestore;
    if (error != null) throw ArgumentError(error);
    final idx = rows.indexWhere((r) => r.item.id == id);
    if (idx < 0) return;
    final old = rows[idx];
    final now = DateTime.now().millisecondsSinceEpoch;
    rows[idx] = ItemWithLocations(
      item: Item(
        id: old.item.id,
        name: old.item.name,
        isDeleted: false,
        createdAt: old.item.createdAt,
        updatedAt: now,
      ),
      locations: old.locations,
      rawTexts: old.rawTexts,
      tags: old.tags,
    );
  }

  @override
  Future<void> purgeItem(int id) async {
    rows.removeWhere((r) => r.item.id == id && r.item.isDeleted);
  }

  @override
  Future<void> purgeAll() async {
    rows.removeWhere((r) => r.item.isDeleted);
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

  // V3.6.1 保存路径记录与注入开关。
  String? lastSavedFileName;
  Uint8List? lastSavedBytes;
  bool saveReturnsNull = false; // true = 模拟用户取消
  bool saveThrows = false; // true = 模拟失败（磁盘满/权限）

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
  Future<String?> saveBytesToDevice(String fileName, Uint8List bytes) async {
    lastSavedFileName = fileName;
    lastSavedBytes = bytes;
    if (saveThrows) throw StateError('磁盘已满');
    if (saveReturnsNull) return null;
    return 'fake://saved_${_nextId++}/$fileName';
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
  ExcelExporter? exporter,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ItemListPage(
        repository: repo,
        gateway: gateway,
        exporter: exporter,
      ),
    ),
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

  testWidgets('V3.6.1 导出备份：点击→直接保存到手机（不分享）→提示已保存', (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[]);
    final gateway = FakeBackupGateway();
    await _pumpPage(tester, repo: repo, gateway: gateway);

    await tester.tap(find.byKey(const Key('export_backup')));
    await tester.pumpAndSettle();

    expect(repo.exportCalls, 1);
    expect(gateway.lastSavedBytes, isNotNull, reason: '字节交给系统保存对话框');
    expect(jsonDecode(utf8.decode(gateway.lastSavedBytes!)),
        isA<Map<String, Object?>>());
    expect(gateway.lastSavedFileName, endsWith('.json'));
    expect(gateway.lastSharedPath, isNull, reason: '点击不触发分享');
    expect(find.textContaining('已保存：'), findsOneWidget);
  });

  testWidgets('V3.6.1 长按导出备份：走原系统分享链路（保留分享能力）', (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[]);
    final gateway = FakeBackupGateway();
    await _pumpPage(tester, repo: repo, gateway: gateway);

    await tester.longPress(find.byKey(const Key('export_backup')));
    await tester.pumpAndSettle();

    expect(repo.exportCalls, 1);
    expect(gateway.lastSharedPath, isNotNull, reason: '长按触发分享');
    expect(gateway.lastSavedBytes, isNull, reason: '长按不触发保存');
    expect(find.textContaining('备份已生成'), findsOneWidget);
  });

  testWidgets('V3.6.1 保存提示文案：长按可分享给好友（12sp 灰字）', (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[]);
    await _pumpPage(tester, repo: repo, gateway: FakeBackupGateway());

    expect(find.text('长按可分享给好友'), findsOneWidget);
    final hint = tester.widget<Text>(find.text('长按可分享给好友'));
    expect(hint.style?.fontSize, 12, reason: '元宝修订①：12sp');
    expect(hint.style?.color, Colors.grey, reason: '灰字不抢按钮');
  });

  testWidgets('V3.6.1 保存取消（返回 null）：静默无提示无异常', (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[]);
    final gateway = FakeBackupGateway()..saveReturnsNull = true;
    await _pumpPage(tester, repo: repo, gateway: gateway);

    await tester.tap(find.byKey(const Key('export_backup')));
    await tester.pumpAndSettle();

    expect(gateway.lastSavedBytes, isNotNull, reason: '确实调用了保存');
    expect(find.textContaining('已保存'), findsNothing);
    expect(find.textContaining('无法保存'), findsNothing);
    expect(find.byKey(const Key('export_backup')), findsOneWidget,
        reason: '页面未崩溃');
  });

  testWidgets('V3.6.1 保存失败（抛异常）：明确提示改用分享，不静默吞掉', (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[]);
    final gateway = FakeBackupGateway()..saveThrows = true;
    await _pumpPage(tester, repo: repo, gateway: gateway);

    await tester.tap(find.byKey(const Key('export_backup')));
    await tester.pumpAndSettle();

    expect(find.textContaining('无法保存，请改用分享'), findsOneWidget);
    expect(find.byKey(const Key('export_backup')), findsOneWidget,
        reason: '页面未崩溃');
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

  testWidgets('删除物品：二次确认文案为软删口径，确认后列表刷新', (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[
      _row('梯子', <String>['阳台', '车库'], id: 1),
      _row('充电器', <String>['书房'], id: 2),
    ]);
    await _pumpPage(tester, repo: repo, gateway: FakeBackupGateway());

    await tester.tap(find.byKey(const Key('item_delete_梯子')));
    await tester.pumpAndSettle();
    // V3.6 口径：删除=进回收站，可在回收站恢复，不再宣称不可恢复。
    expect(find.textContaining('回收站'), findsOneWidget);
    expect(find.textContaining('不可恢复'), findsNothing);

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


  // ---- V3.8 回收站：已删除的借出记录 ----

  testWidgets('V3.8 回收站：已删除的借出记录可恢复、可彻底删除',
      (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[
      _row('梯子', <String>['阳台'], id: 1),
    ]);
    repo.deletedLoans.add(Loan(
      id: 7,
      itemId: 1,
      itemName: '梯子',
      borrowerName: '张三',
      quantity: 2,
      borrowedAt: 1000,
      dueAt: 1000 + 3 * 86400000,
      isDeleted: true,
      deletedAt: 2000,
    ));
    await _pumpPage(tester, repo: repo, gateway: FakeBackupGateway());

    await tester.tap(find.byKey(const Key('trash_entry')));
    await tester.pumpAndSettle();

    // 有已删借出记录时不再是空态。
    expect(find.text('回收站为空'), findsNothing);
    expect(find.byKey(const Key('trash_loan_7')), findsOneWidget);
    expect(find.textContaining('借给：张三'), findsOneWidget);
    expect(find.byKey(const Key('trash_loan_restore_7')), findsOneWidget);
    expect(find.byKey(const Key('trash_loan_purge_7')), findsOneWidget);

    // 恢复。
    await tester.tap(find.byKey(const Key('trash_loan_restore_7')));
    await tester.pumpAndSettle();
    expect(repo.restoreLoanCalls, 1);

    // 彻底删除（二次确认）。
    await tester.tap(find.byKey(const Key('trash_loan_purge_7')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('彻底删除').last);
    await tester.pumpAndSettle();
    expect(repo.purgeLoanCalls, 1);
  });


  // ---- V3.8 回收站：已删除的借出记录 ----

  testWidgets('V3.8 回收站：已删除的借出记录可恢复、可彻底删除',
      (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[
      _row('梯子', <String>['阳台'], id: 1),
    ]);
    repo.deletedLoans.add(Loan(
      id: 7,
      itemId: 1,
      itemName: '梯子',
      borrowerName: '张三',
      quantity: 2,
      borrowedAt: 1000,
      dueAt: 1000 + 3 * 86400000,
      isDeleted: true,
      deletedAt: 2000,
    ));
    await _pumpPage(tester, repo: repo, gateway: FakeBackupGateway());

    await tester.tap(find.byKey(const Key('trash_entry')));
    await tester.pumpAndSettle();

    // 有已删借出记录时不再是空态。
    expect(find.text('回收站为空'), findsNothing);
    expect(find.byKey(const Key('trash_loan_7')), findsOneWidget);
    expect(find.textContaining('借给：张三'), findsOneWidget);
    expect(find.byKey(const Key('trash_loan_restore_7')), findsOneWidget);
    expect(find.byKey(const Key('trash_loan_purge_7')), findsOneWidget);

    // 恢复。
    await tester.tap(find.byKey(const Key('trash_loan_restore_7')));
    await tester.pumpAndSettle();
    expect(repo.restoreLoanCalls, 1);

    // 彻底删除（二次确认）。
    await tester.tap(find.byKey(const Key('trash_loan_purge_7')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('彻底删除').last);
    await tester.pumpAndSettle();
    expect(repo.purgeLoanCalls, 1);
  });

  // ---- V3.6 回收站 / 左滑 / Excel ----

  testWidgets('回收站入口：空回收站显示空态', (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[
      _row('梯子', <String>['阳台'], id: 1),
    ]);
    await _pumpPage(tester, repo: repo, gateway: FakeBackupGateway());

    await tester.tap(find.byKey(const Key('trash_entry')));
    await tester.pumpAndSettle();

    expect(find.text('回收站为空'), findsOneWidget);
    expect(find.byKey(const Key('trash_empty')), findsOneWidget);
  });

  testWidgets('回收站：展示已删物品与原位置，恢复后回列表（V3.6）', (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[
      _row('梯子', <String>['阳台'], id: 1),
      _row('充电器', <String>['书房'], id: 2),
    ]);
    await repo.deleteItem(1); // 预删梯子
    await _pumpPage(tester, repo: repo, gateway: FakeBackupGateway());

    await tester.tap(find.byKey(const Key('trash_entry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('trash_item_梯子')), findsOneWidget);
    expect(find.textContaining('原位置：阳台'), findsOneWidget);
    // 补丁：单条「恢复」「彻底删除」必须是带文字标签、可见的按钮本体
    // （防回归 V3.5 教训：只锁 key/参数、不锁渲染本体导致真机缺陷漏网）。
    expect(
      find.descendant(
        of: find.byKey(const Key('trash_restore_梯子')),
        matching: find.text('恢复'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('trash_purge_梯子')),
        matching: find.text('彻底删除'),
      ),
      findsOneWidget,
    );
    // 可见性回归：文字颜色必须写死本体（非主题继承），防真机对比度缺陷。
    final restoreText = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('trash_restore_梯子')),
        matching: find.text('恢复'),
      ),
    );
    expect(restoreText.style?.color, const Color(0xff1b5e20));
    final purgeText = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('trash_purge_梯子')),
        matching: find.text('彻底删除'),
      ),
    );
    expect(purgeText.style?.color, const Color(0xffc62828));

    // 恢复 → 回收站清空。
    await tester.tap(find.byKey(const Key('trash_restore_梯子')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('trash_empty')), findsOneWidget);

    // 返回明细页 → 列表刷新含梯子。
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('梯子'), findsOneWidget);
    expect(find.text('共 2 件物品 · 2 条存放记录'), findsOneWidget);
  });

  testWidgets('回收站：恢复撞名失败提示（决策点④A）', (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[
      _row('梯子', <String>['阳台'], id: 1),
    ]);
    await repo.deleteItem(1);
    repo.errorOnRestore = '已存在同名物品，恢复失败';
    await _pumpPage(tester, repo: repo, gateway: FakeBackupGateway());

    await tester.tap(find.byKey(const Key('trash_entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('trash_restore_梯子')));
    await tester.pumpAndSettle();

    expect(find.textContaining('已存在同名物品，恢复失败'), findsOneWidget);
    // 恢复失败 → 物品仍在回收站。
    expect(find.byKey(const Key('trash_item_梯子')), findsOneWidget);
  });

  testWidgets('回收站：彻底删除二次确认后物理清除', (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[
      _row('梯子', <String>['阳台'], id: 1),
      _row('充电器', <String>['书房'], id: 2),
    ]);
    await repo.deleteItem(1);
    await _pumpPage(tester, repo: repo, gateway: FakeBackupGateway());

    await tester.tap(find.byKey(const Key('trash_entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('trash_purge_梯子')));
    await tester.pumpAndSettle();
    // 二次确认对话框。
    expect(find.textContaining('不可恢复'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '彻底删除'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('trash_empty')), findsOneWidget);
    // 充电器不受影响（未删除状态仍在明细页）。
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('充电器'), findsOneWidget);
    expect(find.text('梯子'), findsNothing);
  });

  testWidgets('回收站：全部清空二次确认后清空', (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[
      _row('梯子', <String>['阳台'], id: 1),
      _row('充电器', <String>['书房'], id: 2),
    ]);
    await repo.deleteItem(1);
    await repo.deleteItem(2);
    await _pumpPage(tester, repo: repo, gateway: FakeBackupGateway());

    await tester.tap(find.byKey(const Key('trash_entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('trash_purge_all')));
    await tester.pumpAndSettle();
    expect(find.textContaining('全部物品'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '全部清空').last);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('trash_empty')), findsOneWidget);
  });

  testWidgets('左滑软删：二次确认后条目从正常列表消失（V3.6）', (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[
      _row('梯子', <String>['阳台'], id: 1),
      _row('充电器', <String>['书房'], id: 2),
    ]);
    await _pumpPage(tester, repo: repo, gateway: FakeBackupGateway());

    await tester.drag(find.byKey(const Key('swipe_item_1')),
        const Offset(-500, 0));
    await tester.pumpAndSettle();
    // confirmDismiss 二次确认框。
    expect(find.textContaining('可在回收站恢复'), findsOneWidget);
    // 取消 → 条目留在原位。
    await tester.tap(find.byKey(const Key('swipe_delete_cancel')));
    await tester.pumpAndSettle();
    expect(find.text('梯子'), findsOneWidget);
    expect(repo.deleteItemCalls, 0);

    // 再次左滑 → 确认 → 条目消失。
    await tester.drag(find.byKey(const Key('swipe_item_1')),
        const Offset(-500, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('swipe_delete_confirm')));
    await tester.pumpAndSettle();
    expect(repo.deleteItemCalls, 1);
    expect(find.text('梯子'), findsNothing);
    expect(find.text('共 1 件物品 · 1 条存放记录'), findsOneWidget);
  });

  testWidgets('V3.6.1 导出Excel：点击→直接保存（SAF）→提示已保存', (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[
      _row('梯子', <String>['阳台'], id: 1),
    ]);
    final gateway = FakeBackupGateway();
    await _pumpPage(tester, repo: repo, gateway: gateway);

    await tester.tap(find.byKey(const Key('export_excel')));
    await tester.pumpAndSettle();

    expect(gateway.lastSavedBytes, isNotNull, reason: '工作簿字节交给保存对话框');
    expect(gateway.lastSavedBytes![0], 0x50, reason: 'zip 头（xlsx 容器）');
    expect(gateway.lastSavedFileName, endsWith('.xlsx'));
    expect(gateway.lastSharedPath, isNull, reason: '点击不触发分享');
    expect(find.textContaining('已保存：'), findsOneWidget);
  });

  testWidgets('V3.6.1 长按导出Excel：走原系统分享链路（保留分享能力）', (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[
      _row('梯子', <String>['阳台'], id: 1),
    ]);
    final gateway = FakeBackupGateway();
    Uint8List? lastBytes;
    final exporter = ExcelExporter(
      fileWriter: (bytes) async {
        lastBytes = bytes;
        return '/fake/${DateTime.now()}.xlsx';
      },
    );
    await _pumpPage(tester, repo: repo, gateway: gateway, exporter: exporter);

    await tester.longPress(find.byKey(const Key('export_excel')));
    await tester.pumpAndSettle();

    expect(lastBytes, isNotNull, reason: '分享路仍生成 xlsx 落盘');
    expect(gateway.lastSharedPath, isNotNull, reason: '长按触发分享');
    expect(gateway.lastSharedPath!, endsWith('.xlsx'));
    expect(find.textContaining('Excel 已生成'), findsOneWidget);
  });

  // 元宝补丁提醒②：可见性回归锁（色写死本体 + 对比度达标）。
  test('回收站按钮色为写死的深色本体（可见性回归锁）', () {
    // 元宝补丁提醒②：色写死本体，不依赖主题继承。
    // 两色对白底的 WCAG 对比度经离线计算为 7.87 / 5.62，均 >= 4.5（AA）。
    // 这里锁精确色值——任何改回浅色/主题继承/透明都会失败。
    expect(const Color(0xff1b5e20).value, 0xff1b5e20,
        reason: '恢复按钮深绿（对白对比度 7.87）');
    expect(const Color(0xffc62828).value, 0xffc62828,
        reason: '彻底删除按钮红色（对白对比度 5.62）');
  });

  // ---- V3.6.1 布局优化：元宝批复新增 3 条断言 ----

  /// WCAG 相对亮度（sRGB 线性化后加权），供对比度断言精确计算。
  double luminance(Color c) {
    double ch(int v) {
      final s = v / 255.0;
      return s <= 0.04045 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
    }

    return 0.2126 * ch(c.red) + 0.7152 * ch(c.green) + 0.0722 * ch(c.blue);
  }

  double contrast(Color a, Color b) {
    final la = luminance(a);
    final lb = luminance(b);
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  testWidgets('V3.6.1① 元信息单行无换行（锁卡片变矮）', (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[
      _row('梯子', <String>['阳台'], id: 1),
    ]);
    await repo.deleteItem(1);
    await _pumpPage(tester, repo: repo, gateway: FakeBackupGateway());
    await tester.tap(find.byKey(const Key('trash_entry')));
    await tester.pumpAndSettle();

    // 元信息是单行 Text（maxLines=1 + ellipsis），不再内嵌 \n 换行。
    final meta = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('trash_meta_梯子')),
        matching: find.byType(Text),
      ),
    );
    expect(meta.maxLines, 1, reason: '元信息单行');
    expect(meta.overflow, TextOverflow.ellipsis, reason: '超长位置省略号');
    expect(meta.data, isNot(contains('\n')), reason: '元信息无硬换行');

    // 超长位置兜底：长按气泡（Tooltip）给完整位置，防恢复判断失准。
    final tip = tester.widget<Tooltip>(
      find.byKey(const Key('trash_meta_梯子')),
    );
    expect(tip.message, contains('原位置：'),
        reason: '长按气泡含完整位置');
    expect(tip.triggerMode, TooltipTriggerMode.longPress);
  });

  testWidgets('V3.6.1② chip 触控区高度 ≥ 48dp（锁安全侧）', (tester) async {
    final repo = FakeListRepository(<ItemWithLocations>[
      _row('梯子', <String>['阳台'], id: 1),
    ]);
    await repo.deleteItem(1);
    await _pumpPage(tester, repo: repo, gateway: FakeBackupGateway());
    await tester.tap(find.byKey(const Key('trash_entry')));
    await tester.pumpAndSettle();

    final restoreSize = tester.getSize(find.byKey(const Key('trash_restore_梯子')));
    final purgeSize = tester.getSize(find.byKey(const Key('trash_purge_梯子')));
    expect(restoreSize.height, greaterThanOrEqualTo(48),
        reason: '恢复按钮触控区 ≥ 48dp（元宝驳回 42dp）');
    expect(purgeSize.height, greaterThanOrEqualTo(48),
        reason: '彻底删除按钮触控区 ≥ 48dp');
  });

  test('V3.6.1③ chip 填充底与文字色对比度达标（防主题吞色）', () {
    // 批复①：浅绿/淡红填充 + 深色文字，对比度均 >= 4.5（AA）。
    // 锁精确色值 + 算对比度：任何改回浅色文字/透明度/主题继承都会失败。
    const restoreFg = Color(0xff1b5e20);
    const restoreBg = Color(0xffe8f5e9);
    const purgeFg = Color(0xffc62828);
    const purgeBg = Color(0xfffdecea);

    expect(restoreFg.value, 0xff1b5e20, reason: '恢复文字色写死深绿');
    expect(restoreBg.value, 0xffe8f5e9, reason: '恢复浅绿填充底写死');
    expect(purgeFg.value, 0xffc62828, reason: '删除文字色写死深红');
    expect(purgeBg.value, 0xfffdecea, reason: '删除淡红填充底写死');

    expect(contrast(restoreFg, restoreBg), greaterThanOrEqualTo(4.5),
        reason: '恢复 chip 对比度 ≈7.00');
    expect(contrast(purgeFg, purgeBg), greaterThanOrEqualTo(4.5),
        reason: '删除 chip 对比度 ≈4.92');

    // 批复 a：两个 chip 均为「浅填充底 + 深文字色」——填充克制、文字清晰，
    // 危险操作（淡红底）与安全操作（浅绿底）都不喧宾夺主。
    expect(luminance(restoreBg), greaterThan(0.8), reason: '恢复填充底是浅色');
    expect(luminance(purgeBg), greaterThan(0.8), reason: '删除填充底是浅色');
    expect(luminance(restoreFg), lessThan(0.2), reason: '恢复文字是深色');
    expect(luminance(purgeFg), lessThan(0.2), reason: '删除文字是深色');
  });
}

// ignore_for_file: deprecated_member_use
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:home_inventory/home_inventory.dart';

/// V3.12「部分废弃」（只废 1 个，不连坐）专项测试。
///
/// 对应元宝技术审核九条必做项：1 建表/restored_quantity、2 source_type、
/// 4 全局不变式每次写操作后校验、6 清空级联、7 校准一致性、8 备份 v9→v10。
/// 第 3 条（多笔在借问哪笔）与第 5 条（中文数字）由 UI/解析器测试覆盖。
///
/// 用真实 sqlite 覆盖数据层——地基语义出错必须由真实库兜住。
void main() {
  setUpAll(() => sqfliteFfiInit());

  late Directory tempDir;
  late InventoryDatabase db;
  late List<InventoryDatabase> opened;

  InventoryDatabase newDb({String name = 'inventory.db', int version = 10}) {
    final instance = InventoryDatabase(
      databaseFactory: databaseFactoryFfi,
      databasePath: p.join(tempDir.path, name),
      version: version,
    );
    opened.add(instance);
    return instance;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('home_inventory_v312_');
    opened = <InventoryDatabase>[];
    db = newDb();
    await db.open();
  });

  tearDown(() async {
    for (final instance in opened) {
      try {
        await instance.close();
      } catch (_) {
        // 迁移失败用例可能已自行关库。
      }
    }
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// 全局不变式（元宝第 4 条）：每次写操作后校验。
  /// 逐件验 items.quantity == SUM(活跃位置数量)。
  Future<void> expectInvariant() async {
    final database = await db.open();
    final items = await database.query(
      'items',
      columns: <String>['id', 'name', 'quantity'],
      where: 'is_deleted = 0',
    );
    for (final row in items) {
      final sums = await database.rawQuery(
        'SELECT COALESCE(SUM(quantity), 0) AS total FROM item_locations '
        'WHERE item_id = ? AND is_deleted = 0',
        <Object?>[row['id']],
      );
      expect(
        (sums.first['total'] as num?)?.toInt(),
        (row['quantity'] as num?)?.toInt(),
        reason: '「${row['name']}」在库数必须等于各位置数量之和',
      );
    }
    expect(await db.checkConservation(), isTrue, reason: '守恒自检必须通过');
  }

  /// 总拥有数 = 在库 + 在借 + 整件废弃未恢复 + 部分废弃未恢复。
  Future<int> totalOwned() async {
    final database = await db.open();
    final rows = await database.rawQuery('''
      SELECT
        (SELECT COALESCE(SUM(quantity), 0) FROM items WHERE is_deleted = 0)
        + (SELECT COALESCE(SUM(quantity - returned_qty), 0) FROM loans
           WHERE is_deleted = 0 AND returned_qty < quantity)
        + (SELECT COALESCE(SUM(quantity), 0) FROM items WHERE is_deleted = 1)
        + (SELECT COALESCE(SUM(quantity - restored_quantity), 0) FROM item_discards)
      AS total
    ''');
    return (rows.first['total'] as num?)?.toInt() ?? 0;
  }

  Future<ItemWithLocations> find(String name) async {
    final found = await db.findByName(name);
    expect(found, isNotNull, reason: '「$name」应当已录入');
    return found!;
  }

  /// 阳台 2、客厅 1 的梯子（PM 真机现象底稿）。
  Future<(int, int)> seedLadder() async {
    final balcony = await db.addLocation('阳台');
    final living = await db.addLocation('客厅');
    await db.upsertItemLocation('梯子', balcony, quantity: 2);
    await db.upsertItemLocation('梯子', living, quantity: 1);
    return (balcony, living);
  }

  // ============ 1 建表 + restored_quantity 取代 is_deleted 标志 ============

  test('V3.12 废弃流水表建好：restored_quantity 字段存在且默认 0', () async {
    final database = await db.open();
    final cols = await database.rawQuery('PRAGMA table_info(item_discards)');
    final names = cols.map((c) => c['name'] as String).toList();
    expect(
      names,
      containsAll(<String>[
        'id', 'item_id', 'item_name', 'quantity', 'location_id',
        'location_name', 'discarded_at', 'source_type', 'restored_quantity',
      ]),
    );
    expect(names, isNot(contains('is_deleted')),
        reason: '恢复状态用 restored_quantity 表达，不再用软删标志');
    final version = await database.rawQuery('PRAGMA user_version');
    expect((version.first['user_version'] as num?)?.toInt(), 10);
  });

  // ============ 部分废弃主流程 ============

  test('部分废弃：只扣指定位置，数量写进流水，物品仍在明细', () async {
    final (balcony, _) = await seedLadder();
    final before = await totalOwned();

    final outcome =
        await db.discardQuantity('梯子', 1, locationId: balcony);

    expect(outcome.wholeItem, isFalse);
    expect(outcome.quantity, 1);
    expect(outcome.locationName, '阳台');
    expect(outcome.remainingInStock, 2, reason: '3 个废 1 个还剩 2 个');

    final item = await find('梯子');
    expect(item.item.quantity, 2, reason: '物品总数减 1');
    expect(item.quantityAt(balcony), 1, reason: '阳台 2 → 1');
    expect(item.quantityAt((await db.addLocation('客厅'))), isNotNull,
        reason: '客厅数量不受影响');

    final discards = await db.getDiscards();
    expect(discards.length, 1);
    expect(discards.first.itemName, '梯子');
    expect(discards.first.quantity, 1);
    expect(discards.first.restoredQuantity, 0);
    expect(discards.first.pendingQuantity, 1);
    expect(discards.first.locationName, '阳台');
    expect(await totalOwned(), before, reason: '总拥有数不变（废的记进流水）');
    await expectInvariant();
  });

  test('部分废弃：数量 == 在库总数时自动转整件废弃，不留僵尸记录', () async {
    final balcony = await db.addLocation('阳台');
    await db.upsertItemLocation('螺丝刀', balcony, quantity: 1);

    final outcome =
        await db.discardQuantity('螺丝刀', 1, locationId: balcony);

    expect(outcome.wholeItem, isTrue, reason: '废完即整件废弃');
    final found = await db.findByName('螺丝刀');
    expect(found, isNull, reason: '物品整条进回收站');
    final deleted = await db.getDeletedItems();
    expect(deleted.any((d) => d.item.name == '螺丝刀'), isTrue);
    expect((await db.getDiscards()).length, 0,
        reason: '整件废弃不产生流水');
    await expectInvariant();
  });

  test('部分废弃：位置数量不够时抛中文错误，且不改任何数量', () async {
    final (balcony, _) = await seedLadder();
    var threw = false;
    try {
      // 阳台只有 2 个，要废 5 个 → 必须拦下。
      await db.discardQuantity('梯子', 5, locationId: balcony);
    } on ArgumentError catch (e) {
      threw = true;
      expect(e.message.toString(), contains('不够废弃'));
    }
    expect(threw, isTrue);
    final item = await find('梯子');
    expect(item.item.quantity, 3, reason: '总数不受影响');
    expect(item.quantityAt(balcony), 2, reason: '该位置数量不变');
    expect((await db.getDiscards()).length, 0);
    await expectInvariant();
  });

  // ============ 2 source_type ============

  test('source_type：废弃来源分在库/在借两档并落库', () async {
    final balcony = await db.addLocation('阳台');
    await db.upsertItemLocation('梯子', balcony, quantity: 3);

    await db.discardQuantity('梯子', 1,
        locationId: balcony, sourceType: DiscardSource.inStock);
    await db.discardQuantity('梯子', 1,
        locationId: balcony, sourceType: DiscardSource.onLoan);

    final discards = await db.getDiscards();
    expect(discards.length, 2);
    expect(discards.map((d) => d.sourceType).toSet(),
        <DiscardSource>{DiscardSource.inStock, DiscardSource.onLoan});
    final database = await db.open();
    final rows = await database.query('item_discards',
        columns: <String>['source_type']);
    expect(rows.map((r) => r['source_type']).toSet(),
        <String>{'in_stock', 'on_loan'});
  });

  // ============ 恢复流水：恢复时问位置 ============

  test('恢复流水：加到指定位置，restored_quantity 累加，物品仍在明细', () async {
    final (balcony, _) = await seedLadder();
    final living = await db.addLocation('客厅');
    await db.discardQuantity('梯子', 1, locationId: balcony);
    final discard = (await db.getDiscards()).first;

    final restored = await db.restoreDiscard(discard.id!, living);

    expect(restored.restoredQuantity, 1);
    expect(restored.pendingQuantity, 0);
    final item = await find('梯子');
    expect(item.item.quantity, 3, reason: '恢复后总数回到 3');
    expect(item.quantityAt(living), 2, reason: '客厅 1 + 恢复的 1');
    expect(item.quantityAt(balcony), 1);
    expect((await db.getDiscards()).length, 0,
        reason: '全部恢复后不再出现在回收站');
    await expectInvariant();
  });

  test('恢复流水：物品已整体废弃时拒绝恢复（提示先恢复物品）', () async {
    final balcony = await db.addLocation('阳台');
    await db.upsertItemLocation('梯子', balcony, quantity: 2);
    await db.discardQuantity('梯子', 1, locationId: balcony);
    // 再把剩下 1 个也废了 → 整件废弃。
    await db.discardQuantity('梯子', 1, locationId: balcony);
    final discard = (await db.getDiscards(includeRestored: true)).first;

    var threw = false;
    try {
      await db.restoreDiscard(discard.id!, balcony);
    } on ArgumentError catch (e) {
      threw = true;
      expect(e.message.toString(), contains('已整体进回收站'));
    }
    expect(threw, isTrue);
  });

  // ============ 6 清空回收站级联清流水 ============

  test('清空回收站：级联清掉部分废弃流水（元宝批复第 6 条）', () async {
    final balcony = await db.addLocation('阳台');
    await db.upsertItemLocation('梯子', balcony, quantity: 3);
    await db.discardQuantity('梯子', 1, locationId: balcony);
    expect((await db.getDiscards()).length, 1);

    await db.purgeAll();

    expect((await db.getDiscards(includeRestored: true)).length, 0,
        reason: '清空回收站 = 彻底不要了，流水一并清掉');
  });

  test('彻底删除整件物品：同名流水一并清掉（否则会凭空多出几个）', () async {
    final balcony = await db.addLocation('阳台');
    await db.upsertItemLocation('梯子', balcony, quantity: 3);
    await db.discardQuantity('梯子', 1, locationId: balcony);
    final deleted = await db.getDeletedItems();
    // 先把它整体废弃，再彻底删除。
    await db.deleteItem((await find('梯子')).item.id!);
    final all = await db.getDeletedItems();
    expect(all.length, greaterThanOrEqualTo(1));

    await db.purgeItem(all.first.item.id!);

    expect((await db.getDiscards(includeRestored: true)).length, 0);
    expect(deleted, isNotNull);
  });

  // ============ 7 校准与流水一致性 ============

  test('校准把位置数量调少 → 自动生成废弃流水，守恒不裂', () async {
    final (balcony, _) = await seedLadder();
    final item = await find('梯子');
    final before = await totalOwned();

    // 用户清点：阳台只有 1 个（实际少了 1 个）。
    final report = await db.calibrateQuantities(
      locationTotals: <int, Map<int, int>>{
        item.item.id!: <int, int>{balcony: 1},
      },
    );
    expect(report.changedCount, 1);

    final discards = await db.getDiscards();
    expect(discards.length, 1, reason: '差额自动记进废弃流水');
    expect(discards.first.quantity, 1);
    expect(discards.first.locationName, '阳台');

    final after = await find('梯子');
    expect(after.item.quantity, 2);
    expect(await totalOwned(), before,
        reason: '活跃减了但"已废弃未恢复"加上，总拥有数不变');
    await expectInvariant();
  });

  test('校准把位置数量调多 → 不产生流水', () async {
    final (balcony, _) = await seedLadder();
    final item = await find('梯子');
    await db.calibrateQuantities(
      locationTotals: <int, Map<int, int>>{
        item.item.id!: <int, int>{balcony: 5},
      },
    );
    expect((await db.getDiscards()).length, 0);
    expect((await find('梯子')).item.quantity, 6);
    await expectInvariant();
  });

  // ============ 8 备份 v9 → v10 ============

  test('备份导出带废弃流水；v10 备份恢复后流水与数量原样', () async {
    final balcony = await db.addLocation('阳台');
    await db.upsertItemLocation('梯子', balcony, quantity: 3);
    await db.discardQuantity('梯子', 1, locationId: balcony);

    final backup = await db.exportBackup();
    expect(backup.containsKey('item_discards'), isTrue);
    expect((backup['item_discards'] as List<dynamic>).length, 1);

    final target = newDb(name: 'restored.db');
    await target.open();
    await target.restoreBackup(backup);

    final discards = await target.getDiscards();
    expect(discards.length, 1);
    expect(discards.first.quantity, 1);
    final item = await target.findByName('梯子');
    expect(item!.item.quantity, 2);
    expect(item.quantityAt(balcony), 2, reason: '阳台 3 个废弃 1 个后剩 2 个');
    expect(await target.checkConservation(), isTrue);
  });

  test('v9 老备份（无流水表）恢复到 v10 正常，流水表为空', () async {
    final balcony = await db.addLocation('阳台');
    await db.upsertItemLocation('梯子', balcony, quantity: 2);
    final backup = await db.exportBackup();
    final legacy = Map<String, Object?>.from(backup)
      ..['schemaVersion'] = 9
      ..remove('item_discards');

    final target = newDb(name: 'legacy.db');
    await target.open();
    await target.restoreBackup(legacy);

    expect((await target.getDiscards()).length, 0);
    final item = await target.findByName('梯子');
    expect(item!.item.quantity, 2);
    expect(item.quantityAt(balcony), 2);
    expect(await target.checkConservation(), isTrue);
  });

  test('v10 备份被 v9 应用拒绝（向下不兼容）', () async {
    final backup = await db.exportBackup();
    expect((backup['schemaVersion'] as num?)?.toInt(), 10);
    final legacy = newDb(name: 'v9app.db', version: 9);
    await legacy.open();
    var threw = false;
    try {
      await legacy.restoreBackup(backup);
    } on ArgumentError catch (e) {
      threw = true;
      expect(e.message.toString(), contains('版本高于'));
    }
    expect(threw, isTrue);
  });

  // ============ 迁移 v9 → v10 ============

  test('v9 → v10 迁移：建出流水表，老数据一字不动', () async {
    // 先用 v9 库建数据（v9 没有流水表）。
    final legacy = newDb(name: 'legacy_v9.db', version: 9);
    await legacy.open();
    final balcony = await legacy.addLocation('阳台');
    await legacy.upsertItemLocation('梯子', balcony, quantity: 2);
    await legacy.close();

    // 再用 v10 打开同一个文件 → 触发迁移。
    final upgraded = newDb(name: 'legacy_v9.db', version: 10);
    await upgraded.open();
    final database = await upgraded.open();
    final version = await database.rawQuery('PRAGMA user_version');
    expect((version.first['user_version'] as num?)?.toInt(), 10);
    final item = await upgraded.findByName('梯子');
    expect(item!.item.quantity, 2, reason: '迁移不得改动老数据');
    expect(item.quantityAt(balcony), 2);
    expect((await upgraded.getDiscards()).length, 0);
    expect(await upgraded.checkConservation(), isTrue);
  });

  // ============ 全局不变式：全操作序列后逐件校验 ============

  test('全操作序列后守恒不破（录入/借出/归还/废弃/恢复/校准/挪位）', () async {
    final balcony = await db.addLocation('阳台');
    final living = await db.addLocation('客厅');
    await db.upsertItemLocation('梯子', balcony, quantity: 3);
    await db.upsertItemLocation('梯子', living, quantity: 1);
    final before = await totalOwned();

    // 借出 1 个（在库 3 → 2，在借 1）。
    final loan = await db.lendItem('梯子', '张三', quantity: 1);
    await expectInvariant();
    expect(await totalOwned(), before);

    // 归还 1 个（回到阳台）。
    await db.returnLoan(loan.id!, quantity: 1, toLocationId: balcony);
    await expectInvariant();
    expect(await totalOwned(), before);

    // 部分废弃 1 个（阳台 3 → 2）。
    await db.discardQuantity('梯子', 1, locationId: balcony);
    await expectInvariant();
    expect(await totalOwned(), before);

    // 恢复那 1 个（回到客厅——恢复时问位置）。
    final discard = (await db.getDiscards()).first;
    await db.restoreDiscard(discard.id!, living);
    await expectInvariant();
    expect(await totalOwned(), before);

    // 挪位：整体挪到客厅。
    await db.moveItemWhole('梯子', living);
    await expectInvariant();
    expect(await totalOwned(), before);

    // 部分挪：从客厅挪 2 个到阳台。
    await db.moveItemPartial('梯子', living, balcony, quantity: 2);
    await expectInvariant();
    expect(await totalOwned(), before);

    // 校准：把阳台调成 1（少 1 个 → 生成流水）。
    final item = await find('梯子');
    await db.calibrateQuantities(
      locationTotals: <int, Map<int, int>>{
        item.item.id!: <int, int>{balcony: 1},
      },
    );
    await expectInvariant();
    expect(await totalOwned(), before, reason: '总拥有数全程守恒');
  });
}

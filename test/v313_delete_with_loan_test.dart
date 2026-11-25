// ignore_for_file: deprecated_member_use
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:home_inventory/home_inventory.dart';

/// V3.13「删除物品留下孤儿借出记录」专项测试（PM 2026-11-26 真机截图暴露）。
///
/// 真机场景：梯子 3 个，王借走 1 个、李借走 1 个。PM 在「物品明细」页点删除，
/// 弹窗只说「删除后可在回收站恢复」，**完全没提还有 2 个在借**。删完的
/// 后果是：loans 表的 2 笔借出记录仍是 is_deleted=0，而 items 行已软删——
/// 借出管理页照常显示「梯子 ×1 借出中 ×2」，但梯子已经在回收站。
/// 账彻底乱了：孤儿借出 + 恢复后凭空多出 2 个在借。
///
/// 根因：`_softDeleteWholeItem` 只软删 items + item_locations，
/// **完全没处理 loans 表**。两条路径都踩到：
///   ① 明细页「删除物品」→ deleteItem
///   ② 部分废弃「废完整个物品」（数量 == 在库总数自动转整件废弃）
///   → discardQuantity
///
/// 对照：语音整件废弃「梯子废弃了」走 _handleDiscard，会**先自动归还**
/// 再软删，所以那条路径是对的——两条路径口径不一致正是 V3.9.2 同款坑。
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
    tempDir = await Directory.systemTemp.createTemp('home_inventory_v313_');
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

  /// 录 3 个梯子在阳台，借给王 1 个、李 1 个（在库剩 1 个）。
  Future<int> seedThreeLaddersTwoLoans() async {
    final balcony = await db.addLocation('阳台');
    await db.upsertItemLocation('梯子', balcony, quantity: 3);
    await db.lendItem('梯子', '王', quantity: 1);
    await db.lendItem('梯子', '李', quantity: 1);
    return balcony;
  }

  /// 仍在「在借」里的梯子借出记录（孤儿 = items 已软删但 loans 还活着）。
  Future<List<Loan>> orphanLoans() async {
    final items = await db.getAllItemsWithLocations();
    final liveIds = items.map((i) => i.item.id).toSet();
    final loans = await db.getAllLoans();
    return loans.where((l) => !liveIds.contains(l.itemId)).toList();
  }

  test('① 明细页删除物品：不得留下孤儿借出记录', () async {
    await seedThreeLaddersTwoLoans();
    expect((await db.getAllLoans()).length, 2, reason: '前置：两笔在借');

    final items = await db.getAllItemsWithLocations();
    final ladder =
        items.firstWhere((i) => i.item.name == '梯子');
    await db.deleteItem(ladder.item.id!);

    final orphans = await orphanLoans();
    expect(orphans, isEmpty,
        reason: '删除物品后，这两笔在借记录不该继续挂在借出管理里：'
            '${orphans.map((l) => l.borrowerName).toList()}');
  });

  test('①b 删除物品时在借记录应进回收站（可追溯、可恢复）', () async {
    await seedThreeLaddersTwoLoans();
    final items = await db.getAllItemsWithLocations();
    final ladder = items.firstWhere((i) => i.item.name == '梯子');
    await db.deleteItem(ladder.item.id!);

    final trashed = await db.getDeletedLoans();
    expect(trashed.where((l) => l.itemName == '梯子').length, 2,
        reason: '被删物品的在借记录应软删留底进回收站，而不是凭空消失');
  });

  test('② 部分废弃废完整个物品：不得留下孤儿借出记录', () async {
    await seedThreeLaddersTwoLoans();
    final items = await db.getAllItemsWithLocations();
    final ladder = items.firstWhere((i) => i.item.name == '梯子');
    final balconyId = ladder.locations.first.id!;
    // 废掉在库那 1 个 → 数量 == 在库总数 → 自动转整件废弃
    await db.discardQuantity('梯子', 1, locationId: balconyId);

    final orphans = await orphanLoans();
    expect(orphans, isEmpty,
        reason: '整件废弃时别人的在借账不能变孤儿：'
            '${orphans.map((l) => l.borrowerName).toList()}');
  });

  test('③ 守恒自检要能发现孤儿借出（之前只看物品↔位置，是盲区）', () async {
    await seedThreeLaddersTwoLoans();
    final items = await db.getAllItemsWithLocations();
    final ladder = items.firstWhere((i) => i.item.name == '梯子');
    // 绕过业务层直接造孤儿：物品行软删，但 loans 仍指向它
    // （模拟历史脏数据 / 外部改动造成的悬挂借出）。
    final database = await db.open();
    await database.update(
      'items',
      <String, Object?>{'is_deleted': 1},
      where: 'id = ?',
      whereArgs: <Object?>[ladder.item.id],
    );

    // 期望：守恒校验能把「在借记录挂在已删物品上」报出来。
    // 注意 checkConservation() 返回 true = 账是平的；这里应当返回 false。
    final stillConsistent = await db.checkConservation();
    expect(stillConsistent, isFalse,
        reason: '守恒校验必须能发现孤儿借出（之前只看物品↔位置，是盲区）');
  });

  test('⑥ 删除有在借的物品后再恢复：状态必须完整还原（不是凭空多出）', () async {
    await seedThreeLaddersTwoLoans();
    final before = await db.getAllQuantityInfo();
    final items = await db.getAllItemsWithLocations();
    final ladder = items.firstWhere((i) => i.item.name == '梯子');
    await db.deleteItem(ladder.item.id!);
    expect(await db.getAllLoans(), isEmpty,
        reason: '删物品时那两笔在借应一并移出「在借」');

    // 从回收站恢复梯子
    final trashed = await db.getDeletedItems();
    final back = trashed.firstWhere((i) => i.item.name == '梯子');
    await db.restoreItem(back.item.id!);

    // ⚠ V3.13 修正：恢复是「撤销删除」，必须**完整还原**到删除前的状态：
    // 王、李各借 1 个（在借 2），阳台在库 1 个，总拥有 3。
    // 早先这里断言「恢复后不得有在借」是写反了方向 —— 那样会让
    // 在借账凭空消失（王手里的梯子没人认领了）。
    final loans = await db.getAllLoans();
    expect(loans.length, 2, reason: '恢复后那两笔在借必须一并回来');
    final after = await db.getAllQuantityInfo();
    final b = before[ladder.item.id!]!;
    final a = after[ladder.item.id!]!;
    expect(a.stock, b.stock, reason: '在库数应与删除前一致');
    expect(a.lent, b.lent, reason: '在借数应与删除前一致');
    expect(a.total, b.total, reason: '总拥有数应与删除前一致');
    expect(await db.checkConservation(), isTrue);
  });

  test('④ 恢复链路端到端：废弃 1 个 → 恢复 → 数量真的回来', () async {
    // PM 截图时间线：22:36 点了恢复，22:45 却提示「阳台只有 0 个」。
    // 这条测试专门验证"恢复后数量有没有真的加回原位置"。
    final balcony = await db.addLocation('阳台');
    await db.upsertItemLocation('梯子', balcony, quantity: 3);

    // 废弃 1 个 → 在库剩 2
    final outcome = await db.discardQuantity('梯子', 1, locationId: balcony);
    expect(outcome.wholeItem, isFalse);
    expect((await db.findByName('梯子'))!.quantityAt(balcony), 2,
        reason: '废弃 1 个后阳台应剩 2 个');

    // 恢复这 1 个 → 阳台应回到 3
    final discards = await db.getDiscards();
    expect(discards.length, 1);
    await db.restoreDiscard(discards.first.id!, balcony);
    expect((await db.findByName('梯子'))!.quantityAt(balcony), 3,
        reason: '恢复后数量必须真的加回原位置');

    // 恢复后再废弃 1 个必须成功（这正是 PM 22:45 那次失败的场景）
    final again = await db.discardQuantity('梯子', 1, locationId: balcony);
    expect(again.remainingInStock, 2);
  });

  test('⑦ 恢复物品：被级联软删的借出记录必须一并恢复（否则凭空多出在借）', () async {
    await seedThreeLaddersTwoLoans();
    final items = await db.getAllItemsWithLocations();
    final ladder = items.firstWhere((i) => i.item.name == '梯子');
    await db.deleteItem(ladder.item.id!);
    expect(await db.getAllLoans(), isEmpty, reason: '前置：已移出在借');

    // 从回收站恢复梯子 —— 借出记录是「随物品一起被删」的，
    // 恢复物品就应恢复它们，否则账上凭空多出 2 个在借。
    final trashed = await db.getDeletedItems();
    final back = trashed.firstWhere((i) => i.item.name == '梯子');
    await db.restoreItem(back.item.id!);

    final loans = await db.getAllLoans();
    expect(loans.length, 2,
        reason: '恢复物品后，那两笔在借应一并回来（否则账凭空多出/丢失在借）');
    expect(loans.every((l) => l.borrowerName == '王' || l.borrowerName == '李'),
        isTrue);
    expect(await db.checkConservation(), isTrue, reason: '恢复后账必须平');
  });

  test('⑧ 彻底删除物品：其借出记录必须一并物理清除（不得留永久孤儿）', () async {
    await seedThreeLaddersTwoLoans();
    final items = await db.getAllItemsWithLocations();
    final ladder = items.firstWhere((i) => i.item.name == '梯子');
    await db.deleteItem(ladder.item.id!);

    // 彻底删除梯子 → 借出记录也必须没，否则回收站里会挂着
    // 一笔「梯子借给王」的记录，而梯子已经不存在了。
    await db.purgeItem(ladder.item.id!);

    final left = await db.getDeletedLoans();
    expect(left.where((l) => l.itemName == '梯子'), isEmpty,
        reason: '彻底删除物品后，它的借出记录也不该留在回收站');
    expect(await db.checkConservation(), isTrue);
  });

  test('⑨ 回收站单独恢复借出记录：物品还在回收站时不得恢复（否则又造孤儿）', () async {
    await seedThreeLaddersTwoLoans();
    final items = await db.getAllItemsWithLocations();
    final ladder = items.firstWhere((i) => i.item.name == '梯子');
    await db.deleteItem(ladder.item.id!);

    // 回收站里现在躺着两笔「梯子」的已删借出记录。
    final trashed = await db.getDeletedLoans();
    final one = trashed.firstWhere((l) => l.itemName == '梯子');

    // PM 在回收站里单独点「恢复」这一笔借出记录 —— 物品还在回收站，
    // 这笔借出就活了 → 又造出一个孤儿借出（同一个坑换入口重现）。
    var rejected = false;
    try {
      await db.restoreLoan(one.id!);
    } on ArgumentError catch (e) {
      rejected = true;
      expect(e.message.toString(), contains('梯子'),
          reason: '报错要说清是哪件物品还没恢复');
    }
    expect(rejected, isTrue,
        reason: '物品还在回收站时，不允许单独恢复它的借出记录');
    expect(await db.getAllLoans(), isEmpty);
    expect(await db.checkConservation(), isTrue);
  });

  test('⑤ 恢复后守恒仍成立、废弃流水标记为已恢复', () async {
    final balcony = await db.addLocation('阳台');
    await db.upsertItemLocation('梯子', balcony, quantity: 3);
    await db.discardQuantity('梯子', 1, locationId: balcony);
    final discards = await db.getDiscards();
    await db.restoreDiscard(discards.first.id!, balcony);

    final after = await db.getDiscards(includeRestored: true);
    expect(after.first.restoredQuantity, 1);
    expect(after.first.pendingQuantity, 0);
    expect(await db.checkConservation(), isTrue);
    // 默认视图只列「还有未恢复数量」的流水——恢复完就不该再出现在回收站。
    expect(await db.getDiscards(), isEmpty);
  });
}

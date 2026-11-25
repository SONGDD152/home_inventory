// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:home_inventory/home_inventory.dart';
import 'package:home_inventory/ui/trash_page.dart';

import 'fake_loan_mixin.dart';

/// V3.12：回收站页两类条目专项测试。
///
/// 回收站现在有两类条目并存：
///  * 整件废弃（items 软删行）——恢复时各位置数量原样还原；
///  * 部分废弃（item_discards 流水）——恢复时**问位置**（PM 口径）。
class TrashFakeRepository with FakeLoanMixin implements InventoryRepository {
  final List<Location> locations = <Location>[];
  final List<ItemDiscard> discards = <ItemDiscard>[];
  final List<ItemWithLocations> deleted = <ItemWithLocations>[];
  int locationId = 0;
  int discardId = 0;

  /// 记录恢复动作，便于断言"恢复时问了哪个位置"。
  final List<int> restoredTo = <int>[];

  @override
  Future<List<Location>> getAllLocations() async => List<Location>.from(locations);

  @override
  Future<List<ItemWithLocations>> getDeletedItems() async =>
      List<ItemWithLocations>.from(deleted);

  @override
  Future<List<Loan>> getDeletedLoans() async => const <Loan>[];

  @override
  Future<List<ItemDiscard>> getDiscards({bool includeRestored = false}) async {
    if (includeRestored) return List<ItemDiscard>.from(discards);
    return discards.where((d) => d.pendingQuantity > 0).toList();
  }

  @override
  Future<RestoreOutcome> restoreItem(int id) async =>
      const RestoreOutcome(itemName: '梯子', merged: false);

  @override
  Future<ItemDiscard> restoreDiscard(int discardId, int toLocationId,
      {int? quantity}) async {
    restoredTo.add(toLocationId);
    final idx = discards.indexWhere((d) => d.id == discardId);
    final old = discards[idx];
    final updated = ItemDiscard(
      id: old.id,
      itemId: old.itemId,
      itemName: old.itemName,
      quantity: old.quantity,
      locationId: old.locationId,
      locationName: old.locationName,
      discardedAt: old.discardedAt,
      sourceType: old.sourceType,
      restoredQuantity: old.restoredQuantity + (quantity ?? old.pendingQuantity),
    );
    discards[idx] = updated;
    return updated;
  }

  @override
  Future<void> purgeItem(int id) async {
    deleted.removeWhere((d) => d.item.id == id);
  }

  @override
  Future<void> purgeAll() async {
    deleted.clear();
    discards.clear();
  }

  @override
  Future<void> purgeDiscard(int discardId) async {
    discards.removeWhere((d) => d.id == discardId);
  }

  @override
  Future<ItemWithLocations?> findByName(String name) async => null;

  @override
  Future<List<ItemWithLocations>> getAllItemsWithLocations() async =>
      const <ItemWithLocations>[];

  @override
  Future<Map<String, Object?>> exportBackup() async => <String, Object?>{};

  @override
  Future<void> restoreBackup(Map<String, Object?> data) async {}

  @override
  Future<int> addLocation(String name, {String? remark}) async {
    locations.add(Location(
      id: ++locationId,
      name: name,
      createdAt: 1,
      updatedAt: 1,
    ));
    return locationId;
  }

  @override
  Future<void> updateItem(int id, String name) async {}

  @override
  Future<void> deleteItem(int id) async {}

  @override
  Future<void> updateLocation(int id, {String? name, String? remark}) async {}

  @override
  Future<void> deleteLocation(int id) async {}

  @override
  Future<MoveResult> moveItem(String itemName, int locationId,
          {String? rawText}) async =>
      MoveResult(
        itemId: 0,
        locationId: locationId,
        created: false,
        previousLocations: const <String>[],
      );

  @override
  Future<UpsertResult> upsertItemLocation(String itemName, int locationId,
          {String? rawText, int? quantity, bool additive = false}) async =>
      UpsertResult(itemId: 0, locationId: locationId, created: false);
}

void main() {
  late TrashFakeRepository repo;

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: TrashPage(repository: repo)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
  }

  setUp(() async {
    repo = TrashFakeRepository();
    await repo.addLocation('阳台');
    await repo.addLocation('客厅');
    repo.discards.add(ItemDiscard(
      id: ++repo.discardId,
      itemId: 1,
      itemName: '梯子',
      quantity: 1,
      locationId: 1,
      locationName: '阳台',
      discardedAt: DateTime.now().millisecondsSinceEpoch,
      sourceType: DiscardSource.inStock,
      restoredQuantity: 0,
    ));
    repo.deleted.add(ItemWithLocations(
      item: Item(
        id: 9,
        name: '螺丝刀',
        createdAt: 1,
        updatedAt: 1,
        isDeleted: true,
        deletedAt: 1,
        quantity: 1,
      ),
      locations: const <Location>[],
    ));
  });

  testWidgets('回收站两类条目并存：整件废弃 + 部分废弃', (tester) async {
    await pumpPage(tester);

    expect(find.text('部分废弃的物品（1）'), findsOneWidget);
    expect(find.text('已删除的物品（1）'), findsOneWidget);
    expect(find.text('梯子 ×1'), findsOneWidget);
    expect(find.textContaining('在库的那批'), findsOneWidget);
    expect(find.textContaining('原在「阳台」'), findsOneWidget);
    expect(find.text('螺丝刀'), findsOneWidget);
  });

  testWidgets('恢复部分废弃：先问位置，选完才恢复', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('trash_discard_restore_1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    // 必须先问位置（PM 口径：恢复时问位置，不靠废弃时的原位置）。
    expect(find.byKey(const Key('trash_restore_discard_dialog')), findsOneWidget);
    expect(repo.restoredTo, isEmpty, reason: '还没选位置就不能恢复');

    await tester.tap(find.byKey(const Key('trash_restore_discard_客厅')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(repo.restoredTo, <int>[2], reason: '恢复到用户选的位置');
  });

  testWidgets('恢复部分废弃：取消则不恢复', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const Key('trash_discard_restore_1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(repo.restoredTo, isEmpty);
  });

  testWidgets('彻底删除部分废弃记录：二次确认后清掉', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const Key('trash_discard_purge_1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('彻底删除'), findsWidgets);

    await tester.tap(find.text('彻底删除').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(repo.discards, isEmpty);
  });

  testWidgets('全部清空的确认文案写明包含部分废弃记录', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const Key('trash_purge_all')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.textContaining('部分废弃的记录'), findsOneWidget);
  });
}

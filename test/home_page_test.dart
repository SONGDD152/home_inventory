// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:home_inventory/home_inventory.dart';

/// 纯内存仓储：用于 widget 测试，操作是内存级的，pump 一帧即可落地。
/// 数据层的真实数据库行为由 inventory_database_test.dart 用真实 sqlite 覆盖。
class InMemoryRepository implements InventoryRepository {
  final List<Location> _locations = <Location>[];
  final List<Item> _items = <Item>[];
  final List<ItemLocation> _links = <ItemLocation>[];
  int _locationId = 0;
  int _itemId = 0;

  @override
  Future<List<Location>> getAllLocations() async =>
      List<Location>.unmodifiable(_locations);

  @override
  Future<int> addLocation(String name) async {
    final key = name.trim();
    final existing = _locations.where((l) => l.name == key).toList();
    if (existing.isNotEmpty) return existing.first.id!;
    final id = ++_locationId;
    _locations.add(
      Location(id: id, name: key, createdAt: 1, updatedAt: 1),
    );
    return id;
  }

  @override
  Future<UpsertResult> upsertItemLocation(String itemName, int locationId) async {
    final key = itemName.trim();
    var item = _items.where((i) => i.name == key).toList();
    final int itemId;
    if (item.isEmpty) {
      itemId = ++_itemId;
      _items.add(Item(id: itemId, name: key, createdAt: 1, updatedAt: 1));
    } else {
      itemId = item.first.id!;
    }
    final exists = _links.any(
      (l) => l.itemId == itemId && l.locationId == locationId,
    );
    if (exists) {
      return UpsertResult(itemId: itemId, locationId: locationId, created: false);
    }
    _links.add(
      ItemLocation(
        id: _links.length + 1,
        itemId: itemId,
        locationId: locationId,
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    return UpsertResult(itemId: itemId, locationId: locationId, created: true);
  }

  @override
  Future<ItemWithLocations?> findByName(String name) async {
    final key = name.trim();
    final item = _items.where((i) => i.name == key).toList();
    if (item.isEmpty) return null;
    final locationIds = _links
        .where((l) => l.itemId == item.first.id)
        .map((l) => l.locationId)
        .toList();
    final locations = _locations
        .where((l) => locationIds.contains(l.id))
        .toList(growable: false);
    return ItemWithLocations(item: item.first, locations: locations);
  }

  int get linkCount => _links.length;
}

void main() {
  late InMemoryRepository repo;

  setUp(() {
    repo = InMemoryRepository();
  });

  Future<void> pumpApp(WidgetTester tester) {
    return tester.pumpWidget(MaterialApp(home: HomePage(repository: repo)));
  }

  /// pump 一帧让 async 微任务与 rebuild 完成。
  /// 内存仓储无真实 I/O，无需 runAsync（headless 下 runAsync 会死锁）。
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
  }

  Future<void> addLocation(WidgetTester tester, String name) async {
    await tester.enterText(find.byKey(const Key('new_location_field')), name);
    await tester.tap(find.byKey(const Key('add_location_button')));
    await settle(tester);
  }

  Future<void> record(WidgetTester tester, String item) async {
    await tester.enterText(find.byKey(const Key('name_field')), item);
    await tester.tap(find.byKey(const Key('save_button')));
    await settle(tester);
  }

  Future<void> search(WidgetTester tester, String name) async {
    await tester.enterText(find.byKey(const Key('query_field')), name);
    await tester.tap(find.byKey(const Key('query_button')));
    await settle(tester);
  }

  testWidgets('新增位置→录入→按精确名称能查到', (tester) async {
    await pumpApp(tester);
    await addLocation(tester, '阳台');
    await record(tester, '梯子');

    expect(find.textContaining('已记下：梯子'), findsOneWidget);

    await search(tester, '梯子');

    expect(find.text('「梯子」放在：'), findsOneWidget);
    expect(find.byKey(const Key('result_location_1')), findsOneWidget);
    expect(find.textContaining('没找到'), findsNothing);
  });

  testWidgets('连点两下记下只产生一条关联', (tester) async {
    await pumpApp(tester);
    await addLocation(tester, '阳台');
    await record(tester, '梯子');
    await record(tester, '梯子');

    expect(repo.linkCount, 1);
    expect(find.text('这条已经记过了'), findsOneWidget);
  });

  testWidgets('空库查询显示没找到且不报错', (tester) async {
    await pumpApp(tester);
    await search(tester, '梯子');

    expect(find.text('没找到「梯子」'), findsOneWidget);
  });

  testWidgets('物品名为空时给出提示且不写库', (tester) async {
    await pumpApp(tester);
    await addLocation(tester, '阳台');

    await tester.tap(find.byKey(const Key('save_button')));
    await settle(tester);
    expect(find.text('请填写物品名称'), findsOneWidget);
    expect(repo.linkCount, 0);
  });

  testWidgets('同名多位置全量列出', (tester) async {
    await pumpApp(tester);
    await addLocation(tester, '阳台');
    await record(tester, '梯子');
    await addLocation(tester, '储物间');
    await record(tester, '梯子');

    await search(tester, '梯子');

    expect(find.text('「梯子」放在：'), findsOneWidget);
    expect(find.byKey(const Key('result_location_1')), findsOneWidget);
    expect(find.byKey(const Key('result_location_2')), findsOneWidget);
  });

  testWidgets('精确名称不通配：查「梯」找不到「梯子」', (tester) async {
    await pumpApp(tester);
    await addLocation(tester, '阳台');
    await record(tester, '梯子');

    await search(tester, '梯');

    expect(find.text('没找到「梯」'), findsOneWidget);
    expect(find.text('「梯子」放在：'), findsNothing);
  });
}

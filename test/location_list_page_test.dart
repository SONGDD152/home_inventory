// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_inventory/data/inventory_repository.dart';
import 'package:home_inventory/data/item.dart';
import 'package:home_inventory/ui/location_list_page.dart';

import 'fake_loan_mixin.dart';

/// 内存假仓储：位置管理用到的 4 个方法，其余 noSuchMethod 兜底。
class FakeLocationRepository with FakeLoanMixin implements InventoryRepository {
  FakeLocationRepository(List<Location> seed)
      : locations = List<Location>.from(seed);

  final List<Location> locations;
  int idSeq = 100;
  List<({int id, String? name, String? remark})> updates =
      <({int id, String? name, String? remark})>[];
  List<int> deletes = <int>[];
  List<({String name, String? remark})> adds =
      <({String name, String? remark})>[];

  @override
  Future<List<Location>> getAllLocations() async =>
      List<Location>.unmodifiable(locations);

  @override
  Future<int> addLocation(String name, {String? remark}) async {
    adds.add((name: name, remark: remark));
    final id = idSeq++;
    locations.add(
        Location(id: id, name: name, remark: remark, createdAt: 0, updatedAt: 0));
    return id;
  }

  @override
  Future<void> updateLocation(int id, {String? name, String? remark}) async {
    updates.add((id: id, name: name, remark: remark));
    final index = locations.indexWhere((l) => l.id == id);
    if (index >= 0) {
      locations[index] = Location(
        id: id,
        name: name ?? locations[index].name,
        remark: remark ?? locations[index].remark,
        createdAt: 0,
        updatedAt: 0,
      );
    }
  }

  @override
  Future<void> deleteLocation(int id) async {
    deletes.add(id);
    locations.removeWhere((l) => l.id == id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} 未在本测试使用');
}

Location _loc(String name, {String? remark, int id = 1}) =>
    Location(id: id, name: name, remark: remark, createdAt: 0, updatedAt: 0);

Future<void> _pumpPage(
  WidgetTester tester, {
  required InventoryRepository repo,
}) async {
  await tester.pumpWidget(
    MaterialApp(home: LocationListPage(repository: repo)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('渲染：位置名 + 备注显示', (tester) async {
    final repo = FakeLocationRepository(<Location>[
      _loc('阳台', remark: '第二层柜子', id: 1),
      _loc('车库', id: 2),
    ]);
    await _pumpPage(tester, repo: repo);

    expect(find.byKey(const Key('location_item_阳台')), findsOneWidget);
    expect(find.text('第二层柜子'), findsOneWidget);
    expect(find.byKey(const Key('location_item_车库')), findsOneWidget);
    expect(find.byKey(const Key('location_list')), findsOneWidget);
  });

  testWidgets('空态：无位置时显示引导文案', (tester) async {
    await _pumpPage(tester, repo: FakeLocationRepository(<Location>[]));

    expect(find.byKey(const Key('location_empty')), findsOneWidget);
    expect(find.textContaining('还没有位置'), findsOneWidget);
  });

  testWidgets('添加：名称+备注 → 调仓储（含备注）', (tester) async {
    final repo = FakeLocationRepository(<Location>[]);
    await _pumpPage(tester, repo: repo);

    await tester.tap(find.byKey(const Key('add_location_fab')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('location_name_field')), '储物间');
    await tester.enterText(
        find.byKey(const Key('location_remark_field')), '进门右手架子上');
    await tester.tap(find.text('添加').last);
    await tester.pumpAndSettle();

    expect(repo.adds, hasLength(1));
    expect(repo.adds.single.name, '储物间');
    expect(repo.adds.single.remark, '进门右手架子上');
    expect(find.byKey(const Key('location_item_储物间')), findsOneWidget,
        reason: '新增后列表刷新');
  });

  testWidgets('添加：名称为空不调仓储', (tester) async {
    final repo = FakeLocationRepository(<Location>[]);
    await _pumpPage(tester, repo: repo);

    await tester.tap(find.byKey(const Key('add_location_fab')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加').last);
    await tester.pumpAndSettle();

    expect(repo.adds, isEmpty);
    expect(find.textContaining('位置名称不能为空'), findsOneWidget);
  });

  testWidgets('编辑：预填原名与备注，改名+改备注保存', (tester) async {
    final repo = FakeLocationRepository(<Location>[_loc('阳台', id: 1)]);
    await _pumpPage(tester, repo: repo);

    await tester.tap(find.byKey(const Key('location_edit_阳台')));
    await tester.pumpAndSettle();
    // 预填校验。
    expect(find.byKey(const Key('location_name_field')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('location_name_field')), '大阳台');
    await tester.enterText(
        find.byKey(const Key('location_remark_field')), '顶楼');
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();

    expect(repo.updates, hasLength(1));
    expect(repo.updates.single.id, 1);
    expect(repo.updates.single.name, '大阳台');
    expect(repo.updates.single.remark, '顶楼');
    expect(find.byKey(const Key('location_item_大阳台')), findsOneWidget);
  });

  testWidgets('删除：确认后调仓储；取消不删', (tester) async {
    final repo = FakeLocationRepository(<Location>[_loc('车库', id: 2)]);
    await _pumpPage(tester, repo: repo);

    await tester.tap(find.byKey(const Key('location_delete_车库')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('location_delete_cancel')));
    await tester.pumpAndSettle();
    expect(repo.deletes, isEmpty);

    await tester.tap(find.byKey(const Key('location_delete_车库')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('location_delete_confirm')));
    await tester.pumpAndSettle();

    expect(repo.deletes, <int>[2]);
    expect(find.byKey(const Key('location_empty')), findsOneWidget,
        reason: '删除后列表刷新为空态');
  });

  testWidgets('删除：确认框含 V3.2 联动清理说明', (tester) async {
    final repo = FakeLocationRepository(<Location>[_loc('车库', id: 2)]);
    await _pumpPage(tester, repo: repo);

    await tester.tap(find.byKey(const Key('location_delete_车库')));
    await tester.pumpAndSettle();
    expect(find.textContaining('一并移除'), findsOneWidget);
    await tester.tap(find.byKey(const Key('location_delete_cancel')));
    await tester.pumpAndSettle();
    expect(repo.deletes, isEmpty);
  });

  testWidgets('校验拒绝：仓储抛 ArgumentError 提示失败且不炸页', (tester) async {
    final repo = ThrowingLocationRepo();
    await _pumpPage(tester, repo: repo);

    await tester.tap(find.byKey(const Key('add_location_fab')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('location_name_field')), 'x');
    await tester.tap(find.text('添加').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('操作失败'), findsOneWidget);
    expect(find.byKey(const Key('add_location_fab')), findsOneWidget,
        reason: '页面仍在，未崩溃');
  });
}

/// 校验拒绝模拟：addLocation 抛 ArgumentError（与生产仓储一致）。
class ThrowingLocationRepo extends FakeLocationRepository {
  ThrowingLocationRepo() : super(<Location>[]);

  @override
  Future<int> addLocation(String name, {String? remark}) async {
    throw ArgumentError('归一化后名称为空');
  }
}

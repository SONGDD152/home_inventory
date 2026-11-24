// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:home_inventory/home_inventory.dart';

import 'fake_loan_mixin.dart';

/// 纯内存仓储：用于 widget 测试，操作是内存级的，pump 一帧即可落地。
/// 数据层的真实数据库行为由 inventory_database_test.dart 用真实 sqlite 覆盖。
///
/// Step 0（第 4 块测试基建）：三处 key 生成已改用生产共用 normalizeName，
/// 与仓储边界同源；不再各自 trim()，杜绝两套归一化标准。
class InMemoryRepository with FakeLoanMixin implements InventoryRepository {
  final List<Location> _locations = <Location>[];
  final List<Item> _items = <Item>[];
  final List<ItemLocation> _links = <ItemLocation>[];
  int _locationId = 0;
  int _itemId = 0;

  // V3.7 缺陷修复回归：借出/归还内存实现，供首页「说一句」端到端断言。
  // 类自身方法优先于 FakeLoanMixin，不影响其他测试文件共用的 mixin。
  final List<Loan> _loans = <Loan>[];
  int _loanId = 0;

  @override
  Future<Loan> lendItem(String itemName, String borrowerName,
      {int quantity = 1, int? days}) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final loan = Loan(
      id: ++_loanId,
      itemId: 0,
      itemName: normalizeName(itemName),
      borrowerName: normalizeName(borrowerName),
      quantity: quantity,
      borrowedAt: now,
      dueAt: now + (days ?? InventoryDatabase.defaultLoanDays) * 86400000,
    );
    _loans.add(loan);
    return loan;
  }

  @override
  Future<List<Loan>> getAllLoans() async =>
      List<Loan>.unmodifiable(_loans.reversed);

  @override
  Future<void> returnLoan(int loanId, {int? quantity}) async {
    final idx = _loans.indexWhere((l) => l.id == loanId);
    if (idx < 0) return;
    final old = _loans[idx];
    final returned = quantity ?? (old.quantity - old.returnedQty);
    final total = old.returnedQty + returned;
    _loans[idx] = Loan(
      id: old.id,
      itemId: old.itemId,
      itemName: old.itemName,
      borrowerName: old.borrowerName,
      quantity: old.quantity,
      returnedQty: total,
      borrowedAt: old.borrowedAt,
      dueAt: old.dueAt,
      returnedAt: total >= old.quantity ? 1 : null,
      isPartial: total > 0 && total < old.quantity,
    );
  }

  @override
  Future<List<Location>> getAllLocations() async =>
      List<Location>.unmodifiable(_locations);

  @override
  Future<int> addLocation(String name, {String? remark}) async {
    final key = normalizeName(name);
    final existing = _locations.where((l) => l.name == key).toList();
    if (existing.isNotEmpty) return existing.first.id!;
    final id = ++_locationId;
    _locations.add(
      Location(id: id, name: key, createdAt: 1, updatedAt: 1, remark: remark),
    );
    return id;
  }

  @override
  Future<void> updateLocation(int id, {String? name, String? remark}) async {
    final idx = _locations.indexWhere((l) => l.id == id);
    if (idx < 0) return;
    final old = _locations[idx];
    _locations[idx] = Location(
      id: old.id,
      name: name == null ? old.name : normalizeName(name),
      isDeleted: old.isDeleted,
      createdAt: old.createdAt,
      updatedAt: old.updatedAt,
      remark: remark ?? old.remark,
    );
  }

  @override
  Future<void> deleteLocation(int id) async {
    final idx = _locations.indexWhere((l) => l.id == id);
    if (idx < 0) return;
    final old = _locations[idx];
    _locations[idx] = Location(
      id: old.id,
      name: old.name,
      isDeleted: true,
      createdAt: old.createdAt,
      updatedAt: old.updatedAt,
      remark: old.remark,
    );
  }

  @override
  Future<void> updateItem(int id, String name) async {
    final idx = _items.indexWhere((i) => i.id == id);
    if (idx < 0) return;
    final old = _items[idx];
    _items[idx] = Item(
      id: old.id,
      name: normalizeName(name),
      isDeleted: old.isDeleted,
      createdAt: old.createdAt,
      updatedAt: old.updatedAt,
    );
  }

  @override
  Future<void> deleteItem(int id) async {
    final idx = _items.indexWhere((i) => i.id == id);
    if (idx < 0) return;
    final old = _items[idx];
    final now = DateTime.now().millisecondsSinceEpoch;
    _items[idx] = Item(
      id: old.id,
      name: old.name,
      isDeleted: true,
      createdAt: old.createdAt,
      updatedAt: now,
      deletedAt: now,
    );
    // V3.6：活跃关联行同步软删留底（与真实库一致，恢复时可复活）。
    for (var i = 0; i < _links.length; i++) {
      final l = _links[i];
      if (l.itemId == id && !l.isDeleted) {
        _links[i] = ItemLocation(
          id: l.id,
          itemId: l.itemId,
          locationId: l.locationId,
          isDeleted: true,
          createdAt: l.createdAt,
          updatedAt: now,
          rawText: l.rawText,
          tags: l.tags,
        );
      }
    }
  }

  @override
  Future<List<ItemWithLocations>> getDeletedItems() async {
    final deleted = _items.where((i) => i.isDeleted).toList()
      ..sort((a, b) => (b.deletedAt ?? 0).compareTo(a.deletedAt ?? 0));
    return <ItemWithLocations>[
      for (final item in deleted)
        ItemWithLocations(
          item: item,
          locations: _locations
              .where((loc) =>
                  !loc.isDeleted &&
                  _links.any((link) =>
                      link.itemId == item.id && link.locationId == loc.id))
              .toList(growable: false),
        ),
    ];
  }

  @override
  Future<void> restoreItem(int id) async {
    final idx = _items.indexWhere((i) => i.id == id);
    if (idx < 0) return;
    final item = _items[idx];
    // 撞名预检查（决策点④A：撞名即失败）。
    if (_items.any((i) => i.id != id && i.name == item.name && !i.isDeleted)) {
      throw ArgumentError('已存在同名物品，恢复失败');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    _items[idx] = Item(
      id: item.id,
      name: item.name,
      createdAt: item.createdAt,
      updatedAt: now,
    );
    // 软删关联行复活（内存版不做 updated_at 精确匹配，全量复活）。
    for (var i = 0; i < _links.length; i++) {
      final l = _links[i];
      if (l.itemId == id && l.isDeleted) {
        _links[i] = ItemLocation(
          id: l.id,
          itemId: l.itemId,
          locationId: l.locationId,
          isDeleted: false,
          createdAt: l.createdAt,
          updatedAt: now,
          rawText: l.rawText,
          tags: l.tags,
        );
      }
    }
  }

  @override
  Future<void> purgeItem(int id) async {
    _items.removeWhere((i) => i.id == id && i.isDeleted);
    _links.removeWhere((l) => l.itemId == id);
  }

  @override
  Future<void> purgeAll() async {
    final ids = _items.where((i) => i.isDeleted).map((i) => i.id!).toList();
    _items.removeWhere((i) => i.isDeleted);
    _links.removeWhere((l) => ids.contains(l.itemId));
  }

  @override
  Future<UpsertResult> upsertItemLocation(String itemName, int locationId,
      {String? rawText}) async {
    final key = normalizeName(itemName);
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
  Future<MoveResult> moveItem(String itemName, int locationId,
      {String? rawText}) async {
    final key = normalizeName(itemName);
    var item = _items.where((i) => i.name == key).toList();
    final int itemId;
    if (item.isEmpty) {
      itemId = ++_itemId;
      _items.add(Item(id: itemId, name: key, createdAt: 1, updatedAt: 1));
    } else {
      itemId = item.first.id!;
    }
    // 挪位前其他位置名（软删语义在真实库覆盖；内存仓储同步移除）。
    final previous = _links
        .where((l) => l.itemId == itemId && l.locationId != locationId)
        .map((l) => _locations
            .where((loc) => loc.id == l.locationId && !loc.isDeleted)
            .map((loc) => loc.name)
            .firstOrNull)
        .whereType<String>()
        .toList();
    _links.removeWhere(
        (l) => l.itemId == itemId && l.locationId != locationId);
    final targetExists =
        _links.any((l) => l.itemId == itemId && l.locationId == locationId);
    if (!targetExists) {
      _links.add(
        ItemLocation(
          id: _links.length + 1,
          itemId: itemId,
          locationId: locationId,
          createdAt: 1,
          updatedAt: 1,
        ),
      );
    }
    return MoveResult(
      itemId: itemId,
      locationId: locationId,
      created: !targetExists,
      previousLocations: previous,
    );
  }

  @override
  Future<ItemWithLocations?> findByName(String name) async {
    final key = normalizeName(name);
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

  @override
  Future<List<ItemWithLocations>> getAllItemsWithLocations() async {
    final items = _items
        .where((i) => !i.isDeleted)
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return <ItemWithLocations>[
      for (final item in items)
        ItemWithLocations(
          item: item,
          locations: _locations
              .where((l) =>
                  !l.isDeleted &&
                  _links.any((link) =>
                      !link.isDeleted &&
                      link.itemId == item.id &&
                      link.locationId == l.id))
              .toList(growable: false),
        ),
    ];
  }

  Map<String, Object?>? lastExportedBackup;
  Map<String, Object?>? lastRestoredBackup;

  @override
  Future<Map<String, Object?>> exportBackup() async {
    lastExportedBackup = <String, Object?>{
      'app': 'home_inventory',
      'schemaVersion': 5,
      'items': _items.map((i) => i.toMap()).toList(),
      'locations': _locations.map((l) => l.toMap()).toList(),
      'item_locations': _links.map((l) => l.toMap()).toList(),
    };
    return lastExportedBackup!;
  }

  @override
  Future<void> restoreBackup(Map<String, Object?> data) async {
    lastRestoredBackup = data;
  }

  int get linkCount => _links.length;
  int get locationCount => _locations.length;
}

void main() {
  late InMemoryRepository repo;

  // V3 交互说明文案（测试按模板生成期望值，不写死样例值）。
  const notUnderstood = '没听懂，试试"XX放阳台"或"XX在哪"';
  String notFound(String item) => '暂未记录该物品：$item。';
  String recorded(String item, String location) => '已记下：$item → $location';
  String alreadyRecorded(String item, String location) =>
      '「$item」已经在「$location」了。';
  // （V3.4：locationAdded/emptyLocation 文案常量随首页手动添加入口
  // 撤下移除，相关场景迁移至位置管理页测试。）

  setUp(() {
    repo = InMemoryRepository();
  });

  // Step 0 等价断言：直接证明内存仓储的归一化与生产共用 helper 一致，
  // 不经过 UI。N2/N4 依赖的前提由此从「推断」变为「实测」。
  test('Step0 归一化等价：全角/带空格输入经内存仓储落成归一化名', () async {
    final id = await repo.addLocation('　ＡＢＣ　');
    final locations = await repo.getAllLocations();
    expect(locations, hasLength(1));
    expect(locations.single.name, normalizeName('　ＡＢＣ　'));
    expect(locations.single.name, 'abc');
    expect(locations.single.id, id);
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

  Future<void> submit(WidgetTester tester, String phrase) async {
    await tester.enterText(find.byKey(const Key('phrase_field')), phrase);
    await tester.pump(); // 让 onChanged 刷新「确定」按钮的禁用态
    await tester.tap(find.byKey(const Key('submit_button')));
    await settle(tester);
  }

  testWidgets('V3.3：右上角列表图标不复存在，明细页经抽屉可达', (tester) async {
    await pumpApp(tester);
    await settle(tester);

    // V3.3 决策点①：右上角 V1 遗留图标撤下，入口统一三道杠。
    expect(find.byKey(const Key('open_item_list')), findsNothing);
    expect(find.byKey(const Key('open_drawer')), findsOneWidget);

    // 明细页仍经抽屉可达（链路回归）。
    await tester.tap(find.byKey(const Key('open_drawer')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drawer_items')));
    await tester.pumpAndSettle();
    expect(find.text('物品明细'), findsOneWidget);
    expect(find.byKey(const Key('detail_search')), findsOneWidget);
    expect(find.textContaining('还没有记录'), findsOneWidget,
        reason: '空库空态');

    // 返回首页仍正常。
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('phrase_field')), findsOneWidget);
  });

  /// V3.4：首页手动添加入口已撤下，手动添加统一走
  /// 抽屉 → 位置管理页 → FAB → 对话框；完成后返回首页。
  Future<void> addLocationViaDrawer(WidgetTester tester, String name) async {
    await tester.tap(find.byKey(const Key('open_drawer')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drawer_locations')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add_location_fab')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('location_name_field')), name);
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    // 返回首页（位置页为 push 进入的独立路由）。
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('phrase_field')), findsOneWidget);
  }

  // ============ 6 条原有回归用例（保留意图，改为单句式驱动 + 冻结文案）============

  testWidgets('新增位置→录入→按精确名称能查到', (tester) async {
    await pumpApp(tester);
    await addLocationViaDrawer(tester, '阳台');
    // 手动添加落库后回到首页，「已添加位置」提示归位置页职责（V3.4），
    // 此处断言库内状态。
    expect(repo.locationCount, 1);

    await submit(tester, '梯子放阳台');
    expect(find.text(recorded('梯子', '阳台')), findsOneWidget);

    await submit(tester, '梯子在哪');
    expect(find.text('「梯子」在：阳台（共1处）。'), findsOneWidget);
    expect(find.byKey(const Key('result_location_1')), findsOneWidget);
    expect(find.textContaining('暂未记录'), findsNothing);
  });

  testWidgets('连点两下记下只产生一条关联', (tester) async {
    await pumpApp(tester);
    await submit(tester, '梯子放阳台');
    // 第一次：断言「已记下」确实出现过（建立对比基线）。
    expect(find.text(recorded('梯子', '阳台')), findsOneWidget);

    await submit(tester, '梯子放阳台');
    // 第二次：走幂等分支，只显示「已记过」；第一次的「已记下」被覆盖，
    // 不得两条并存——否则文案分支判定错误（DeepSeek 第92轮圈点）。
    expect(repo.linkCount, 1);
    expect(repo.locationCount, 1);
    expect(find.text(alreadyRecorded('梯子', '阳台')), findsOneWidget);
    expect(find.text(recorded('梯子', '阳台')), findsNothing);
  });

  testWidgets('空库查询显示没有记录且不报错', (tester) async {
    await pumpApp(tester);
    await submit(tester, '梯子在哪');

    expect(find.text(notFound('梯子')), findsOneWidget);
  });

  testWidgets('空输入时确定按钮禁用、零写入（文档验收场景5）', (tester) async {
    await pumpApp(tester);
    // 空输入：「确定」禁用，tap 无响应。
    final button = tester.widget<FilledButton>(find.byKey(const Key('submit_button')));
    expect(button.onPressed, isNull, reason: '空输入时确定须禁用');
    await tester.tap(find.byKey(const Key('submit_button')));
    await settle(tester);
    expect(repo.linkCount, 0);
    expect(find.text(notUnderstood), findsNothing);
  });

  testWidgets('挪位：同物品再记新位置替换旧位置（V3.2 语义）', (tester) async {
    await pumpApp(tester);
    await submit(tester, '梯子放阳台');

    await submit(tester, '梯子放储物间');
    expect(find.textContaining('已更新：梯子 → 储物间（原位置：阳台）'),
        findsOneWidget,
        reason: 'V3.2 起再记即挪位，旧位置软删');

    await submit(tester, '梯子在哪');
    expect(find.text('「梯子」在：储物间（共1处）。'), findsOneWidget);
    expect(find.byKey(const Key('result_location_2')), findsOneWidget,
        reason: '储物间是第 2 个创建的位置（id=2）');
    expect(find.text('阳台'), findsNothing, reason: '旧位置不再列出');
  });

  testWidgets('挪位：动词「挪到」也走替换语义（梯子挪到客厅）', (tester) async {
    await pumpApp(tester);
    await submit(tester, '梯子放阳台');

    await submit(tester, '梯子挪到客厅');
    expect(find.textContaining('已更新：梯子 → 客厅（原位置：阳台）'),
        findsOneWidget);

    await submit(tester, '梯子在哪');
    expect(find.text('「梯子」在：客厅（共1处）。'), findsOneWidget);
  });

  testWidgets('挪位：重复记同一位置不提示原位置（幂等）', (tester) async {
    await pumpApp(tester);
    await submit(tester, '梯子放阳台');
    await submit(tester, '梯子放阳台');
    expect(find.text('「梯子」已经在「阳台」了。'), findsOneWidget);
  });

  testWidgets('精确名称不通配：查「梯」找不到「梯子」', (tester) async {
    await pumpApp(tester);
    await submit(tester, '梯子放阳台');

    await submit(tester, '梯在哪');
    expect(find.text(notFound('梯')), findsOneWidget);
    expect(find.textContaining('「梯子」在：'), findsNothing);
  });

  // ============ 6 条新增用例（自动新建 / 归一化驱动 / 幂等 / 同源 / 提示分开）============

  testWidgets('N1 句式录入新位置自动新建并关联', (tester) async {
    await pumpApp(tester);
    // 前置：库里没有任何位置（未点 add_location_button）。
    expect(repo.locationCount, 0);

    await submit(tester, '梯子放阳台');

    expect(find.text(recorded('梯子', '阳台')), findsOneWidget);
    expect(repo.locationCount, 1);
    expect(repo.linkCount, 1);
    final locations = await repo.getAllLocations();
    expect(locations.single.name, '阳台');
  });

  testWidgets('N2 自动新建由归一化结果驱动（全角+空格）', (tester) async {
    await pumpApp(tester);
    await submit(tester, '梯子放　ＡＢＣ　');

    final locations = await repo.getAllLocations();
    expect(locations.single.name, 'abc'); // 全角转半角 + lower + trim
    expect(repo.locationCount, 1);
  });

  testWidgets('N2b 添加位置名为空走专属文案，非没听懂（V3.4 场景迁移至位置管理页）', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('open_drawer')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drawer_locations')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add_location_fab')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('location_name_field')), '   ');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    // 空名 →「位置名称不能为空」SnackBars，且不得显示「没听懂」、零写入。
    expect(find.text('位置名称不能为空。'), findsOneWidget);
    expect(find.text(notUnderstood), findsNothing);
    expect(repo.locationCount, 0);
  });

  testWidgets('N3 重复录入同一新位置幂等、无 UI 旁路', (tester) async {
    await pumpApp(tester);
    await submit(tester, '梯子放阳台');
    await submit(tester, '梯子放阳台');

    expect(repo.locationCount, 1);
    expect(repo.linkCount, 1);
  });

  testWidgets('N4 显式添加位置与句式录入同源：位置表、关联表各恰好1条', (tester) async {
    await pumpApp(tester);
    // 显式入口（V3.4 起在位置管理页）添加全角位置名 → 归一化落库。
    await addLocationViaDrawer(tester, '　ＡＢＣ　');
    expect(repo.locationCount, 1);

    // 句式录入到同一位置（归一化后同为 abc）。
    await submit(tester, '梯子放abc');

    // 两处分别断言，精确同源。
    final locations = await repo.getAllLocations();
    expect(locations, hasLength(1)); // 位置表恰好 1 条
    expect(locations.single.name, 'abc');
    expect(repo.linkCount, 1); // 关联表恰好 1 条
  });

  testWidgets('N5 两种提示分开且没听懂零写入', (tester) async {
    await pumpApp(tester);
    // 句式不合规 → 没听懂，且无任何写入。
    await submit(tester, '梯子呢');
    expect(find.text(notUnderstood), findsOneWidget);
    expect(repo.linkCount, 0);
    expect(repo.locationCount, 0);
    final locations = await repo.getAllLocations();
    expect(locations, isEmpty);

    // 句式合法但查不到 → 没有记录（与没听懂不混）。
    await submit(tester, '梯子在哪');
    expect(find.text(notFound('梯子')), findsOneWidget);
    expect(find.text(notUnderstood), findsNothing);
  });

  testWidgets('N6 V2倒装与介词口语现在录入成功且位置不重复', (tester) async {
    // 契约变更 CR-V2-R1：V1 这两句判没听懂、零写入；V2 方案 C 认倒装与介词变体。
    await pumpApp(tester);

    await submit(tester, '我把梯子放阳台了');
    expect(find.text(recorded('梯子', '阳台')), findsOneWidget);
    expect(find.text(notUnderstood), findsNothing);
    expect(repo.locationCount, 1);
    expect(repo.linkCount, 1);

    // 第二句同物同位的口语变体（放到=放），应走「已经记过」分支，不重复建位置/关联。
    await submit(tester, '梯子放到阳台');
    expect(find.text(alreadyRecorded('梯子', '阳台')), findsOneWidget);
    expect(find.text(notUnderstood), findsNothing);
    expect(repo.locationCount, 1);
    expect(repo.linkCount, 1);
  });

  testWidgets('N7 语序非法输入判没听懂且零写入（叠用倒装/多动词）',
      (tester) async {
    // 审查需改点1：规则层能确定非法的语序必须拦住，且不产生任何脏数据。
    await pumpApp(tester);

    for (final phrase in const <String>[
      '我把把梯子放阳台', // 叠用倒装
      '梯子搁阳台放厨房', // 多动词连写
      '梯子和阳台', // 无放置动词
    ]) {
      await submit(tester, phrase);
      expect(find.text(notUnderstood), findsOneWidget, reason: phrase);
      expect(repo.locationCount, 0, reason: phrase);
      expect(repo.linkCount, 0, reason: phrase);
    }
    expect(await repo.getAllLocations(), isEmpty);
  });

  // ---- 文档验收场景（端到端 UI）----

  testWidgets('验收2：记：螺丝放厨房抽屉 → 正确入库并提示成功', (tester) async {
    await pumpApp(tester);
    await submit(tester, '记：螺丝放厨房抽屉');
    expect(find.text(recorded('螺丝', '厨房抽屉')), findsOneWidget);
    expect(repo.linkCount, 1);
  });

  testWidgets('验收3：查：螺丝 → 返回厨房抽屉', (tester) async {
    await pumpApp(tester);
    await submit(tester, '记：螺丝放厨房抽屉');
    await submit(tester, '查：螺丝');
    expect(find.textContaining('「螺丝」在：厨房抽屉'), findsOneWidget);
    expect(find.text(notFound('螺丝')), findsNothing);
  });

  testWidgets('验收4：添加新位置车库 → 可被后续记录引用', (tester) async {
    await pumpApp(tester);
    await addLocationViaDrawer(tester, '车库');
    expect(repo.locationCount, 1);
    await submit(tester, '电钻放车库');
    expect(find.text(recorded('电钻', '车库')), findsOneWidget);
    expect(repo.linkCount, 1);
  });

  testWidgets('验收7：页面无 DIAG/DIAG6 调试标记与内部代号残留', (tester) async {
    await pumpApp(tester);
    expect(find.textContaining('DIAG'), findsNothing);
    expect(find.textContaining('755b329'), findsNothing);
    expect(find.textContaining('TRACE MARK'), findsNothing);
  });

  // 技术审核条件①：语音隐私弱提示常驻可见。
  // V3.3：文案去技术味（口径不变：12px 灰色、常驻展示）。
  testWidgets('弱提示：语音由系统输入法处理 常驻显示', (tester) async {
    await pumpApp(tester);
    expect(find.byKey(const Key('voice_hint')), findsOneWidget);
    expect(find.text('语音由系统输入法处理'), findsOneWidget);
    expect(find.text('语音由当前输入法处理'), findsNothing,
        reason: '旧文案不复存在');
  });

  // ---- V3.1 导航：抽屉菜单 + 兜底文字入口 ----

  testWidgets('抽屉：汉堡按钮打开，四项菜单齐全', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('open_drawer')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home_drawer')), findsOneWidget);
    expect(find.text('语音记账'), findsOneWidget);
    expect(find.text('位置管理'), findsOneWidget);
    expect(find.text('物品明细'), findsOneWidget);
    expect(find.text('数据备份与恢复'), findsOneWidget);
  });

  testWidgets('抽屉：点「物品明细」进入明细页（底部操作区可见）', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('open_drawer')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drawer_items')));
    await tester.pumpAndSettle();

    expect(find.text('物品明细'), findsOneWidget);
    expect(find.byKey(const Key('detail_search')), findsOneWidget);
    // 底部操作区两个按钮都在明细页内。
    expect(find.byKey(const Key('export_backup')), findsOneWidget);
    expect(find.byKey(const Key('restore_backup')), findsOneWidget);
  });

  testWidgets('抽屉：点「位置管理」进入位置页', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('open_drawer')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drawer_locations')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('add_location_fab')), findsOneWidget);
    expect(find.textContaining('还没有位置'), findsOneWidget,
        reason: '空库显示空态引导');
  });

  testWidgets('抽屉：点「数据备份与恢复」进入备份页', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('open_drawer')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drawer_backup')));
    await tester.pumpAndSettle();

    expect(find.text('数据备份与恢复'), findsOneWidget);
    expect(find.byKey(const Key('export_backup')), findsOneWidget);
  });

  // ---- V3.3 导航收敛 ----

  testWidgets('V3.3：底部兜底按钮不复存在，静态引导文字不可点', (tester) async {
    await pumpApp(tester);

    // 决策点②：兜底按钮撤下，原位置留静态引导文字。
    expect(find.byKey(const Key('home_menu_fallback')), findsNothing,
        reason: 'home_menu_fallback 整块移除');
    final hint = tester.widget<Text>(
      find.byKey(const Key('home_menu_hint')),
    );
    expect(hint.data, '管理物品 / 位置 / 备份：点左上角 ☰ 菜单');

    // 静态文字无任何点击响应：tap 后抽屉不展开。
    await tester.tap(find.byKey(const Key('home_menu_hint')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home_drawer')), findsNothing,
        reason: '引导文字禁止添加点击响应（审核补充提醒）');
  });

  testWidgets('V3.3：首页左边缘右滑唤醒抽屉', (tester) async {
    await pumpApp(tester);

    // Scaffold drawer 原生手势：从屏幕左缘水平拖入。
    await tester.dragFrom(const Offset(1, 300), const Offset(400, 0));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home_drawer')), findsOneWidget);
    expect(find.text('语音记账'), findsOneWidget);
    expect(find.text('物品明细'), findsOneWidget);
  });

  // ---- V3.4 首页交互收敛 + 三道杠可见性 ----

  testWidgets('V3.4：「管理位置」整块不复存在（输入框/按钮/标题/分隔线）',
      (tester) async {
    await pumpApp(tester);

    // 审核拍板：按代码实际 key 撤除（需求单 home_query_field/
    // home_add_location_field 不存在，笔误已按代码修正）。
    expect(find.byKey(const Key('new_location_field')), findsNothing);
    expect(find.byKey(const Key('add_location_button')), findsNothing);
    expect(find.text('管理位置'), findsNothing);
    expect(find.text('东西在哪里？'), findsNothing);
    expect(find.text('添加位置'), findsNothing);
    expect(find.byType(Divider), findsNothing,
        reason: '中间分隔线随「管理位置」一并撤除，不留占位');
  });

  testWidgets('V3.4：首页仅剩顶部一个输入控件（说一句）', (tester) async {
    await pumpApp(tester);

    expect(find.byType(TextField), findsOneWidget,
        reason: '首页无其他手动添加/查询入口残留');
    expect(find.byKey(const Key('phrase_field')), findsOneWidget);
  });

  testWidgets('V3.4.1：三道杠可见性锁定（深色 AppBar 底 + 亮色图标）',
      (tester) async {
    await pumpApp(tester);

    // PM 修订方向：AppBar 反转——深绿底 + 白配绿对比拉满。
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    final appBar = scaffold.appBar as AppBar;
    final theme = Theme.of(tester.element(find.byType(Scaffold).first));
    expect(appBar.backgroundColor, theme.colorScheme.primary,
        reason: 'AppBar 深色底（主题绿）');
    expect(appBar.foregroundColor, theme.colorScheme.onPrimary,
        reason: '标题亮色');
    final button = tester.widget<IconButton>(
      find.byKey(const Key('open_drawer')),
    );
    expect(button.color, Colors.white, reason: '按钮设色白色');
    expect(button.iconSize, 28, reason: '视觉尺寸较默认 24 增大');
    // V3.5.1 真机缺陷修复：颜色直接写死在 Icon 本体（不再依赖
    // M3 样式继承链），断言锁最终渲染的 Icon 而非仅参数值。
    final icon = tester.widget<Icon>(find.byIcon(Icons.menu));
    expect(icon.color, Colors.white,
        reason: '白色图标在深绿底上对比最大，真机可见（两轮缺陷后改锁渲染本体）');
    expect(icon.size, 28);
    // 点击展开（功能链路继续有效）。
    await tester.tap(find.byKey(const Key('open_drawer')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home_drawer')), findsOneWidget);
  });

  testWidgets('V3.4.1：首屏示例引导文案展示', (tester) async {
    await pumpApp(tester);
    expect(find.byKey(const Key('sample_hint')), findsOneWidget);
    expect(find.text('试试说：梯子放阳台，或：梯子在哪'), findsOneWidget);
  });

  testWidgets('V3.4：键盘弹起态顶部三道杠不被裁切、仍可点击', (tester) async {
    await pumpApp(tester);

    // 键盘弹起（聚焦顶部输入框）后再点三道杠，抽屉必须能打开。
    await tester.enterText(find.byKey(const Key('phrase_field')), '梯子放阳台');
    await tester.pump();
    await tester.tap(find.byKey(const Key('open_drawer')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home_drawer')), findsOneWidget,
        reason: 'AppBar 位于 Scaffold 顶部，键盘弹起不裁切、热区可用');
  });

  // ---------- V3.5 五模块底栏导航骨架 ----------

  testWidgets('V3.5：底栏渲染 5 个一级模块按钮', (tester) async {
    await pumpApp(tester);

    expect(find.byKey(const Key('home_bottom_nav')), findsOneWidget);
    expect(find.text('仓储'), findsOneWidget);
    expect(find.text('日程'), findsOneWidget);
    expect(find.text('知识库'), findsOneWidget);
    expect(find.text('餐饮'), findsOneWidget);
    expect(find.text('衣橱'), findsOneWidget);
  });

  testWidgets('V3.5：仓储默认选中，抽屉显示真实四项子菜单', (tester) async {
    await pumpApp(tester);

    final nav = tester.widget<BottomNavigationBar>(
      find.byKey(const Key('home_bottom_nav')),
    );
    expect(nav.currentIndex, 0, reason: '仓储默认选中（唯一可用模块）');

    await tester.tap(find.byKey(const Key('open_drawer')));
    await tester.pumpAndSettle();

    expect(find.text('仓储模块'), findsOneWidget, reason: '副标题随模块显示');
    expect(find.byKey(const Key('drawer_voice')), findsOneWidget);
    expect(find.byKey(const Key('drawer_locations')), findsOneWidget);
    expect(find.byKey(const Key('drawer_items')), findsOneWidget);
    expect(find.byKey(const Key('drawer_backup')), findsOneWidget);
    expect(find.byKey(const Key('drawer_building_schedule')), findsNothing,
        reason: '仓储模块不渲染占位项');
  });

  testWidgets('V3.5.1：切至日程 → 抽屉自动弹出并显示建设中占位（决策点①A）',
      (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('日程'));
    await tester.pumpAndSettle();

    final nav = tester.widget<BottomNavigationBar>(
      find.byKey(const Key('home_bottom_nav')),
    );
    expect(nav.currentIndex, 1, reason: '底栏高亮随点击切换');

    // V3.5.1 真机缺陷修复（修订单原文「点击一级按钮 → 左侧菜单
    // 仅展示该模块子菜单」）：底栏点击后抽屉自动弹出，占位模块
    // 有即时可见反馈（此前只切状态不弹抽屉，叠加 ☰ 不可见导致
    // 真机点占位模块零反馈）。
    expect(find.byKey(const Key('home_drawer')), findsOneWidget,
        reason: '点底栏一级按钮后抽屉自动展开');

    expect(find.text('日程模块'), findsOneWidget);
    // V3.5 补丁（占位项收敛）：只渲染当前模块自己的一条占位项。
    expect(find.byKey(const Key('drawer_building_schedule')), findsOneWidget);
    expect(find.byKey(const Key('drawer_building_knowledge')), findsNothing,
        reason: '非选中模块不渲染占位项');
    expect(find.byKey(const Key('drawer_building_dining')), findsNothing);
    expect(find.byKey(const Key('drawer_building_wardrobe')), findsNothing);
    expect(find.byKey(const Key('drawer_locations')), findsNothing,
        reason: '非仓储模块不渲染仓储四项');

    // 决策点③：占位点击仅提示，不进空白页。
    await tester.tap(find.byKey(const Key('drawer_building_schedule')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('building_snackbar_schedule')), findsOneWidget,
        reason: '点击占位项提示建设中');
    expect(find.byKey(const Key('detail_search')), findsNothing,
        reason: '不进入任何子页');
  });

  testWidgets('V3.5 补丁：切知识库/餐饮/衣橱 → 抽屉各只锁单条占位项',
      (tester) async {
    await pumpApp(tester);

    final cases = <String, String>{
      '知识库': 'knowledge',
      '餐饮': 'dining',
      '衣橱': 'wardrobe',
    };
    for (final entry in cases.entries) {
      await tester.tap(find.text(entry.key));
      await tester.pumpAndSettle();

      expect(find.byKey(Key('drawer_building_${entry.value}')), findsOneWidget,
          reason: '${entry.key}抽屉仅显示自己的占位项');
      // 其余三个占位项与仓储四项均不出现。
      for (final other in cases.entries) {
        if (other.value != entry.value) {
          expect(find.byKey(Key('drawer_building_${other.value}')),
              findsNothing);
        }
      }
      expect(find.byKey(const Key('drawer_items')), findsNothing);

      // 决策点③：点击不进页（SnackBar 提示行为已由日程组锁定；
      // SnackBar 默认驻留 4 秒会跨组排队，故此处不重复断言提示）。
      await tester.tap(find.byKey(Key('drawer_building_${entry.value}')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('detail_search')), findsNothing,
          reason: '不进入任何子页');

      // 关抽屉进入下一组。
      tester
          .state<ScaffoldState>(find.byType(Scaffold).first)
          .closeDrawer();
      await tester.pumpAndSettle();
    }
  });

  testWidgets('V3.5：切回仓储 → 抽屉恢复真实四项', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('衣橱'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home_drawer')), findsOneWidget,
        reason: '切占位模块抽屉自动弹出');

    // 模拟用户关闭抽屉后再切回仓储。
    tester.state<ScaffoldState>(find.byType(Scaffold).first).closeDrawer();
    await tester.pumpAndSettle();
    await tester.tap(find.text('仓储'));
    await tester.pumpAndSettle();

    expect(find.text('仓储模块'), findsOneWidget);
    expect(find.byKey(const Key('drawer_items')), findsOneWidget);
    expect(find.byKey(const Key('drawer_building_wardrobe')), findsNothing);
  });

  testWidgets('V3.5：仓储子菜单 → 物品明细全屏页，返回后底栏高亮不变',
      (tester) async {
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('open_drawer')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drawer_items')));
    await tester.pumpAndSettle();

    // 全屏子页（MaterialPageRoute），底栏不在该路由上。
    expect(find.text('物品明细'), findsOneWidget);
    expect(find.byKey(const Key('home_bottom_nav')), findsNothing,
        reason: '子页全屏展示，不叠底栏');

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('phrase_field')), findsOneWidget,
        reason: '返回栈正确：子页返回回首页');
    final nav = tester.widget<BottomNavigationBar>(
      find.byKey(const Key('home_bottom_nav')),
    );
    expect(nav.currentIndex, 0, reason: '返回后底栏高亮保持仓储');
  });

  testWidgets('V3.5：语音主入口与底栏并存不冲突（首屏不空回归）',
      (tester) async {
    await pumpApp(tester);

    expect(find.byKey(const Key('phrase_field')), findsOneWidget);
    expect(find.byKey(const Key('sample_hint')), findsOneWidget);
    expect(find.byKey(const Key('home_bottom_nav')), findsOneWidget);
  });

  // =========== V3.7 借出入口 + 未识别确认框 ===========
  testWidgets('V3.7：仓储抽屉末项「借出管理」可进入借出页', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('open_drawer')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('drawer_loans')), findsOneWidget);
    expect(find.text('借出管理'), findsOneWidget);

    await tester.tap(find.byKey(const Key('drawer_loans')));
    await tester.pumpAndSettle();
    expect(find.text('借出管理'), findsWidgets);
    expect(find.byKey(const Key('loan_add_fab')), findsOneWidget);
  });

  testWidgets('V3.7：未识别带借意图弹确认框，点「用这个说法」填回示例句式',
      (tester) async {
    await pumpApp(tester);
    await submit(tester, '借梯子'); // 有 guess=lend 但解析不出完整三要素
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('intent_confirm_dialog')), findsOneWidget);
    expect(find.textContaining('借出'), findsWidgets);

    await tester.tap(find.byKey(const Key('intent_confirm_use')));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byKey(const Key('phrase_field')));
    expect(field.controller!.text, contains('借给'));
  });

  testWidgets('V3.7：未识别无意图（纯物品名）仍提示没听懂、不弹确认框',
      (tester) async {
    await pumpApp(tester);
    await submit(tester, '梯子');
    await settle(tester);
    expect(find.byKey(const Key('intent_confirm_dialog')), findsNothing);
    expect(find.textContaining('没听懂'), findsOneWidget);
  });

  // =========== V3.7 借出入口 + 未识别确认框 ===========
  testWidgets('V3.7：仓储抽屉末项「借出管理」可进入借出页', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('open_drawer')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('drawer_loans')), findsOneWidget);
    expect(find.text('借出管理'), findsOneWidget);

    await tester.tap(find.byKey(const Key('drawer_loans')));
    await tester.pumpAndSettle();
    expect(find.text('借出管理'), findsWidgets);
    expect(find.byKey(const Key('loan_add_fab')), findsOneWidget);
  });

  testWidgets('V3.7：未识别带借意图弹确认框，点「用这个说法」填回示例句式',
      (tester) async {
    await pumpApp(tester);
    await submit(tester, '借梯子'); // 有 guess=lend 但解析不出完整三要素
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('intent_confirm_dialog')), findsOneWidget);
    expect(find.textContaining('借出'), findsWidgets);

    await tester.tap(find.byKey(const Key('intent_confirm_use')));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byKey(const Key('phrase_field')));
    expect(field.controller!.text, contains('借给'));
  });

  testWidgets('V3.7：未识别无意图（纯物品名）仍提示没听懂、不弹确认框',
      (tester) async {
    await pumpApp(tester);
    await submit(tester, '梯子');
    await settle(tester);
    expect(find.byKey(const Key('intent_confirm_dialog')), findsNothing);
    expect(find.textContaining('没听懂'), findsOneWidget);
  });

  // =========== 缺陷修复：语音借出/归还端到端落库 ===========
  testWidgets('修复：说「借给张三1个梯子」直接借出落库（数量1）',
      (tester) async {
    await pumpApp(tester);
    await submit(tester, '借给张三1个梯子');
    await settle(tester);

    final loans = await repo.getAllLoans();
    expect(loans, hasLength(1), reason: '说一句应直接落库，无需进借出页手填');
    expect(loans.first.itemName, '梯子');
    expect(loans.first.borrowerName, '张三');
    expect(loans.first.quantity, 1);
    expect(find.byKey(const Key('notice')), findsOneWidget);
    expect(find.textContaining('已借出：梯子 → 张三'), findsOneWidget);
  });

  testWidgets('修复：说「借给张三2个梯子」数量2落库', (tester) async {
    await pumpApp(tester);
    await submit(tester, '借给张三2个梯子');
    await settle(tester);

    final loans = await repo.getAllLoans();
    expect(loans, hasLength(1));
    expect(loans.first.quantity, 2);
  });

  testWidgets('修复：说「还了1个梯子」部分归还落库（剩余数量正确）',
      (tester) async {
    await pumpApp(tester);
    await submit(tester, '借给张三2个梯子');
    await settle(tester);
    await submit(tester, '还了1个梯子');
    await settle(tester);

    final loans = await repo.getAllLoans();
    expect(loans, hasLength(1));
    expect(loans.first.returnedQty, 1, reason: '部分归还累加到原记录');
    expect(loans.first.quantity - loans.first.returnedQty, 1);
    // 元宝批复补充①③：反馈带借阅人 + 剩余数量，与借出文案对称。
    expect(find.textContaining('已归还：梯子 → 张三（1 个 · 还剩 1 个）'),
        findsOneWidget);
  });

  testWidgets('修复：没有借出记录时说「还了梯子」给明确提示、不误判没听懂',
      (tester) async {
    await pumpApp(tester);
    await submit(tester, '还了梯子');
    await settle(tester);

    expect(find.textContaining('没有借出的梯子可还'), findsOneWidget);
    expect((await repo.getAllLoans()), isEmpty);
  });

  testWidgets('修复：同物品借给多人，说「还了1个梯子」弹候选问是谁还的（不再静默 FIFO）',
      (tester) async {
    await pumpApp(tester);
    await submit(tester, '借给张三1个梯子'); // 先借出
    await settle(tester);
    await submit(tester, '借给李四1个梯子'); // 后借出
    await settle(tester);
    await submit(tester, '还了1个梯子');
    await settle(tester);

    // V3.8（PM 真机反馈：没说谁还的会记错账）：多人未还且句中没指名 →
    // 弹候选框让用户点是谁还的，没点之前不写任何归还。
    expect(find.byKey(const Key('return_picker_dialog')), findsOneWidget);
    final before = await repo.getAllLoans();
    expect(before.every((l) => l.returnedQty == 0), isTrue,
        reason: '没选之前零写入');

    // 点「张三」→ 扣张三那笔。
    await tester.tap(find.byKey(const Key('return_pick_张三_1')));
    await settle(tester);

    final loans = await repo.getAllLoans();
    final zhang = loans.firstWhere((l) => l.borrowerName == '张三');
    final li = loans.firstWhere((l) => l.borrowerName == '李四');
    expect(zhang.returnedQty, 1, reason: '用户选了张三那笔');
    expect(li.returnedQty, 0, reason: '李四那笔完全未动');
    expect(find.textContaining('已归还：梯子 → 张三'), findsOneWidget);
  });

  testWidgets('V3.8：说「张三还了1个梯子」指名到人，直接扣张三那笔、不弹候选',
      (tester) async {
    await pumpApp(tester);
    await submit(tester, '借给张三1个梯子');
    await settle(tester);
    await submit(tester, '借给李四1个梯子');
    await settle(tester);
    await submit(tester, '张三还了1个梯子');
    await settle(tester);

    expect(find.byKey(const Key('return_picker_dialog')), findsNothing,
        reason: '句中已指名，不需要问');
    final loans = await repo.getAllLoans();
    final zhang = loans.firstWhere((l) => l.borrowerName == '张三');
    final li = loans.firstWhere((l) => l.borrowerName == '李四');
    expect(zhang.returnedQty, 1);
    expect(li.returnedQty, 0, reason: '没点名的李四那笔不动');
    expect(find.textContaining('已归还：梯子 → 张三'), findsOneWidget);
  });

  testWidgets('V3.8：说「还了1个梯子给张三」指名到人，直接扣张三那笔',
      (tester) async {
    await pumpApp(tester);
    await submit(tester, '借给张三1个梯子');
    await settle(tester);
    await submit(tester, '借给李四1个梯子');
    await settle(tester);
    await submit(tester, '还了1个梯子给张三');
    await settle(tester);

    expect(find.byKey(const Key('return_picker_dialog')), findsNothing);
    final loans = await repo.getAllLoans();
    expect(loans.firstWhere((l) => l.borrowerName == '张三').returnedQty, 1);
    expect(loans.firstWhere((l) => l.borrowerName == '李四').returnedQty, 0);
  });

  testWidgets('V3.8：指名的人没借这笔 → 提示真实候选，不静默记到别人头上',
      (tester) async {
    await pumpApp(tester);
    await submit(tester, '借给张三1个梯子');
    await settle(tester);
    await submit(tester, '王五还了1个梯子');
    await settle(tester);

    final loans = await repo.getAllLoans();
    expect(loans.first.returnedQty, 0, reason: '没指名成功就不写');
    expect(find.textContaining('没有借给「王五」的梯子未还记录'), findsOneWidget);
  });

  testWidgets('V3.8：句式格式标准常驻输入框下方', (tester) async {
    await pumpApp(tester);
    expect(find.byKey(const Key('phrase_syntax_guide')), findsOneWidget);
    // 借出/归还句式都要写明（含指名说法）。
    expect(find.textContaining('借给张三2个梯子'), findsOneWidget);
    expect(find.textContaining('张三还了1个梯子'), findsOneWidget);
    expect(find.textContaining('还了1个梯子给张三'), findsOneWidget);
  });

  testWidgets('V3.8：借出/归还反馈带位置标签', (tester) async {
    await pumpApp(tester);
    // 先记位置：梯子放阳台
    await submit(tester, '梯子放阳台');
    await settle(tester);
    await submit(tester, '借给张三1个梯子');
    await settle(tester);
    expect(find.textContaining('已借出：梯子 → 张三'), findsOneWidget);
    expect(find.textContaining('在阳台'), findsOneWidget);

    await submit(tester, '张三还了1个梯子');
    await settle(tester);
    expect(find.textContaining('已归还：梯子 → 张三'), findsOneWidget);
    expect(find.textContaining('在阳台'), findsOneWidget);
  });
}

// ignore_for_file: deprecated_member_use
// V4.3.1（+38）借出模块 Bug 紧急补丁专项测试。
//
// PM 真机打回两个 Bug：
//  Bug 1 位置查询不合并借出状态——指甲刀借给张三（在库 0 借出 1 未还），
//        查「指甲刀在哪」仍回「在：次卧床上（共1处）」，误导还能去拿。
//  Bug 2 「全部归还」无防护无轨迹——无二次确认、无归还日期、位置无恢复逻辑。
//
// 修正口径（PM 回执）：
//  * loans 加 from_location_id（v13→v14 迁移）：借出从哪扣、归还回哪；
//  * 归还时间精确可改（returned_at），备份保留完整轨迹可回溯；
//  * 查询合并未还借出：在库 0 → 「已借给X（借出日~到期日），当前在库 0，
//    原存放：…」+「借出中，不在库」；部分归还 → 在库/借出分开列；
//  * 查询与借出管理页同源（loans 一张表，getActiveLoansForItem）；
//  * 红线：不物理删借出记录、不自动清在库数。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:home_inventory/home_inventory.dart';

import 'fake_loan_mixin.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late Directory tempDir;
  late String dbPath;
  late InventoryDatabase db;
  final List<InventoryDatabase> opened = <InventoryDatabase>[];

  InventoryDatabase newDb({int? version, String? path}) {
    final instance = InventoryDatabase(
      databaseFactory: databaseFactoryFfi,
      databasePath: path ?? dbPath,
      version: version ?? InventoryDatabase.currentSchemaVersion,
    );
    opened.add(instance);
    return instance;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('v59_loan_patch_');
    dbPath = p.join(tempDir.path, 'inventory.db');
    db = newDb();
  });

  tearDown(() async {
    for (final instance in opened) {
      await instance.close();
    }
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  /// 造一件带数量的在库物品，返回位置 id。
  Future<int> putStock(String item, int quantity, String location) async {
    final locationId = await db.addLocation(location);
    await db.upsertItemLocation(item, locationId, quantity: quantity);
    return locationId;
  }

  /// 位置 id → 位置数量（经 findByName 的聚合口径）。
  Future<int> qtyAt(String item, int locationId) async {
    final found = await db.findByName(item);
    return found?.locationQuantities[locationId] ?? 0;
  }

  // ---------- Bug 2 数据层：源位置落库与位置恢复 ----------

  test('借出落库记 from_location_id：从哪个位置扣的就记哪个', () async {
    final bed = await putStock('指甲刀', 1, '次卧床上');
    final balcony = await db.addLocation('阳台');
    // 再添 1 个到阳台（第一关联仍是次卧床上 = 主位置）。
    await db.upsertItemLocation('指甲刀', balcony, quantity: 1);

    final loan = await db.lendItem('指甲刀', '张三');
    expect(loan.fromLocationId, bed,
        reason: '未指定源位置时从主位置扣，主位置 = 活跃关联 id 最小者');
  });

  test('位置恢复：归还自动回到借出前的原位置（源位置≠主位置也不丢轨迹）', () async {
    final balcony = await putStock('梯子', 2, '阳台');
    final bed = await db.addLocation('次卧床上');
    // 次卧床上单独放 1 个（各位置数量独立，阳台不动）。
    await db.upsertItemLocation('梯子', bed, quantity: 1);
    expect(await qtyAt('梯子', balcony), 2);
    expect(await qtyAt('梯子', bed), 1);

    // 从次卧床上借走 1 个（显式指定源位置）——阳台 2、次卧 0。
    final loan = await db.lendItem('梯子', '张三',
        quantity: 1, fromLocationId: bed);
    expect(await qtyAt('梯子', balcony), 2);
    expect(await qtyAt('梯子', bed), 0);

    // 归还不指定落点 → 数据层自动恢复到借出源位置（次卧床上）。
    await db.returnLoan(loan.id!);
    expect(await qtyAt('梯子', balcony), 2,
        reason: '阳台的 2 个不能被误加');
    expect(await qtyAt('梯子', bed), 1, reason: '归还回借出前的原位置：次卧床上');
  });

  test('旧记录回退主位置：from_location_id 为 null 的借出归还回主位置', () async {
    final bed = await putStock('指甲刀', 1, '次卧床上');
    final loan = await db.lendItem('指甲刀', '张三');
    expect(loan.fromLocationId, bed);

    // 模拟 v13 旧备份：借出行没有 from_location_id 列 → 恢复进 v14 库。
    final backup = await db.exportBackup();
    final loanMaps = (backup['loans'] as List<Object?>)
        .map((r) => Map<String, Object?>.from(r as Map))
        .toList();
    for (final row in loanMaps) {
      row.remove('from_location_id');
    }
    backup['loans'] = loanMaps;
    await db.restoreBackup(backup);

    final loans = await db.getAllLoans();
    expect(loans.single.fromLocationId, isNull, reason: '旧记录没有源位置');
    expect(await qtyAt('指甲刀', bed), 0, reason: '借出未还，在库为 0');
    await db.returnLoan(loans.single.id!);
    expect(await qtyAt('指甲刀', bed), 1, reason: '回退主位置（次卧床上），在库恢复');
  });

  test('归还时间：returned_at 写入精确时刻；未来时间拒绝；幂等不再覆盖', () async {
    await putStock('指甲刀', 2, '次卧床上');
    final loan = await db.lendItem('指甲刀', '张三', quantity: 2);
    final fixed =
        DateTime(2026, 11, 27, 14, 30).toUtc().millisecondsSinceEpoch;

    // 部分归还：returned_at 语义 = 还清时刻，部分归还不写。
    await db.returnLoan(loan.id!, quantity: 1, returnedAt: fixed);
    var after = (await db.getAllLoans()).single;
    expect(after.returnedQty, 1);
    expect(after.returnedAt, isNull);

    // 还清：写 UI 指定的精确归还时刻。
    await db.returnLoan(loan.id!, returnedAt: fixed);
    after = (await db.getAllLoans()).single;
    expect(after.returnedQty, 2);
    expect(after.returnedAt, fixed,
        reason: '备份与归还管理靠这一列回溯「啥时候还的」');

    // 未来时间（超过 1 分钟容差）拒绝——时间不能往还没发生的点上记。
    final future = DateTime.now().toUtc()
            .add(const Duration(minutes: 2))
            .millisecondsSinceEpoch;
    await expectLater(
      db.returnLoan(loan.id!, returnedAt: future),
      throwsArgumentError,
    );
    expect((await db.getAllLoans()).single.returnedAt, fixed,
        reason: '拒绝后原值不被覆盖');
  });

  test('v13→v14 迁移：真实旧库幂等加 from_location_id 列，旧数据不搬迁', () async {
    final dir = await Directory.systemTemp.createTemp('v59_migrate_');
    final path = p.join(dir.path, 'migrate.db');
    // 手造一个 v13 形状的库（loans 无 from_location_id）。
    final raw = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 13,
        onCreate: (Database rawDb, int version) async {
        await rawDb.execute('CREATE TABLE items ('
            'id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, '
            'is_deleted INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, '
            'updated_at INTEGER NOT NULL, deleted_at INTEGER, '
            'quantity INTEGER NOT NULL DEFAULT 1)');
        await rawDb.execute('CREATE TABLE locations ('
            'id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, '
            'is_deleted INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, '
            'updated_at INTEGER NOT NULL, remark TEXT)');
        await rawDb.execute('CREATE TABLE item_locations ('
            'id INTEGER PRIMARY KEY AUTOINCREMENT, item_id INTEGER NOT NULL, '
            'location_id INTEGER NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0, '
            'created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, '
            'raw_text TEXT, tags TEXT, quantity INTEGER NOT NULL DEFAULT 1)');
        await rawDb.execute('CREATE TABLE borrowers ('
            'id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, '
            'is_deleted INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, '
            'updated_at INTEGER NOT NULL, deleted_at INTEGER)');
        // v13 形状：没有 from_location_id。
        await rawDb.execute('CREATE TABLE loans ('
            'id INTEGER PRIMARY KEY AUTOINCREMENT, item_id INTEGER NOT NULL, '
            'item_name TEXT NOT NULL, borrower_name TEXT NOT NULL, '
            'quantity INTEGER NOT NULL DEFAULT 1, returned_qty INTEGER NOT NULL DEFAULT 0, '
            'borrowed_at INTEGER NOT NULL, due_at INTEGER NOT NULL, '
            'returned_at INTEGER, is_partial INTEGER NOT NULL DEFAULT 0, '
            'updated_at INTEGER NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0, '
            'deleted_at INTEGER)');
      },
      ),
    );
    await raw.close();

    // 用生产版本号（v14）打开 → 触发 13→14 迁移。
    final migrated = newDb(path: path);
    final bed = await migrated.addLocation('次卧床上');
    await migrated.upsertItemLocation('指甲刀', bed, quantity: 1);
    final loan = await migrated.lendItem('指甲刀', '张三');
    expect(loan.fromLocationId, bed,
        reason: '迁移后的库能记录源位置');
    await migrated.returnLoan(loan.id!);
    final migratedFound = await migrated.findByName('指甲刀');
    expect(migratedFound?.locationQuantities[bed], 1, reason: '归还位置恢复照常工作');
  });

  // ---------- Bug 1 数据层：查询合并借出状态的数据源 ----------

  test('getActiveLoansForItem：只回未还清、未软删的借出（与借出管理页同源）', () async {
    await putStock('指甲刀', 2, '次卧床上');
    final toZhang = await db.lendItem('指甲刀', '张三');
    final toLi = await db.lendItem('指甲刀', '李四');

    var active = await db.getActiveLoansForItem('指甲刀');
    expect(active, hasLength(2), reason: '两笔未还都在');
    expect(active.map((l) => l.borrowerName), containsAll(<String>['张三', '李四']));

    // 张三还清 → 只剩李四。
    await db.returnLoan(toZhang.id!);
    active = await db.getActiveLoansForItem('指甲刀');
    expect(active, hasLength(1));
    expect(active.single.borrowerName, '李四');
    expect(active.single.quantity - active.single.returnedQty, 1);

    // 李四的记录软删进回收站 → 不计入（红线：记录还在，只是不进查询）。
    await db.returnLoan(toLi.id!, quantity: 1);
    await db.deleteLoan(toLi.id!);
    active = await db.getActiveLoansForItem('指甲刀');
    expect(active, isEmpty);

    // 没记录过的物品 → 空表（查询文案回退到「暂未记录」链路）。
    expect(await db.getActiveLoansForItem('没这东西'), isEmpty);
  });

  test('备份往返：from_location_id 与 returned_at 进备份、恢复后可回溯', () async {
    final bed = await putStock('指甲刀', 1, '次卧床上');
    final loan = await db.lendItem('指甲刀', '张三');
    final fixed =
        DateTime(2026, 11, 27, 20, 8).toUtc().millisecondsSinceEpoch;
    await db.returnLoan(loan.id!, returnedAt: fixed);

    final backup = await db.exportBackup();
    final loanRow = (backup['loans'] as List<Object?>)
        .map((r) => Map<String, Object?>.from(r as Map))
        .single;
    expect(loanRow['from_location_id'], bed, reason: '源位置进备份（PM 红线：轨迹留底）');
    expect(loanRow['returned_at'], fixed, reason: '精确归还时间进备份');

    // 恢复到全新库 → 「谁、啥时候、还了几个」逐项可回溯。
    final other = newDb();
    await other.restoreBackup(backup);
    final restored = (await other.getAllLoans()).single;
    expect(restored.fromLocationId, bed);
    expect(restored.returnedAt, fixed);
    expect(restored.returnedQty, 1);
    expect(restored.borrowerName, '张三');
  });

  // ---------- Bug 2 界面层：标记全部归还的三步防护 ----------

  testWidgets('「全部归还」按钮改名「标记全部归还」，取消不动账', (tester) async {
    final repo = _LoanPageRepo();
    repo.loans.add(_nailLoan(returnedQty: 0));
    await tester.pumpWidget(
        MaterialApp(home: LoanListPage(repository: repo)));
    await tester.pump();

    // 文案修正：不再叫「全部归还」。
    expect(find.text('全部归还'), findsNothing);
    expect(find.text('标记全部归还'), findsOneWidget);

    await tester.tap(find.byKey(const Key('loan_return_7')));
    await tester.pump();

    // 二次确认弹窗：物品名 + 数量 + 不可撤销警示。
    expect(find.byKey(const Key('loan_return_confirm_dialog')), findsOneWidget);
    expect(find.textContaining('确认将 指甲刀（1个）标记为已归还'), findsOneWidget);
    expect(find.textContaining('此操作不可撤销'), findsOneWidget);

    // 取消 → 零写入。
    await tester.tap(find.byKey(const Key('loan_return_cancel')));
    await tester.pump();
    expect(repo.returnCalls, isEmpty, reason: '取消了就什么都不能改');
  });

  testWidgets('标记全部归还：归还时间可改并精确落库，恢复提示可见', (tester) async {
    final repo = _LoanPageRepo();
    repo.loans.add(_nailLoan(returnedQty: 0));
    await tester.pumpWidget(
        MaterialApp(home: LoanListPage(repository: repo)));
    await tester.pump();

    await tester.tap(find.byKey(const Key('loan_return_7')));
    await tester.pump();

    // 默认值是当前时刻（格式合法），改成指定时刻。
    final field = find.byKey(const Key('loan_return_time_field'));
    expect(field, findsOneWidget);
    await tester.enterText(field, '2026-11-27 14:30');
    await tester.tap(find.byKey(const Key('loan_return_confirm_ok')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(repo.returnCalls, hasLength(1));
    final call = repo.returnCalls.single;
    expect(call.quantity, isNull, reason: '全部归还 = 未指定部分数量');
    expect(
      call.returnedAt,
      DateTime(2026, 11, 27, 14, 30).toUtc().millisecondsSinceEpoch,
      reason: '弹窗里改的精确归还时间原样传给仓储',
    );
    // 归还回执：物品 + 归还时间 + 位置恢复提示（PM 验收点：不丢轨迹）。
    expect(find.textContaining('已标记归还：指甲刀'), findsOneWidget);
    expect(find.textContaining('2026-11-27 14:30'), findsOneWidget);
    expect(find.textContaining('位置已恢复'), findsOneWidget);
  });

  testWidgets('标记全部归还：时间格式非法拦住不发请求', (tester) async {
    final repo = _LoanPageRepo();
    repo.loans.add(_nailLoan(returnedQty: 0));
    await tester.pumpWidget(
        MaterialApp(home: LoanListPage(repository: repo)));
    await tester.pump();

    await tester.tap(find.byKey(const Key('loan_return_7')));
    await tester.pump();
    final field = find.byKey(const Key('loan_return_time_field'));
    await tester.enterText(field, 'abc');
    await tester.tap(find.byKey(const Key('loan_return_confirm_ok')));
    await tester.pump();

    expect(repo.returnCalls, isEmpty, reason: '格式非法不能落库');
    expect(find.byKey(const Key('loan_return_confirm_dialog')), findsOneWidget,
        reason: '弹窗不关，等用户改');
  });

  // ---------- Bug 1 界面层：查询合并借出状态 ----------

  testWidgets('查询合并借出：在库 0 显示「已借给…借出中，不在库」，不报共N处', (tester) async {
    final repo = _QueryRepo();
    final borrowed = DateTime(2026, 11, 25, 12).toUtc().millisecondsSinceEpoch;
    final due = borrowed + 3 * 86400000;
    repo.found = ItemWithLocations(
      item: const Item(
          id: 1, name: '指甲刀', createdAt: 1, updatedAt: 1, quantity: 0),
      locations: <Location>[
        const Location(id: 5, name: '次卧床上', createdAt: 1, updatedAt: 1),
      ],
      locationQuantities: const <int, int>{5: 0},
    );
    repo.qty = const QuantityInfo(stock: 0, lent: 1, available: 0);
    repo.activeLoans = <Loan>[
      Loan(
        id: 7,
        itemId: 1,
        itemName: '指甲刀',
        borrowerName: '张三',
        quantity: 1,
        borrowedAt: borrowed,
        dueAt: due,
      ),
    ];
    await tester.pumpWidget(MaterialApp(home: HomePage(repository: repo)));
    await tester.pump();

    await tester.enterText(
        find.byKey(const Key('phrase_field')), '指甲刀在哪');
    await tester.pump();
    await tester.tap(find.byKey(const Key('submit_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    final line =
        tester.widget<Text>(find.byKey(const Key('result_line'))).data!;
    // PM 指定文案：借阅人 + 借出日~到期日 + 当前在库 0 + 原存放 + 借出中标记。
    expect(line, contains('已借给张三'));
    String fmt(int ms) {
      final t = DateTime.fromMillisecondsSinceEpoch(ms);
      return '${t.month}/${t.day}';
    }

    expect(line, contains('（${fmt(borrowed)}~${fmt(due)}）'));
    expect(line, contains('当前在库 0'));
    expect(line, contains('原存放：次卧床上'));
    expect(line, contains('借出中，不在库'));
    // 不再误报「在：次卧床上（共1处）」。
    expect(line, isNot(contains('共1处')));
    expect(line, isNot(contains('在：')));
    // 原位置不再列成「可以拿到的地方」。
    expect(find.byKey(const Key('result_location_5')), findsNothing);
  });

  testWidgets('查询合并借出：部分归还显示在库 N 个 + 借出未还 M 个分开列', (tester) async {
    final repo = _QueryRepo();
    final borrowed = DateTime(2026, 11, 25, 12).toUtc().millisecondsSinceEpoch;
    repo.found = ItemWithLocations(
      item: const Item(
          id: 1, name: '梯子', createdAt: 1, updatedAt: 1, quantity: 1),
      locations: <Location>[
        const Location(id: 5, name: '次卧床上', createdAt: 1, updatedAt: 1),
      ],
      locationQuantities: const <int, int>{5: 1},
    );
    repo.qty = const QuantityInfo(stock: 1, lent: 1, available: 1);
    repo.activeLoans = <Loan>[
      Loan(
        id: 7,
        itemId: 1,
        itemName: '梯子',
        borrowerName: '张三',
        quantity: 2,
        returnedQty: 1,
        borrowedAt: borrowed,
        dueAt: borrowed + 3 * 86400000,
      ),
    ];
    await tester.pumpWidget(MaterialApp(home: HomePage(repository: repo)));
    await tester.pump();

    await tester.enterText(find.byKey(const Key('phrase_field')), '梯子在哪');
    await tester.pump();
    await tester.tap(find.byKey(const Key('submit_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    final line =
        tester.widget<Text>(find.byKey(const Key('result_line'))).data!;
    expect(line, contains('在库 1 个'));
    expect(line, contains('借出未还 1 个'));
    expect(line, contains('借给张三'));
    // 部分归还：在库位置照常列出（还有 1 个真能拿到）。
    expect(find.byKey(const Key('result_location_5')), findsOneWidget);
  });

  testWidgets('查询无未还借出：维持纯位置口径不变（回归保护）', (tester) async {
    final repo = _QueryRepo();
    repo.found = ItemWithLocations(
      item: const Item(
          id: 1, name: '剪刀', createdAt: 1, updatedAt: 1, quantity: 1),
      locations: <Location>[
        const Location(id: 5, name: '客厅抽屉', createdAt: 1, updatedAt: 1),
      ],
      locationQuantities: const <int, int>{5: 1},
    );
    repo.qty = const QuantityInfo(stock: 1, lent: 0, available: 1);
    repo.activeLoans = const <Loan>[];
    await tester.pumpWidget(MaterialApp(home: HomePage(repository: repo)));
    await tester.pump();

    await tester.enterText(find.byKey(const Key('phrase_field')), '剪刀在哪');
    await tester.pump();
    await tester.tap(find.byKey(const Key('submit_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    final line =
        tester.widget<Text>(find.byKey(const Key('result_line'))).data!;
    expect(line, '「剪刀」在：客厅抽屉（共1处）。');
  });
}

/// 借出记录样例：指甲刀借张三 1 个（id 固定 7，供按钮 key 定位）。
Loan _nailLoan({int returnedQty = 0}) => Loan(
      id: 7,
      itemId: 1,
      itemName: '指甲刀',
      borrowerName: '张三',
      quantity: 1,
      returnedQty: returnedQty,
      borrowedAt: DateTime(2026, 11, 25, 12).toUtc().millisecondsSinceEpoch,
      dueAt: DateTime(2026, 11, 25, 12).toUtc().millisecondsSinceEpoch +
          3 * 86400000,
    );

/// 借出管理页测试桩：记录 returnLoan 调用参数（弹窗 → 仓储的契约断言）。
class _LoanPageRepo with FakeLoanMixin implements InventoryRepository {
  final List<Loan> loans = <Loan>[];
  final List<({int id, int? quantity, int? toLocationId, int? returnedAt})>
      returnCalls = <({int id, int? quantity, int? toLocationId, int? returnedAt})>[];

  // 接口里 mixin 未覆盖的基础方法补空桩（本页用不到）。
  @override
  Future<void> updateItem(int id, String name) async {}
  @override
  Future<void> deleteItem(int id) async {}
  @override
  Future<List<ItemWithLocations>> getDeletedItems() async =>
      const <ItemWithLocations>[];
  @override
  Future<RestoreOutcome> restoreItem(int id) async => RestoreOutcome(
        itemName: '', merged: false,
      );
  @override
  Future<void> purgeItem(int id) async {}
  @override
  Future<void> purgeAll() async {}
  @override
  Future<void> updateLocation(int id, {String? name, String? remark}) async {}
  @override
  Future<void> deleteLocation(int id) async {}
  @override
  Future<UpsertResult> upsertItemLocation(String itemName, int locationId,
      {String? rawText, int? quantity, bool additive = false}) async {
    throw UnimplementedError('本页用不到');
  }

  @override
  Future<MoveResult> moveItem(String itemName, int locationId,
          {String? rawText}) async =>
      throw UnimplementedError('本页用不到');

  @override
  Future<int> addLocation(String name, {String? remark}) async => 1;

  @override
  Future<List<ItemWithLocations>> getAllItemsWithLocations() async =>
      const <ItemWithLocations>[];

  @override
  Future<Map<String, Object?>> exportBackup() async =>
      <String, Object?>{'app': 'home_inventory'};

  @override
  Future<void> restoreBackup(Map<String, Object?> data) async {}

  @override
  Future<List<Loan>> getAllLoans() async => List<Loan>.unmodifiable(loans);

  @override
  Future<void> returnLoan(int loanId,
      {int? quantity, int? toLocationId, int? returnedAt}) async {
    returnCalls.add((
      id: loanId,
      quantity: quantity,
      toLocationId: toLocationId,
      returnedAt: returnedAt,
    ));
    final idx = loans.indexWhere((l) => l.id == loanId);
    if (idx >= 0) {
      final old = loans[idx];
      final returned = quantity ?? (old.quantity - old.returnedQty);
      final total = old.returnedQty + returned;
      loans[idx] = Loan(
        id: old.id,
        itemId: old.itemId,
        itemName: old.itemName,
        borrowerName: old.borrowerName,
        quantity: old.quantity,
        returnedQty: total,
        borrowedAt: old.borrowedAt,
        dueAt: old.dueAt,
        returnedAt: total >= old.quantity ? (returnedAt ?? 1) : null,
        isPartial: total > 0 && total < old.quantity,
      );
    }
  }
}

/// 首页查询测试桩：借出状态查询文案的契约断言。
class _QueryRepo with FakeLoanMixin implements InventoryRepository {
  ItemWithLocations? found;
  QuantityInfo qty = const QuantityInfo(stock: 0, lent: 0, available: 0);
  List<Loan> activeLoans = const <Loan>[];
  final List<Loan> loans = <Loan>[];

  // 接口里 mixin 未覆盖的基础方法补空桩（查询链路用不到）。
  @override
  Future<void> updateItem(int id, String name) async {}
  @override
  Future<void> deleteItem(int id) async {}
  @override
  Future<List<ItemWithLocations>> getDeletedItems() async =>
      const <ItemWithLocations>[];
  @override
  Future<RestoreOutcome> restoreItem(int id) async => RestoreOutcome(
        itemName: '', merged: false,
      );
  @override
  Future<void> purgeItem(int id) async {}
  @override
  Future<void> purgeAll() async {}
  @override
  Future<void> updateLocation(int id, {String? name, String? remark}) async {}
  @override
  Future<void> deleteLocation(int id) async {}
  @override
  Future<UpsertResult> upsertItemLocation(String itemName, int locationId,
      {String? rawText, int? quantity, bool additive = false}) async {
    throw UnimplementedError('查询链路用不到');
  }

  @override
  Future<MoveResult> moveItem(String itemName, int locationId,
          {String? rawText}) async =>
      throw UnimplementedError('查询链路用不到');


  @override
  Future<ItemWithLocations?> findByName(String name) async => found;

  @override
  Future<List<ItemWithLocations>> getAllItemsWithLocations() async =>
      found == null ? const <ItemWithLocations>[] : <ItemWithLocations>[found!];

  @override
  Future<QuantityInfo> getQuantityInfo(String itemName) async => qty;

  @override
  Future<Map<int, QuantityInfo>> getAllQuantityInfo() async =>
      found?.item.id == null
          ? const <int, QuantityInfo>{}
          : <int, QuantityInfo>{found!.item.id!: qty};

  @override
  Future<List<Loan>> getActiveLoansForItem(String itemName) async =>
      activeLoans;

  @override
  Future<List<Loan>> getAllLoans() async => List<Loan>.unmodifiable(loans);

  @override
  Future<List<Location>> getAllLocations() async => const <Location>[];

  @override
  Future<int> addLocation(String name, {String? remark}) async => 1;

  @override
  Future<Map<String, Object?>> exportBackup() async =>
      <String, Object?>{'app': 'home_inventory'};

  @override
  Future<void> restoreBackup(Map<String, Object?> data) async {}
}

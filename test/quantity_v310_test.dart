// ignore_for_file: deprecated_member_use
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:home_inventory/home_inventory.dart';

import 'fake_loan_mixin.dart';

/// V3.10「数量打通」专属测试（PM 2026-11-24 拍板口径）。
///
/// 覆盖四块：
///  1. 解析器：数量口径（覆盖 / 累加）、物品名不被数量污染。
///  2. 数据层：在库口径（借出扣、归还加）、可借数、超借拦截、未录入拦截、
///     校准工具。
///  3. UI：语音录入数量落库、借出超量提示、明细页数量与「含已借出」筛选。
///  4. 校准页：按实物清点写回在库数。
///
/// 口径锚点（PM 拍板）：
///  ① 在库口径：借出扣库存，借空默认隐藏，「含已借出」筛选兜底。
///  ② 借超拦截：「家里只有N个，可借M个」，不允许负数。
///  ③ 普通「3个梯子」覆盖原数量；「再放N个/又多了N个」走累加。
///  ④ 未记录物品禁止直接借出，引导先录入。
///  ⑤ 抽屉增加「校准数量」工具。
///  ⑥ schema 保持 v8，不做物理迁移。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  // ==================== 1. 解析器 ====================

  group('V3.10 解析器：数量口径', () {
    test('「3个梯子放阳台」→ 数量 3、覆盖语义', () {
      final r = parsePhrase('3个梯子放阳台');
      expect(r, isA<ParseUpsert>());
      final u = r as ParseUpsert;
      expect(u.item, '梯子');
      expect(u.location, '阳台');
      expect(u.quantity, 3);
      expect(u.additive, isFalse, reason: 'PM 拍板③：普通说法 = 覆盖');
    });

    test('「放3个梯子在阳台」→ 数量 3（动词在前语序同样认）', () {
      final r = parsePhrase('放3个梯子在阳台') as ParseUpsert;
      expect(r.item, '梯子');
      expect(r.location, '阳台');
      expect(r.quantity, 3);
    });

    test('「再放2个梯子在阳台」→ 累加语义', () {
      final r = parsePhrase('再放2个梯子在阳台') as ParseUpsert;
      expect(r.quantity, 2);
      expect(r.additive, isTrue, reason: '「再」= 又添了');
      expect(r.location, '阳台');
    });

    test('「又多了2个梯子」→ 累加、只改数量不挪位', () {
      final r = parsePhrase('又多了2个梯子') as ParseUpsert;
      expect(r.item, '梯子');
      expect(r.quantity, 2);
      expect(r.additive, isTrue);
      expect(r.hasLocation, isFalse);
    });

    test('「再来1个梯子」→ 累加（口语变体）', () {
      final r = parsePhrase('再来1个梯子') as ParseUpsert;
      expect(r.item, '梯子');
      expect(r.quantity, 1);
      expect(r.additive, isTrue);
    });

    test('「3个梯子」→ 只带数量：纠正数量、不带位置', () {
      final r = parsePhrase('3个梯子') as ParseUpsert;
      expect(r.item, '梯子');
      expect(r.quantity, 3);
      expect(r.additive, isFalse);
      expect(r.hasLocation, isFalse);
    });

    test('「5号电池放阳台」→ 物品名干净，数量不污染名字', () {
      // V3.9.2 的教训：物品名被数量切坏后，按「电池」永远查不到它。
      final r = parsePhrase('5号电池放阳台') as ParseUpsert;
      expect(r.item, '5号电池');
      expect(r.quantity, 1, reason: '「5号」不是数量');
    });

    test('借出句里的数量不被录入抢答：「借给张三2个梯子」', () {
      final r = parsePhrase('借给张三2个梯子');
      expect(r, isA<ParseLend>());
      expect((r as ParseLend).quantity, 2);
    });

    test('归还句里的数量不被录入抢答：「还了1个梯子」', () {
      final r = parsePhrase('还了1个梯子');
      expect(r, isA<ParseReturn>());
      expect((r as ParseReturn).quantity, 1);
    });

    // PM 2026-11-25 真机复验打回：数量说在物品后面，物品名不能被污染。
    test('数量后置不污染物品名：「再放梯子3个在阳台」→ 梯子/3/累加', () {
      final r = parsePhrase('再放梯子3个在阳台');
      expect(r, isA<ParseUpsert>());
      final u = r as ParseUpsert;
      expect(u.item, '梯子');
      expect(u.location, '阳台');
      expect(u.quantity, 3);
      expect(u.additive, isTrue);
    });
    test('数量后置中文数字：「放梯子三个到阳台」→ 梯子/3', () {
      final u = parsePhrase('放梯子三个到阳台') as ParseUpsert;
      expect(u.item, '梯子');
      expect(u.quantity, 3);
      expect(u.additive, isFalse);
    });
    test('数量后置动词在中：「梯子三个放阳台」→ 梯子/3', () {
      final u = parsePhrase('梯子三个放阳台') as ParseUpsert;
      expect(u.item, '梯子');
      expect(u.quantity, 3);
    });

    // PM 2026-11-25 真机新增：查数量回三口径。
    test('「梯子有几个」→ 数量查询（不被位置查询/录入抢答）', () {
      expect(parsePhrase('梯子有几个'), isA<ParseQuantityQuery>());
      expect((parsePhrase('梯子有几个') as ParseQuantityQuery).item, '梯子');
    });
    test('「梯子还有几个」含「还」字也不被归还抢答', () {
      expect(parsePhrase('梯子还有几个'), isA<ParseQuantityQuery>());
    });
    test('查数量多说法：多少/一共几个/在借几个/有几个梯子/数量', () {
      for (final phrase in <String>[
        '梯子多少',
        '梯子一共几个',
        '梯子在借几个',
        '有几个梯子',
        '梯子数量',
      ]) {
        expect(parsePhrase(phrase), isA<ParseQuantityQuery>(),
            reason: '$phrase 应识别为查数量');
      }
    });
    test('查位置与归还/借出不受影响', () {
      expect(parsePhrase('梯子在哪'), isA<ParseQuery>());
      expect(parsePhrase('还了1个梯子'), isA<ParseReturn>());
      expect(parsePhrase('借给张三1个梯子'), isA<ParseLend>());
    });
    test('带「查：」前缀的数量查询也回三口径（元宝补充②）', () {
      final r = parsePhrase('查：梯子有几个');
      expect(r, isA<ParseQuantityQuery>());
      expect((r as ParseQuantityQuery).item, '梯子');
      expect(parsePhrase('查：梯子在哪'), isA<ParseQuery>());
    });
  });

  // ==================== 2. 数据层 ====================

  group('V3.10 数据层：在库口径', () {
    late Directory tempDir;
    late InventoryDatabase db;
    late List<InventoryDatabase> opened;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('home_inventory_v310_');
      opened = <InventoryDatabase>[];
      db = InventoryDatabase(
        databaseFactory: databaseFactoryFfi,
        databasePath: '${tempDir.path}/inventory.db',
        version: 8,
      );
      opened.add(db);
      await db.open();
    });

    tearDown(() async {
      for (final d in opened) {
        await d.close();
      }
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    Future<int> balcony() => db.addLocation('阳台');

    test('录入带数量 → 在库数 = 数量、可借数 = 在库数', () async {
      await db.upsertItemLocation('梯子', await balcony(), quantity: 3);
      final info = await db.getQuantityInfo('梯子');
      expect(info.stock, 3);
      expect(info.lent, 0);
      expect(info.available, 3);
    });

    test('借出扣在库数；可借数 = 在库数（不再把在借数减两遍）', () async {
      // 回归：V3.10 初版把「在借数」又从在库数里减了一次，
      // 「录 3 个借出 2 个」会算出可借 0 个——明明还剩 1 个却借不出去。
      await db.upsertItemLocation('梯子', await balcony(), quantity: 3);
      await db.lendItem('梯子', '张三', quantity: 2);
      final info = await db.getQuantityInfo('梯子');
      expect(info.stock, 1, reason: '借出 2 个扣掉 2 个');
      expect(info.lent, 2);
      expect(info.available, 1, reason: '可借数 = 在库数，不该再减在借数');
    });

    test('借出后还能把剩下的借走（不再被误拦）', () async {
      await db.upsertItemLocation('梯子', await balcony(), quantity: 3);
      await db.lendItem('梯子', '张三', quantity: 2);
      // 关键回归：还剩 1 个，应该借得出去。
      final second = await db.lendItem('梯子', '李四');
      expect(second.quantity, 1);
      final info = await db.getQuantityInfo('梯子');
      expect(info.stock, 0);
      expect(info.lent, 3);
      expect(info.available, 0);
    });

    test('借空后再借 → 拦截并给出中文提示（PM 拍板②）', () async {
      await db.upsertItemLocation('梯子', await balcony(), quantity: 1);
      await db.lendItem('梯子', '张三');
      await expectLater(
        db.lendItem('梯子', '李四'),
        throwsA(isA<ArgumentError>()),
      );
      try {
        await db.lendItem('梯子', '李四');
      } on ArgumentError catch (e) {
        expect(e.message.toString(), contains('可借'));
      }
    });

    test('借超 → 拦截，提示「家里只有N个，可借M个」', () async {
      await db.upsertItemLocation('梯子', await balcony(), quantity: 2);
      try {
        await db.lendItem('梯子', '张三', quantity: 3);
        fail('应当拦截借超');
      } on ArgumentError catch (e) {
        final msg = e.message.toString();
        expect(msg, contains('家里只有2个'));
        expect(msg, contains('可借2个'));
      }
    });

    test('未记录过的物品不能直接借出（PM 拍板④）', () async {
      try {
        await db.lendItem('梯子', '张三');
        fail('应当拦截未录入的物品');
      } on ArgumentError catch (e) {
        expect(e.message.toString(), contains('还没记录过'));
      }
    });

    test('归还加回在库数（与借出严格对称）', () async {
      await db.upsertItemLocation('梯子', await balcony(), quantity: 3);
      final loan = await db.lendItem('梯子', '张三', quantity: 2);
      expect((await db.getQuantityInfo('梯子')).stock, 1);
      await db.returnLoan(loan.id!, quantity: 1);
      expect((await db.getQuantityInfo('梯子')).stock, 2, reason: '还 1 个加回 1 个');
      await db.returnLoan(loan.id!);
      expect((await db.getQuantityInfo('梯子')).stock, 3, reason: '还清后回到 3 个');
    });

    test('覆盖语义：再录一次带数量 = 直接改写，不是累加', () async {
      await db.upsertItemLocation('梯子', await balcony(), quantity: 3);
      await db.upsertItemLocation('梯子', await balcony(), quantity: 5);
      expect((await db.getQuantityInfo('梯子')).stock, 5);
    });

    test('累加语义：additive = 在库数 += N', () async {
      await db.upsertItemLocation('梯子', await balcony(), quantity: 3);
      await db.upsertItemLocation('梯子', await balcony(), quantity: 2, additive: true);
      expect((await db.getQuantityInfo('梯子')).stock, 5);
    });

    test('setItemQuantity 只改数量、不动位置（不误删其他位置关联）', () async {
      final b = await balcony();
      final g = await db.addLocation('车库');
      await db.upsertItemLocation('梯子', b, quantity: 2);
      await db.upsertItemLocation('梯子', g, quantity: 2);
      final found = await db.findByName('梯子');
      expect(found!.locations.map((e) => e.name), containsAll(<String>['阳台', '车库']));

      final newStock = await db.setItemQuantity('梯子', 6);
      expect(newStock, 6);
      final after = await db.findByName('梯子');
      expect(after!.locations.map((e) => e.name), containsAll(<String>['阳台', '车库']),
          reason: '只改数量不该动位置关联');
    });

    test('setItemQuantity 对没记录过的物品抛 ArgumentError', () async {
      await expectLater(
        db.setItemQuantity('梯子', 3),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('getAllQuantityInfo 与单件口径一致', () async {
      await db.upsertItemLocation('梯子', await balcony(), quantity: 3);
      await db.upsertItemLocation('雨伞', await balcony(), quantity: 2);
      await db.lendItem('梯子', '张三', quantity: 2);
      final all = await db.getAllQuantityInfo();
      final one = await db.getQuantityInfo('梯子');
      final found = all.values.firstWhere((i) => i.stock == one.stock);
      expect(found.available, one.available);
      expect(found.lent, one.lent);
    });

    // PM 2026-11-25 真机新增 / 元宝审核补充③：挪位不重复建记录。
    test('同一物品换位置：明细仍 1 条，当前位置是新的', () async {
      final balconyId = await balcony();
      final livingRoom = await db.addLocation('客厅');
      await db.moveItem('梯子', balconyId);
      await db.moveItem('梯子', livingRoom);
      final rows = await db.getAllItemsWithLocations();
      expect(rows, hasLength(1), reason: '同一物品换位置不建第二条记录');
      expect(rows.first.item.name, '梯子');
      expect(rows.first.locations.map((l) => l.name), <String>['客厅'],
          reason: '当前位置只报新位置，旧关联软删留底');
    });

    // 元宝审核补充①：数据层双保险——脏名落库前被剥，不新建物品。
    test('数据层兜底：脏名「梯子3个」落库归一为「梯子」，不建第二条', () async {
      final balconyId = await balcony();
      await db.upsertItemLocation('梯子', balconyId, quantity: 1);
      // 模拟解析器漏剥的脏名直达仓储层。
      await db.upsertItemLocation('梯子3个', balconyId, quantity: 1, additive: true);
      final rows = await db.getAllItemsWithLocations();
      expect(rows, hasLength(1), reason: '脏名归一到同一物品，不会多一行');
      expect(rows.first.item.name, '梯子');
      expect((await db.getQuantityInfo('梯子')).stock, 2);
    });

    // -------- 校准工具（PM 拍板⑤） --------

    test('校准：按清点总数写回在库数 = 总数 − 在借数', () async {
      await db.upsertItemLocation('梯子', await balcony(), quantity: 1);
      await db.lendItem('梯子', '张三');
      final found = await db.findByName('梯子');
      final id = found!.item.id!;

      // 老库口径：账面 1 个，实际家里 3 个（1 个借出去了）。
      final report = await db.calibrateQuantities(totals: <int, int>{id: 3});
      expect(report.changedCount, 1);
      final info = await db.getQuantityInfo('梯子');
      expect(info.stock, 2, reason: '总数 3 − 在借 1 = 在库 2');
      expect(info.lent, 1);
    });

    test('校准幂等：同样的清点值反复校准，结果不变', () async {
      await db.upsertItemLocation('梯子', await balcony(), quantity: 1);
      await db.lendItem('梯子', '张三');
      final id = (await db.findByName('梯子'))!.item.id!;
      await db.calibrateQuantities(totals: <int, int>{id: 3});
      final second = await db.calibrateQuantities(totals: <int, int>{id: 3});
      expect(second.changedCount, 0, reason: '已经对齐就不该再改');
      expect((await db.getQuantityInfo('梯子')).stock, 2);
    });

    test('校准：清点总数比在借数还少 → 如实跳过，不写坏账', () async {
      await db.upsertItemLocation('梯子', await balcony(), quantity: 1);
      await db.lendItem('梯子', '张三');
      final id = (await db.findByName('梯子'))!.item.id!;
      final report = await db.calibrateQuantities(totals: <int, int>{id: 0});
      expect(report.changedCount, 0);
      expect(report.details.join(), contains('跳过'));
      expect((await db.getQuantityInfo('梯子')).stock, 0, reason: '账面没被动');
    });

    test('schema 仍是 v8（PM 拍板⑥：不做物理迁移）', () async {
      expect(db.version, 8);
    });
  });

  // ==================== 3. UI ====================

  group('V3.10 UI：数量贯通', () {
    late _FakeRepo repo;

    setUp(() {
      repo = _FakeRepo();
    });

    Future<void> pumpApp(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(home: HomePage(repository: repo)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
    }

    Future<void> submit(WidgetTester tester, String phrase) async {
      await tester.enterText(find.byKey(const Key('phrase_field')), phrase);
      await tester.pump();
      await tester.tap(find.byKey(const Key('submit_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
    }

    testWidgets('说「3个梯子放阳台」→ 数量 3 落库', (tester) async {
      await pumpApp(tester);
      await submit(tester, '3个梯子放阳台');
      final found = await repo.findByName('梯子');
      expect(found, isNotNull);
      expect(found!.item.quantity, 3);
    });

    testWidgets('说「又多了2个梯子」→ 在库数累加', (tester) async {
      await pumpApp(tester);
      await submit(tester, '3个梯子放阳台');
      await submit(tester, '又多了2个梯子');
      final found = await repo.findByName('梯子');
      expect(found!.item.quantity, 5);
    });

    testWidgets('说「3个梯子」→ 只改数量、不动位置', (tester) async {
      await pumpApp(tester);
      await submit(tester, '梯子放阳台');
      await submit(tester, '3个梯子');
      final found = await repo.findByName('梯子');
      expect(found!.item.quantity, 3);
      expect(found.locations.map((e) => e.name), contains('阳台'));
    });

    testWidgets('没记录过的物品不能直接借出，如实提示', (tester) async {
      await pumpApp(tester);
      await submit(tester, '借给张三1个梯子');
      expect(find.textContaining('还没记录过'), findsOneWidget);
      expect(await repo.getAllLoans(), isEmpty);
    });

    testWidgets('借超 → 提示「家里只有N个，可借M个」，不落账', (tester) async {
      await pumpApp(tester);
      await submit(tester, '2个梯子放阳台');
      await submit(tester, '借给张三5个梯子');
      expect(find.textContaining('家里只有2个'), findsOneWidget);
      expect(await repo.getAllLoans(), isEmpty, reason: '拦截时零写入');
    });

    // PM 2026-11-25 真机新增：查数量回三口径。
    testWidgets('「梯子有几个」回在库/在借/一共', (tester) async {
      await pumpApp(tester);
      await submit(tester, '3个梯子放阳台');
      await repo.lendItem('梯子', '张三', quantity: 1);
      await submit(tester, '梯子有几个');
      expect(find.textContaining('在库 2 个，在借 1 个，一共 3 个'), findsOneWidget);
    });
    testWidgets('没借出去时说一共，不说在借 0 个', (tester) async {
      await pumpApp(tester);
      await submit(tester, '2个梯子放阳台');
      await submit(tester, '梯子有几个');
      expect(find.textContaining('在库 2 个，没有借出去的，一共 2 个'), findsOneWidget);
    });
    testWidgets('没记录过的物品查数量 → 说没有记录，与没听懂分开', (tester) async {
      await pumpApp(tester);
      await submit(tester, '梯子有几个');
      expect(find.textContaining('暂未记录该物品'), findsOneWidget);
      expect(find.textContaining('没听懂'), findsNothing);
    });

    // PM 2026-11-25 真机打回：归还后弹窗问位置，不再默认原位置。
    testWidgets('归还后弹「放哪儿」，选已有位置即挪过去', (tester) async {
      final garage = await repo.addLocation('车库');
      await repo.upsertItemLocation('梯子', garage);
      await repo.lendItem('梯子', '张三');
      await pumpApp(tester);
      await submit(tester, '还了1个梯子');
      expect(find.byKey(const Key('return_location_dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('return_location_pick_车库')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.textContaining('已归还：梯子 → 张三'), findsOneWidget);
      expect(find.textContaining('在车库'), findsOneWidget);
    });
    testWidgets('归还弹窗点「先不改」→ 沿用原位置', (tester) async {
      final balcony = await repo.addLocation('阳台');
      await repo.upsertItemLocation('梯子', balcony);
      await repo.lendItem('梯子', '张三');
      await pumpApp(tester);
      await submit(tester, '还了1个梯子');
      expect(find.byKey(const Key('return_location_dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('return_location_skip')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.textContaining('在阳台'), findsOneWidget);
    });
  });

  // ==================== 4. 明细页 / 校准页 ====================

  group('V3.10 UI：明细页与校准页', () {
    testWidgets('借空的物品默认折叠，勾选「含已借出」才显示', (tester) async {
      final repo = _ListRepo(<ItemWithLocations>[
        _row('梯子', 3),
        _row('雨伞', 0),
      ]);
      await tester.pumpWidget(MaterialApp(home: ItemListPage(repository: repo)));
      await tester.pumpAndSettle();

      expect(find.textContaining('梯子'), findsOneWidget);
      expect(find.textContaining('雨伞'), findsNothing,
          reason: '借空（在库 0）的物品默认折叠');

      await tester.tap(find.text('含已借出'));
      await tester.pumpAndSettle();
      expect(find.textContaining('雨伞'), findsOneWidget,
          reason: '勾选后借空物品也要能看见');
    });

    testWidgets('明细页显示数量：×3、在借 1', (tester) async {
      final repo = _ListRepo(<ItemWithLocations>[
        _row('梯子', 2),
      ]);
      await tester.pumpWidget(MaterialApp(home: ItemListPage(repository: repo)));
      await tester.pumpAndSettle();
      expect(find.textContaining('梯子 ×2'), findsOneWidget);
    });

    testWidgets('校准页：按实物清点写回在库数 = 总数 − 在借数', (tester) async {
      final repo = _CalibRepo();
      await tester.pumpWidget(MaterialApp(home: CalibrationPage(repository: repo)));
      await tester.pumpAndSettle();

      // 账面 1 个、借出 1 个（李四）→ 用户清点「家里一共 3 个」。
      // V3.11：校准页多了一行实时合计，也带「在借 1 个」，断言锁定合计行本身。
      final sumFinder = find.byKey(const Key('calibration_sum_1'));
      expect(sumFinder, findsOneWidget);
      expect(tester.widget<Text>(sumFinder).data, contains('在借 1 个'));
      await tester.enterText(
        find.byKey(const Key('calibration_field_1_1')),
        '3',
      );
      await tester.tap(find.byKey(const Key('calibration_save')));
      await tester.pumpAndSettle();

      expect(repo.writtenTotals[1], 3, reason: '清点总数写回');
      expect(repo.savedStock, 2, reason: '在库数 = 总数 3 − 在借 1');
    });

    testWidgets('校准页：清点总数小于在借数 → 如实跳过，不写坏账', (tester) async {
      final repo = _CalibRepo();
      await tester.pumpWidget(MaterialApp(home: CalibrationPage(repository: repo)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('calibration_field_1_1')), '0');
      await tester.tap(find.byKey(const Key('calibration_save')));
      await tester.pumpAndSettle();
      expect(repo.savedStock, isNull, reason: '账打架时不该写');
    });
  });
}

/// 造一行明细（数量即在库数）。
ItemWithLocations _row(String name, int quantity) {
  return ItemWithLocations(
    item: Item(
      id: name.hashCode,
      name: name,
      createdAt: 1,
      updatedAt: 1,
      quantity: quantity,
    ),
    locations: <Location>[
      Location(id: 1, name: '阳台', createdAt: 1, updatedAt: 1),
    ],
  );
}

/// 明细页用的假仓储：数量取 `items.quantity`（在库数）。
class _ListRepo with FakeLoanMixin implements InventoryRepository {
  @override
  Future<int> addLocation(String name, {String? remark}) async => name.hashCode;

  @override
  Future<ItemWithLocations?> findByName(String name) async {
    for (final r in rows) {
      if (r.item.name == normalizeName(name)) return r;
    }
    return null;
  }

  @override
  Future<UpsertResult> upsertItemLocation(String itemName, int locationId,
      {String? rawText, int? quantity, bool additive = false}) async {
    throw UnimplementedError();
  }

  @override
  Future<MoveResult> moveItem(String itemName, int locationId,
      {String? rawText, int? quantity, bool additive = false}) async {
    throw UnimplementedError();
  }

  _ListRepo(this.rows);

  final List<ItemWithLocations> rows;

  @override
  Future<List<ItemWithLocations>> getAllItemsWithLocations() async =>
      List<ItemWithLocations>.unmodifiable(rows);

  @override
  Future<Map<int, QuantityInfo>> getAllQuantityInfo() async {
    final result = <int, QuantityInfo>{};
    for (final r in rows) {
      final id = r.item.id!;
      result[id] = QuantityInfo(
        stock: r.item.quantity,
        lent: 0,
        available: r.item.quantity,
      );
    }
    return result;
  }

  @override
  Future<void> updateItem(int id, String name) async {}

  @override
  Future<void> deleteItem(int id) async {}

  @override
  Future<List<ItemWithLocations>> getDeletedItems() async =>
      const <ItemWithLocations>[];

  @override
  Future<RestoreOutcome> restoreItem(int id) async =>
      const RestoreOutcome(itemName: '', merged: false);

  @override
  Future<void> purgeItem(int id) async {}

  @override
  Future<void> purgeAll() async {}

  @override
  Future<void> updateLocation(int id, {String? name, String? remark}) async {}

  @override
  Future<void> deleteLocation(int id) async {}

  @override
  Future<Map<String, Object?>> exportBackup() async => <String, Object?>{};

  @override
  Future<void> restoreBackup(Map<String, Object?> data) async {}

  @override
  Future<List<Location>> getAllLocations() async => const <Location>[];
}

/// 校准页用的假仓储：账面上 1 个梯子、1 个借给李四。
class _CalibRepo with FakeLoanMixin implements InventoryRepository {
  @override
  Future<int> addLocation(String name, {String? remark}) async => name.hashCode;

  @override
  Future<ItemWithLocations?> findByName(String name) async {
    final rows = await getAllItemsWithLocations();
    for (final r in rows) {
      if (r.item.name == normalizeName(name)) return r;
    }
    return null;
  }

  @override
  Future<UpsertResult> upsertItemLocation(String itemName, int locationId,
      {String? rawText, int? quantity, bool additive = false}) async {
    throw UnimplementedError();
  }

  @override
  Future<MoveResult> moveItem(String itemName, int locationId,
      {String? rawText, int? quantity, bool additive = false}) async {
    throw UnimplementedError();
  }

  final Map<int, int> writtenTotals = <int, int>{};
  int? savedStock;

  @override
  Future<List<ItemWithLocations>> getAllItemsWithLocations() async {
    return <ItemWithLocations>[
      ItemWithLocations(
        item: Item(
            id: 1, name: '梯子', createdAt: 1, updatedAt: 1, quantity: 1),
        locations: <Location>[
          Location(id: 1, name: '阳台', createdAt: 1, updatedAt: 1),
        ],
      ),
    ];
  }

  @override
  Future<Map<int, QuantityInfo>> getAllQuantityInfo() async => <int, QuantityInfo>{
        1: const QuantityInfo(stock: 1, lent: 1, available: 1),
      };

  @override
  Future<List<Loan>> getAllLoans() async => <Loan>[
        Loan(
          id: 1,
          itemId: 1,
          itemName: '梯子',
          borrowerName: '李四',
          quantity: 1,
          borrowedAt: 1,
          dueAt: 1,
        ),
      ];

  @override
  Future<CalibrationReport> calibrateQuantities({
    Map<int, int> totals = const <int, int>{},
    Map<int, Map<int, int>> locationTotals = const <int, Map<int, int>>{},
  }) async {
    // V3.11：校准页按位置填数，假仓储同样把各位置加总成「家里一共几个」，
    // 否则新页面传 locationTotals 过来会被旧假仓储静默丢掉。
    final mappedTotals = <int, int>{
      for (final e in locationTotals.entries)
        e.key: e.value.values.fold<int>(0, (a, b) => a + b),
    };
    final effective = mappedTotals.isNotEmpty ? mappedTotals : totals;
    writtenTotals.addAll(effective);
    const lent = 1;
    var changed = 0;
    final details = <String>[];
    for (final e in effective.entries) {
      if (e.value < lent) {
        details.add('梯子：清点 ${e.value} 个，比在借的 $lent 个还少，已跳过');
        continue;
      }
      savedStock = e.value - lent;
      changed++;
      details.add('梯子：共 ${e.value} 个 − 在借 $lent 个 → 在库 $savedStock 个');
    }
    return CalibrationReport(changedCount: changed, details: details);
  }

  @override
  Future<void> updateItem(int id, String name) async {}

  @override
  Future<void> deleteItem(int id) async {}

  @override
  Future<List<ItemWithLocations>> getDeletedItems() async =>
      const <ItemWithLocations>[];

  @override
  Future<RestoreOutcome> restoreItem(int id) async =>
      const RestoreOutcome(itemName: '', merged: false);

  @override
  Future<void> purgeItem(int id) async {}

  @override
  Future<void> purgeAll() async {}

  @override
  Future<void> updateLocation(int id, {String? name, String? remark}) async {}

  @override
  Future<void> deleteLocation(int id) async {}

  @override
  Future<Map<String, Object?>> exportBackup() async => <String, Object?>{};

  @override
  Future<void> restoreBackup(Map<String, Object?> data) async {}

  @override
  Future<List<Location>> getAllLocations() async => const <Location>[];
}

/// UI 测试用的内存假仓储：数量语义与生产一致（借出扣、归还加）。
class _FakeRepo with FakeLoanMixin implements InventoryRepository {
  final Map<String, int> _items = <String, int>{};
  final Map<String, List<String>> _locations = <String, List<String>>{};
  final List<Loan> _loans = <Loan>[];
  int _loanId = 0;

  // 与本组测试无关的接口一律空实现（`implements` 不继承默认实现，必须显式补）。
  @override
  Future<void> updateItem(int id, String name) async {}

  @override
  Future<void> deleteItem(int id) async {}

  @override
  Future<List<ItemWithLocations>> getDeletedItems() async =>
      const <ItemWithLocations>[];

  @override
  Future<RestoreOutcome> restoreItem(int id) async =>
      const RestoreOutcome(itemName: '', merged: false);

  @override
  Future<void> purgeItem(int id) async {}

  @override
  Future<void> purgeAll() async {}

  @override
  Future<void> updateLocation(int id, {String? name, String? remark}) async {}

  @override
  Future<void> deleteLocation(int id) async {}

  @override
  Future<Map<String, Object?>> exportBackup() async => <String, Object?>{};

  @override
  Future<void> restoreBackup(Map<String, Object?> data) async {}

  @override
  Future<List<Location>> getAllLocations() async => _locNames.entries
      .map((e) => Location(id: e.key, name: e.value, createdAt: 1, updatedAt: 1))
      .toList();

  @override
  Future<List<ItemWithLocations>> getAllItemsWithLocations() async {
    return _items.keys.map((name) {
      final locs = (_locations[name] ?? const <String>[])
          .map((l) => Location(
                id: l.hashCode, name: l, createdAt: 1, updatedAt: 1))
          .toList();
      return ItemWithLocations(
        item: Item(id: name.hashCode, name: name, createdAt: 1, updatedAt: 1,
            quantity: _items[name] ?? 1),
        locations: locs,
      );
    }).toList();
  }

  @override
  Future<ItemWithLocations?> findByName(String name) async {
    final key = normalizeName(name);
    if (!_items.containsKey(key)) return null;
    final locs = (_locations[key] ?? const <String>[])
        .map((l) =>
            Location(id: l.hashCode, name: l, createdAt: 1, updatedAt: 1))
        .toList();
    return ItemWithLocations(
      item: Item(id: key.hashCode, name: key, createdAt: 1, updatedAt: 1,
          quantity: _items[key] ?? 1),
      locations: locs,
    );
  }

  /// 位置 id → 名称（生产里位置是独立表，这里用 id 反查名字）。
  final Map<int, String> _locNames = <int, String>{};

  @override
  Future<int> addLocation(String name, {String? remark}) async {
    final id = name.hashCode;
    _locNames[id] = name;
    return id;
  }

  @override
  Future<UpsertResult> upsertItemLocation(String itemName, int locationId,
      {String? rawText, int? quantity, bool additive = false}) async {
    final key = normalizeName(itemName);
    final cur = _items[key] ?? 1;
    final newQty = additive ? cur + (quantity ?? 0) : (quantity ?? cur);
    _items[key] = newQty;
    final locName = _locNames[locationId] ?? '位置$locationId';
    final locs = _locations.putIfAbsent(key, () => <String>[]);
    if (!locs.contains(locName)) locs.add(locName);
    return UpsertResult(itemId: key.hashCode, locationId: locationId, created: true);
  }

  @override
  Future<MoveResult> moveItem(String itemName, int locationId,
      {String? rawText, int? quantity, bool additive = false}) async {
    final key = normalizeName(itemName);
    final cur = _items[key] ?? 1;
    final newQty = additive ? cur + (quantity ?? 0) : (quantity ?? cur);
    _items[key] = newQty;
    final locName = _locNames[locationId] ?? '位置$locationId';
    _locations[key] = <String>[locName];
    return MoveResult(
      itemId: key.hashCode,
      locationId: locationId,
      created: true,
      previousLocations: const <String>[],
      quantity: newQty,
      quantityChanged: true,
    );
  }

  /// V3.11：UI 的无数量录入走整体挪，假仓储复用原 moveItem 落库语义。
  @override
  Future<MoveResult> moveItemWhole(String itemName, int toLocationId,
      {String? rawText}) =>
      moveItem(itemName, toLocationId, rawText: rawText);

  @override
  Future<int> setItemQuantity(String itemName, int quantity,
      {bool additive = false}) async {
    final key = normalizeName(itemName);
    if (!_items.containsKey(key)) {
      throw ArgumentError.value(key, 'itemName', '还没记录过「$key」');
    }
    final cur = _items[key] ?? 1;
    _items[key] = additive ? cur + quantity : quantity;
    return _items[key]!;
  }

  @override
  Future<QuantityInfo> getQuantityInfo(String itemName) async {
    final key = normalizeName(itemName);
    final stock = _items[key] ?? 0;
    final lent = _loans
        .where((l) => l.itemName == key)
        .fold<int>(0, (s, l) => s + (l.quantity - l.returnedQty));
    return QuantityInfo(stock: stock, lent: lent, available: stock);
  }

  @override
  Future<Map<int, QuantityInfo>> getAllQuantityInfo() async =>
      const <int, QuantityInfo>{};

  @override
  Future<CalibrationReport> calibrateQuantities({
    Map<int, int> totals = const <int, int>{},
    Map<int, Map<int, int>> locationTotals = const <int, Map<int, int>>{},
  }) async =>
      const CalibrationReport(changedCount: 0);

  @override
  Future<Loan> lendItem(String itemName, String borrowerName,
      {int quantity = 1, int? days, int? fromLocationId}) async {
    final key = normalizeName(itemName);
    final stock = _items[key];
    if (stock == null) {
      throw ArgumentError.value(key, 'itemName', '还没记录过「$key」');
    }
    if (quantity > stock) {
      throw ArgumentError.value(quantity, 'quantity', '家里只有$stock个「$key」，可借$stock个');
    }
    _items[key] = stock - quantity;
    final loan = Loan(
      id: ++_loanId,
      itemId: key.hashCode,
      itemName: key,
      borrowerName: normalizeName(borrowerName),
      quantity: quantity,
      borrowedAt: 1,
      dueAt: 1 + (days ?? 3) * 86400000,
    );
    _loans.add(loan);
    return loan;
  }

  @override
  Future<void> returnLoan(int loanId,
      {int? quantity, int? toLocationId, int? returnedAt}) async {}

  @override
  Future<List<Loan>> getAllLoans() async => List<Loan>.unmodifiable(_loans);
}

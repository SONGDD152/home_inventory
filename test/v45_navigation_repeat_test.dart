// ignore_for_file: deprecated_member_use
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:home_inventory/data/domain.dart';
import 'package:home_inventory/data/inventory_database.dart';
import 'package:home_inventory/data/reminder.dart';
import 'package:home_inventory/data/todo_state.dart';
import 'package:home_inventory/domain/overview_reader.dart';
import 'package:home_inventory/domain/reminder_source.dart';
import 'package:home_inventory/domain/reminder_sources.dart';
import 'package:home_inventory/domain/repeat_rule.dart';
import 'package:home_inventory/domain/todo_agenda.dart';
import 'package:home_inventory/domain/todo_state_writer.dart';
import 'package:home_inventory/ui/home_module.dart';
import 'package:home_inventory/ui/overview_page.dart';

import 'fake_domain_repository.dart';

/// V4.1 批次 4 专项测试：**导航调整 + 裁定②甲方案（重复规则展开）**。
///
/// ## 批次 4 范围（PM 既定 5 项 + 元宝裁定②增量）
/// ① 生活区底栏 5 → 4 模块（「日程」删掉）；
/// ② 日程上移概览层（旧 `schedule_page.dart` 随之删除，无入口即孤儿页）；
/// ③ 概览页底栏改双签（从顶部 TabBar 移到**页面底部**）；
/// ④ 旧测试改断言保行数（461 旧一条不删）；
/// ⑤ 工作区单按钮底栏视觉优化；
/// ⑥ **裁定②甲方案**：重复规则「完成后自动新建下一实例、保留历史」。
///
/// ## 裁定②甲方案的三个关键口径
/// - **落点在数据层**：概览的日报签与日程签两处勾选**都走 `markDone`**，
///   展开挂数据层两签天然同源（挂 UI 层要改两处、必然漂移）；
/// - **幂等**：同一条提醒重复完成只建一个下一实例；
/// - **撤销不回收**：排期不回滚（用户已经看到过这一期）。
///
/// ## 连带的口径修正（配套）
/// 保留历史实例后，历史实例的原到期日在过去 → 会**天天挂在催办区里**。
/// 所以 [TodoAgenda] 加了第 ⓪ 条（已完成且不是当天处理的 → 不进该日催办区）。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late Directory tempDir;
  late List<InventoryDatabase> opened;

  InventoryDatabase newDb({String name = 'inventory.db'}) {
    final instance = InventoryDatabase(
      databaseFactory: databaseFactoryFfi,
      databasePath: p.join(tempDir.path, name),
      version: 13,
      domain:
          name.startsWith('work') ? InventoryDomain.work : InventoryDomain.life,
    );
    opened.add(instance);
    return instance;
  }

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('v45_nav_repeat');
    opened = <InventoryDatabase>[];
  });

  tearDown(() {
    for (final db in opened) {
      db.close();
    }
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  // ═══════════════ 裁定②甲方案 · 周期推进纯函数 ═══════════════

  group('裁定②甲方案：周期推进纯函数（唯一实现）', () {
    test('daily / weekly / monthly / yearly 各推一个周期', () {
      final base = DateTime(2026, 3, 10, 8, 30);
      expect(RepeatRule.advance(base, RepeatRule.daily),
          DateTime(2026, 3, 11, 8, 30));
      expect(RepeatRule.advance(base, RepeatRule.weekly),
          DateTime(2026, 3, 17, 8, 30));
      expect(RepeatRule.advance(base, RepeatRule.monthly),
          DateTime(2026, 4, 10, 8, 30));
      expect(RepeatRule.advance(base, RepeatRule.yearly),
          DateTime(2027, 3, 10, 8, 30));
    });

    test('不重复 / 非法规则 → null（不推进）', () {
      final base = DateTime(2026, 3, 10);
      expect(RepeatRule.advance(base, null), isNull);
      expect(RepeatRule.advance(base, 'fortnightly'), isNull);
      expect(RepeatRule.advance(base, ''), isNull);
    });

    test('月末 clamp：1/31 + monthly → 2/28（该月最后一天）', () {
      expect(
        RepeatRule.advance(DateTime(2026, 1, 31, 9), RepeatRule.monthly),
        DateTime(2026, 2, 28, 9),
        reason: '2 月没有 31 日 → 落到该月最后一天',
      );
    });

    test('闰年 clamp：2024/2/29 + yearly → 2025/2/28', () {
      expect(
        RepeatRule.advance(DateTime(2024, 2, 29, 9), RepeatRule.yearly),
        DateTime(2025, 2, 28, 9),
      );
    });

    test('跨年推进：12 月 + monthly → 次年 1 月', () {
      expect(
        RepeatRule.advance(DateTime(2026, 12, 15, 9), RepeatRule.monthly),
        DateTime(2027, 1, 15, 9),
      );
    });
  });

  // ═══════════════ 裁定②甲方案：数据层展开 ═══════════════

  group('裁定②甲方案：完成后自动新建下一实例（保留历史）', () {
    test('完成带重复规则的日程 → 新建下一实例，旧实例保留为历史', () async {
      final db = newDb();
      final due = DateTime(2026, 3, 1, 8);
      final id = await db.addReminder('倒垃圾',
          dueAt: due,
          repeatRule: RepeatRule.daily,
          priority: ReminderPriority.high);

      await db.markDone(TodoSourceType.scheduleReminder, id);

      final items = await db.getReminders();
      expect(items, hasLength(2), reason: '旧实例保留 + 新建下一实例 = 2 行');

      // 旧实例原样保留（历史留着才有得捞）。
      final old = items.firstWhere((r) => r.id == id);
      expect(old.title, '倒垃圾');
      expect(old.dueAt, due.millisecondsSinceEpoch);
      expect(old.repeatRule, RepeatRule.daily);

      // 下一实例：到期日 = 原到期日 + 一个周期，其余字段全部继承。
      final next = items.firstWhere((r) => r.id != id);
      expect(next.title, '倒垃圾');
      expect(next.dueAt, DateTime(2026, 3, 2, 8).millisecondsSinceEpoch);
      expect(next.repeatRule, RepeatRule.daily);
      expect(next.priority, ReminderPriority.high);
      expect(next.detail, isNull);
      expect(next.status, 'pending', reason: '下一实例是待办');
    });

    test('下一实例继承标题 / 备注 / 优先级', () async {
      final db = newDb();
      final id = await db.addReminder('交电费',
          detail: '电费单在抽屉第二格',
          dueAt: DateTime(2026, 3, 1, 9),
          repeatRule: RepeatRule.monthly,
          priority: ReminderPriority.low);

      await db.markDone(TodoSourceType.scheduleReminder, id);

      final items = await db.getReminders();
      final next = items.firstWhere((r) => r.id != id);
      expect(next.title, '交电费');
      expect(next.detail, '电费单在抽屉第二格');
      expect(next.priority, ReminderPriority.low);
      expect(next.dueAt, DateTime(2026, 4, 1, 9).millisecondsSinceEpoch);
    });

    test('幂等：完成 → 撤销 → 再完成，下一实例只建一个', () async {
      final db = newDb();
      final id = await db.addReminder('倒垃圾',
          dueAt: DateTime(2026, 3, 1, 8), repeatRule: RepeatRule.daily);

      await db.markDone(TodoSourceType.scheduleReminder, id);
      expect(await db.getReminders(), hasLength(2));

      // 撤销完成。
      await db.markDone(TodoSourceType.scheduleReminder, id, done: false);
      expect(await db.getReminders(), hasLength(2),
          reason: '撤销**不回收**下一实例（排期不回滚）');

      // 再完成 → 幂等查重命中 → 不会多建。
      await db.markDone(TodoSourceType.scheduleReminder, id);
      expect(await db.getReminders(), hasLength(2),
          reason: '重复完成只建一个下一实例');
    });

    test('不重复的日程完成 → 不新建下一实例', () async {
      final db = newDb();
      final id = await db.addReminder('一次性交电费',
          dueAt: DateTime(2026, 3, 1, 8));
      await db.markDone(TodoSourceType.scheduleReminder, id);
      expect(await db.getReminders(), hasLength(1));
    });

    test('无期限提醒完成 → 不新建下一实例（没有下一期的基准）', () async {
      final db = newDb();
      final id = await db.addReminder('随时想想',
          repeatRule: RepeatRule.daily);
      await db.markDone(TodoSourceType.scheduleReminder, id);
      expect(await db.getReminders(), hasLength(1));
    });

    test('系统类（借出到期）完成 → 不新建提醒', () async {
      final db = newDb();
      final locationId = await db.addLocation('阳台');
      await db.upsertItemLocation('梯子', locationId, quantity: 1);
      final loan = await db.lendItem('梯子', '张三', quantity: 1, days: 3);

      await db.markDone(TodoSourceType.loanDue, loan.id!);

      expect(await db.getReminders(), isEmpty,
          reason: '系统类没有重复规则，不该凭空长出提醒');
    });

    test('setReminderDone 路径同样展开（口径唯一，不挑入口）', () async {
      final db = newDb();
      final id = await db.addReminder('倒垃圾',
          dueAt: DateTime(2026, 3, 1, 8), repeatRule: RepeatRule.weekly);
      await db.setReminderDone(id);
      final items = await db.getReminders();
      expect(items, hasLength(2));
      expect(items.firstWhere((r) => r.id != id).dueAt,
          DateTime(2026, 3, 8, 8).millisecondsSinceEpoch);
    });

    test('展开只写 reminders 表，仓储账一个数不动', () async {
      final db = newDb();
      final locationId = await db.addLocation('阳台');
      await db.upsertItemLocation('梯子', locationId, quantity: 2);
      final loan = await db.lendItem('梯子', '张三', quantity: 1, days: 3);
      final loansBefore = await db.getAllLoans();
      final itemsBefore = await db.getAllItems();

      final id = await db.addReminder('倒垃圾',
          dueAt: DateTime(2026, 3, 1, 8), repeatRule: RepeatRule.daily);
      await db.markDone(TodoSourceType.scheduleReminder, id);

      expect((await db.getAllLoans()).length, loansBefore.length);
      expect((await db.getAllItems()).length, itemsBefore.length);
      expect(loan.id, isNotNull);
    });

    test('物理分库：生活域展开不写工作域的库', () async {
      final life = newDb(name: 'inventory.db');
      final work = newDb(name: 'work_inventory.db');

      final id = await life.addReminder('倒垃圾',
          dueAt: DateTime(2026, 3, 1, 8), repeatRule: RepeatRule.daily);
      await life.markDone(TodoSourceType.scheduleReminder, id);

      expect(await life.getReminders(), hasLength(2));
      expect(await work.getReminders(), isEmpty,
          reason: '下一实例只落在本域那张 reminders 表里');
    });

    test('展开后下一实例会出现在日程源里（界面能看见）', () async {
      final db = newDb();
      final id = await db.addReminder('倒垃圾',
          dueAt: DateTime(2026, 3, 1, 8), repeatRule: RepeatRule.daily);
      await db.markDone(TodoSourceType.scheduleReminder, id);

      final source = ScheduleReminderSource(db, InventoryDomain.life);
      final entries = await source.loadEntries();
      expect(entries, hasLength(2), reason: '旧实例 + 下一实例');
      expect(entries.map((e) => e.sourceId).toSet(), hasLength(2));
    });
  });

  // ═══════════════ 源码级锁：展开口径只在数据层、只写 reminders ═══════════════

  group('源码级锁：展开逻辑的位置与写边界', () {
    /// 剥掉注释行（与 v41 / v43 / v44 同一口径）——
    /// 锁要证明的是「**代码里**没有那条路」，不是「文档里不许提那些词」。
    String codeOnly(String path) {
      final file = File(path);
      expect(file.existsSync(), isTrue, reason: '$path 不存在');
      final out = <String>[];
      for (final line in file.readAsStringSync().split('\n')) {
        final t = line.trim();
        if (t.startsWith('///') || t.startsWith('//') || t.startsWith('*')) {
          continue;
        }
        out.add(line);
      }
      return out.join('\n');
    }

    test('锁①：概览区两个文件都不含展开逻辑（口径只在数据层一份）', () {
      for (final path in const <String>[
        'lib/ui/overview_page.dart',
        'lib/ui/schedule_tab_view.dart',
      ]) {
        final src = codeOnly(path);
        expect(src.contains('_expandRepeatingReminder'), isFalse,
            reason: '$path 不该自己实现展开——两签同源靠的是数据层那一份');
        expect(src.contains('RepeatRule.advance'), isFalse,
            reason: '$path 不该自己算周期——周期推进是唯一实现（domain 层）');
      }
    });

    test('锁②：展开方法只碰 reminders 表，不碰 items / loans / locations', () {
      final src = codeOnly('lib/data/inventory_database.dart');
      final start = src.indexOf('Future<void> _expandRepeatingReminder');
      expect(start, greaterThan(-1), reason: '展开方法应存在');
      // 方法体 = 从声明到下一个顶层方法声明为止。
      final next = src.indexOf('\n  Future<', start + 10);
      final body = src.substring(start, next == -1 ? src.length : next);
      expect(body, contains('tableReminders'),
          reason: '展开要写 reminders 表（下一实例）');
      for (final bad in const <String>[
        'tableItems',
        'tableLocations',
        'tableItemLocations',
        'tableLoans',
        'tableBorrowers',
      ]) {
        expect(body.contains(bad), isFalse,
            reason: '展开是日程系统的事，不该碰仓储账的 $bad');
      }
    });

    test('锁③：周期推进只有一份实现（domain 层纯函数）', () {
      final src = codeOnly('lib/domain/repeat_rule.dart');
      expect(src.contains('static DateTime? advance'), isTrue,
          reason: '周期推进的唯一实现在 domain/repeat_rule.dart');
      // 别处**不得再定义**一份推进算法（调用 `RepeatRule.advance` 是允许的）。
      for (final path in const <String>[
        'lib/data/inventory_database.dart',
        'lib/ui/overview_page.dart',
        'lib/ui/schedule_tab_view.dart',
      ]) {
        final other = codeOnly(path);
        expect(other.contains('DateTime? advance('), isFalse,
            reason: '$path 不该再定义一份周期推进（会与 domain 层漂移）');
      }
    });
  });

  // ═══════════════ 配套口径：历史已完成不进催办区 ═══════════════

  group('配套口径⓪：已完成且不是当天处理的 → 不进该日催办区', () {
    final today = DateTime(2026, 3, 10);
    final yesterday = DateTime(2026, 3, 9, 20);

    test('昨天完成的 → 今天不进催办区（历史实例不天天挂着）', () {
      expect(
        TodoAgenda.isInAgenda(
          sourceDueAt: yesterday.millisecondsSinceEpoch,
          nextDueAt: null,
          doneAt: yesterday.millisecondsSinceEpoch,
          date: today,
        ),
        isFalse,
      );
    });

    test('今天完成的 → 今天仍然进催办区（日报要看今天做完了什么）', () {
      final doneToday = DateTime(2026, 3, 10, 9);
      expect(
        TodoAgenda.isInAgenda(
          sourceDueAt: yesterday.millisecondsSinceEpoch,
          nextDueAt: null,
          doneAt: doneToday.millisecondsSinceEpoch,
          date: today,
        ),
        isTrue,
      );
    });

    test('未完成的历史条目 → 仍然进（逾期留置规则不变）', () {
      expect(
        TodoAgenda.isInAgenda(
          sourceDueAt: yesterday.millisecondsSinceEpoch,
          nextDueAt: null,
          doneAt: null,
          date: today,
        ),
        isTrue,
      );
    });

    test('从没处理过的条目 → 判定与改动前完全一致', () {
      expect(
        TodoAgenda.isInAgenda(
          sourceDueAt: DateTime(2026, 3, 20).millisecondsSinceEpoch,
          nextDueAt: null,
          doneAt: null,
          leadDays: 0,
          date: today,
        ),
        isFalse,
        reason: '到期日在未来且不提前 → 不进',
      );
    });
  });

  // ═══════════════ 批次 4 ①②：导航调整（底栏 5→4 / 日程上移） ═══════════════

  group('批次 4①②：生活区底栏 5→4，日程上移概览层', () {
    test('生活区模块注册表 = 4 项，不再有「日程」', () {
      final modules = modulesOf(InventoryDomain.life);
      expect(modules, hasLength(4));
      expect(modules.map((m) => m.label).toList(),
          <String>['仓储', '知识库', '餐饮', '衣橱']);
      expect(modules.any((m) => m.label == '日程'), isFalse);
    });

    test('工作区模块注册表 = 1 项（单按钮底栏）', () {
      final modules = modulesOf(InventoryDomain.work);
      expect(modules, hasLength(1));
      expect(modules.first.label, '工作仓储');
    });

    test('旧 SchedulePage 已删除（无入口即孤儿页）', () {
      expect(File('lib/ui/schedule_page.dart').existsSync(), isFalse);
      expect(File('lib/ui/schedule_tab_view.dart').existsSync(), isTrue,
          reason: '日程签的新家在概览层');
    });
  });

  // ═══════════════ 批次 4③：概览页底栏双签 ═══════════════

  testWidgets('批次4③：概览页双签在**页面底部**（不是顶部）', (tester) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final life = FakeDomainRepository();
    final work = FakeDomainRepository();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: OverviewPage(
          reader: InventoryOverviewReader(life: life, work: work),
          sources: <ReminderSource>[
            ScheduleReminderSource(life, InventoryDomain.life),
          ],
          todoWriters: <InventoryDomain, TodoStateWriter>{
            InventoryDomain.life: life,
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 双签存在，且 key 一字不变（批次 2/3 已交付专项靠它点）。
    expect(find.byKey(const Key('overview_tabs')), findsOneWidget);
    expect(find.byKey(const Key('overview_tab_report')), findsOneWidget);
    expect(find.byKey(const Key('overview_tab_schedule')), findsOneWidget);

    // 位置：必须在页面**下半部**——批次 1/2 做成了顶部 TabBar，
    // PM 拍板是「概览页底栏改双签」，这条断言就是锁住那次修正。
    final tabsY = tester.getTopLeft(find.byKey(const Key('overview_tabs'))).dy;
    expect(tabsY, greaterThan(2000 * 0.6),
        reason: '双签在页面底部（当前 dy=$tabsY）');
  });

  // ═══════════════ 批次 4④：日程签「隐藏已完成」开关 ═══════════════

  testWidgets('批次4④：日程签「隐藏已完成」开关可折叠历史实例',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final life = FakeDomainRepository();
    final work = FakeDomainRepository();
    final now = DateTime.now();
    await life.addReminder('倒垃圾',
        dueAt: DateTime(now.year, now.month, now.day - 1, 9));
    await life.addReminder('交电费',
        dueAt: DateTime(now.year, now.month, now.day + 1, 9));
    // 第一条标记完成（模拟甲方案留下的历史实例）。
    await life.markDone(TodoSourceType.scheduleReminder, 1);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: OverviewPage(
          reader: InventoryOverviewReader(life: life, work: work),
          sources: <ReminderSource>[
            ScheduleReminderSource(life, InventoryDomain.life),
          ],
          todoWriters: <InventoryDomain, TodoStateWriter>{
            InventoryDomain.life: life,
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('overview_tab_schedule')));
    await tester.pumpAndSettle();

    // 默认：已完成的历史实例**照旧显示**（批次 3 既有行为一个字没改）。
    expect(find.byKey(const Key('schedule_entry_reminder_life_1')),
        findsOneWidget);
    expect(find.byKey(const Key('schedule_entry_reminder_life_2')),
        findsOneWidget);
    expect(find.byKey(const Key('schedule_toggle_done')), findsOneWidget);

    // 点开关 → 已完成那条收起，未完成那条留着。
    await tester.tap(find.byKey(const Key('schedule_toggle_done')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('schedule_entry_reminder_life_1')), findsNothing,
        reason: '历史实例被开关收起了');
    expect(find.byKey(const Key('schedule_entry_reminder_life_2')),
        findsOneWidget,
        reason: '未完成的当期日程不受影响');

    // 再点 → 收起的回来了（历史没丢）。
    await tester.tap(find.byKey(const Key('schedule_toggle_done')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('schedule_entry_reminder_life_1')),
        findsOneWidget);
  });
}

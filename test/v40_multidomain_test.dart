// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:home_inventory/data/daily_report_service.dart';
import 'package:home_inventory/data/domain.dart';
import 'package:home_inventory/data/inventory_database.dart';
import 'package:home_inventory/data/phrase_parser.dart';
import 'package:home_inventory/data/reminder_repository.dart';
import 'package:home_inventory/data/report_state_store.dart';
import 'package:home_inventory/domain/domain_hub.dart';
import 'package:home_inventory/domain/overview_reader.dart';
import 'package:home_inventory/domain/reminder_sources.dart';
import 'package:home_inventory/ui/home_page.dart';

import 'fake_domain_repository.dart';

/// V4.0 多域架构（物理分库）专项测试。
///
/// 元宝第三轮测试红线：**461 条旧测试一条不删**（本文件是**新增**专项，
/// 与旧测试同批跑）；以下专项全部必过，不是「有时间再做」。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late Directory tempDir;
  late List<InventoryDatabase> opened;

  InventoryDatabase newDb({String name = 'inventory.db', int version = 11}) {
    final instance = InventoryDatabase(
      databaseFactory: databaseFactoryFfi,
      databasePath: p.join(tempDir.path, name),
      version: version,
      domain: name.startsWith('work') ? InventoryDomain.work : InventoryDomain.life,
    );
    opened.add(instance);
    return instance;
  }

  /// 造一个位置并放一件物品（位置必须先存在，upsert 才认 locationId）。
  Future<void> seed(InventoryDatabase db, String item, int qty) async {
    final locationId = await db.addLocation('主位置');
    await db.upsertItemLocation(item, locationId, quantity: qty);
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('home_inventory_v40_');
    opened = <InventoryDatabase>[];
  });

  tearDown(() async {
    for (final instance in opened) {
      await instance.close();
    }
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  // ============ 一、双库隔离 ============

  test('V4.0 双库隔离：两本账各写各的，同名互不可见', () async {
    final life = newDb(name: 'life.db');
    final work = newDb(name: 'work.db');

    await seed(life, '梯子', 1);
    await seed(work, '梯子', 3);

    final lifeItems = await life.getAllItemsWithLocations();
    final workItems = await work.getAllItemsWithLocations();
    expect(lifeItems.length, 1);
    expect(workItems.length, 1);

    final lifeQty = await life.getQuantityInfo('梯子');
    final workQty = await work.getQuantityInfo('梯子');
    expect(lifeQty.stock, 1, reason: '生活库的梯子还是 1 个');
    expect(workQty.stock, 3, reason: '工作库的梯子是 3 个，两本账互不影响');

    // 两库文件确实是不同路径（物理分库，不是逻辑过滤）。
    expect(life.domain, InventoryDomain.life);
    expect(work.domain, InventoryDomain.work);
    expect(life.domain.fileName, 'home_inventory.db');
    expect(work.domain.fileName, 'work_inventory.db');
  });

  test('V4.1 工作库首建：九表齐全（与生活库 v12 结构一致）', () async {
    final work = newDb(name: 'work.db');
    await work.open();
    final db = await work.open();
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    );
    final names = rows.map((r) => r['name'] as String).toSet();
    for (final expected in <String>[
      'items',
      'locations',
      'item_locations',
      'item_discards',
      'borrowers',
      'loans',
      'reminders',
      'daily_reports',
      // V4.1：第 9 张表——催办条目状态的唯一权威源。
      'todo_states',
    ]) {
      expect(names.contains(expected), isTrue, reason: '工作库应含表 $expected');
    }
    expect(names.length, 9, reason: 'v12 共 9 张表');
  });

  test('V4.0 迁移：生活库 v10→v11 数据零丢失、幂等', () async {
    final legacy = newDb(name: 'life.db', version: 10);
    await legacy.open();
    final legacyLocation = await legacy.addLocation('主位置');
    await legacy.upsertItemLocation('梯子', legacyLocation, quantity: 2);
    final before = await legacy.getAllItemsWithLocations();
    expect(before.length, 1);
    await legacy.close();

    // 用 v11 打开同一个文件 → 触发 v10→v11 迁移。
    final upgraded = newDb(name: 'life.db', version: 11);
    await upgraded.open();
    final after = await upgraded.getAllItemsWithLocations();
    expect(after.length, 1, reason: '迁移不丢物品');
    expect((await upgraded.getQuantityInfo('梯子')).stock, 2,
        reason: '迁移不丢数量');

    // 幂等：再开一次不再改动。
    await upgraded.close();
    final again = newDb(name: 'life.db', version: 11);
    await again.open();
    expect((await again.getQuantityInfo('梯子')).stock, 2);
  });

  // ============ 二、备份分域 ============

  test('V4.0 备份隔离：生活备份恢复进工作库被拒绝', () async {
    final life = newDb(name: 'life.db');
    final work = newDb(name: 'work.db');
    await seed(life, '梯子', 1);
    final backup = await life.exportBackup();
    expect(backup['domain'], 'life', reason: '备份带域标识');

    Object? caught;
    try {
      await work.restoreBackup(backup);
    } catch (e) {
      caught = e;
    }
    expect(caught, isA<ArgumentError>());
    expect((caught as ArgumentError).message.toString(),
        contains('这是生活区的备份，不能恢复到工作区'));
    expect((await work.getAllItemsWithLocations()).length, 0,
        reason: '被拒绝后工作库一个字节都没变');
  });

  test('V4.0 备份隔离：旧备份（无域标识）归生活库，工作库拒收', () async {
    final life = newDb(name: 'life.db');
    final work = newDb(name: 'work.db');
    await seed(life, '梯子', 1);
    final backup = await life.exportBackup();
    backup.remove('domain'); // 模拟 V3.x 老备份。

    // 恢复到生活库：正常。
    await life.restoreBackup(backup);
    expect((await life.getAllItemsWithLocations()).length, 1);

    // 恢复到工作库：拒绝，并说清只能回生活区。
    Object? caught;
    try {
      await work.restoreBackup(backup);
    } catch (e) {
      caught = e;
    }
    expect(caught, isA<ArgumentError>());
    expect((caught as ArgumentError).message.toString(), contains('只能恢复到生活区'));
  });

  test('V4.0 备份：工作库导出的备份带 work 标识，生活库拒收', () async {
    final life = newDb(name: 'life.db');
    final work = newDb(name: 'work.db');
    await seed(work, '投影仪', 1);
    final backup = await work.exportBackup();
    expect(backup['domain'], 'work');

    Object? caught;
    try {
      await life.restoreBackup(backup);
    } catch (e) {
      caught = e;
    }
    expect(caught, isA<ArgumentError>());
    expect((caught as ArgumentError).message.toString(),
        contains('这是工作区的备份，不能恢复到生活区'));
  });

  // ============ 三、切库守卫 ============

  test('V4.0 切库守卫：切换期间写操作直接拒绝', () async {
    final life = newDb(name: 'life.db');
    final work = newDb(name: 'work.db');
    final hub = DomainHub(
      life: life,
      work: work,
      switchTimeout: const Duration(milliseconds: 200),
    );

    final pending = Completer<void>();
    final hold = life.trackOperation(() => pending.future);
    final switching = hub.switchTo(InventoryDomain.work);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    Object? caught;
    try {
      await life.addLocation('阳台');
    } catch (e) {
      caught = e;
    }
    expect(caught, isA<DomainSwitchInProgress>(),
        reason: '切换期间写必须被拒绝，不静默重试');

    pending.complete();
    await hold;
    await switching;
    expect(hub.currentDomain, InventoryDomain.work);
  });

  test('V4.0 切库守卫：超时置脏 + 超时次数可见 + 下次切域重建连接',
      () async {
    final life = newDb(name: 'life.db');
    final work = newDb(name: 'work.db');
    await seed(life, '梯子', 1);
    final hub = DomainHub(
      life: life,
      work: work,
      switchTimeout: const Duration(milliseconds: 100),
    );

    // 制造一次超时：旧域有操作迟迟不收尾。
    final pending = Completer<void>();
    final hold = life.trackOperation(() => pending.future);
    await hub.switchTo(InventoryDomain.work);
    expect(hub.switchTimeoutCount, 1, reason: '超时次数用户可见');
    expect(hub.isDirty, isTrue, reason: '超时后连接状态置脏');

    pending.complete();
    await hold;

    // 下次切域前强制重建连接；重建后数据仍在（没有脏数据）。
    await hub.switchTo(InventoryDomain.life);
    expect(hub.isDirty, isFalse);
    final items = await life.getAllItemsWithLocations();
    expect(items.length, 1, reason: '重建连接后数据完好');
  });

  // ============ 四、语音域路由 ============

  test('V4.0 语音域路由：域前缀命中即带域标识', () {
    final envelope = parsePhraseEnvelope('工作区放梯子在书房');
    expect(envelope.targetDomain, InventoryDomain.work);
    expect(envelope.payload, isA<ParseUpsert>());
    final upsert = envelope.payload as ParseUpsert;
    expect(upsert.item, '梯子');
    expect(upsert.location, '书房');
  });

  test('V4.0 语音域路由：含域词但不是指令 → 按原句走，不吞句', () {
    final envelope = parsePhraseEnvelope('公司团建要用的投影仪');
    expect(envelope.targetDomain, isNull,
        reason: '剥前缀后解析不出合法意图 → 按原句走，不当域指令');
  });

  test('V4.0 语音域路由：无域前缀时目标域为空（落当前域）', () {
    final envelope = parsePhraseEnvelope('梯子放阳台');
    expect(envelope.targetDomain, isNull);
    expect(envelope.payload, isA<ParseUpsert>());
  });

  test('V4.0 提醒意图：「提醒我明天交周报」认得出标题与日期', () {
    final result = parsePhrase('提醒我明天交周报');
    expect(result, isA<ParseReminderAdd>());
    final reminder = result as ParseReminderAdd;
    expect(reminder.title, '交周报');
    expect(reminder.dueAt, isNotNull);
    expect(reminder.dueAt!.isAfter(DateTime.now()), isTrue);
  });

  test('V4.0 提醒意图：生活区的「提醒我…」不触发工作区', () {
    final result = parsePhrase('提醒我买牛奶');
    expect(result, isA<ParseReminderAdd>());
  });

  // ============ 五、概览（只读聚合） ============

  test('V4.0 概览：两域数字各自独立、守恒口径逐域成立', () async {
    final life = newDb(name: 'life.db');
    final work = newDb(name: 'work.db');
    await seed(life, '梯子', 2);
    await seed(work, '投影仪', 5);

    final reader = InventoryOverviewReader(life: life, work: work);
    final lifeSnapshot = await reader.read(InventoryDomain.life);
    final workSnapshot = await reader.read(InventoryDomain.work);

    expect(lifeSnapshot.itemCount, 1);
    expect(lifeSnapshot.stock, 2);
    expect(workSnapshot.itemCount, 1);
    expect(workSnapshot.stock, 5);
    expect(lifeSnapshot.isBalanced, isTrue);
    expect(workSnapshot.isBalanced, isTrue);
    expect(lifeSnapshot.totalOwned, 2);
    expect(workSnapshot.totalOwned, 5);
  });

  test('V4.0 概览：提醒源统一接口，借出到期能出条目', () async {
    final life = newDb(name: 'life.db');
    await seed(life, '梯子', 1);
    await life.lendItem('梯子', '张三', quantity: 1);
    final source = LoanDueReminderSource(life, InventoryDomain.life);
    final entries = await source.loadEntries();
    expect(entries.length, 1);
    expect(entries.first.title, contains('梯子'));
  });

  // ============ 六、日报 ============

  test('V4.0 日报：每日一次判据（同日重复调用不重复生成）', () async {
    final life = newDb(name: 'life.db');
    final work = newDb(name: 'work.db');
    final store = InMemoryReportStateStore();
    final service = DailyReportService(
      storage: life,
      reminders: life,
      overview: InventoryOverviewReader(life: life, work: work),
      stateStore: store,
    );
    final now = DateTime(2026, 11, 26, 10, 30);

    final first = await service.ensureYesterdayReport(now: now);
    expect(first, isTrue, reason: '第一次应补生成');
    final second = await service.ensureYesterdayReport(now: now);
    expect(second, isFalse, reason: '同一天只生成一次');

    final key = DailyReportService.formatDate(DateTime(2026, 11, 25));
    final report = await life.getDailyReport(key);
    expect(report, isNotNull);
  });

  test('V4.0 日报：系统时间回拨到已处理过的日期不重复补生成', () async {
    final life = newDb(name: 'life.db');
    final work = newDb(name: 'work.db');
    final store = InMemoryReportStateStore();
    final service = DailyReportService(
      storage: life,
      reminders: life,
      overview: InventoryOverviewReader(life: life, work: work),
      stateStore: store,
    );

    await service.ensureYesterdayReport(now: DateTime(2026, 11, 26, 10));
    // 时间被调回前一天：昨天 = 11-24（未处理过），应补生成 11-24。
    final back = await service.ensureYesterdayReport(now: DateTime(2026, 11, 25, 9));
    expect(back, isTrue);
    // 再调回 11-26：昨天 = 11-25，已处理过 → 不重复生成。
    final again = await service.ensureYesterdayReport(now: DateTime(2026, 11, 26, 8));
    expect(again, isFalse, reason: '时间回拨不得造成重复补生成');
  });

  test('V4.0 日报：内容三块（提醒 / 仓储动态 / 账目快照）', () async {
    final life = newDb(name: 'life.db');
    final work = newDb(name: 'work.db');
    await seed(life, '梯子', 1);
    final service = DailyReportService(
      storage: life,
      reminders: life,
      overview: InventoryOverviewReader(life: life, work: work),
    );
    final content = await service.buildContent(DateTime(2026, 11, 25));
    expect(content, contains('提醒清单'));
    expect(content, contains('仓储动态'));
    expect(content, contains('账目快照'));
    expect(content, contains('生活区'));
    expect(content, contains('工作区'));
  });

  test('V4.0 日报导出：docx 是合法 ZIP 包且含正文', () async {
    final life = newDb(name: 'life.db');
    final work = newDb(name: 'work.db');
    final service = DailyReportService(
      storage: life,
      reminders: life,
      overview: InventoryOverviewReader(life: life, work: work),
    );
    final bytes = await service.buildDocx(DateTime(2026, 11, 25));
    expect(bytes.length, greaterThan(100));
    // ZIP 头。
    expect(bytes[0], 0x50);
    expect(bytes[1], 0x4B);
    expect(bytes[2], 0x03);
    expect(bytes[3], 0x04);
    // 包内条目名（文件名是 ASCII 的，document.xml 必在）。
    final text = utf8.decode(bytes.toList(), allowMalformed: true);
    expect(text, contains('word/document.xml'));
    expect(text, contains('[Content_Types].xml'));
    // 正文中文（UTF-8 字节序列）能在包里检索到。
    expect(text, contains('家庭仓储日报'));
  });

  test('V4.0 提醒：增删改与完成状态流转', () async {
    final life = newDb(name: 'life.db');
    final ReminderRepository repo = life;
    final id = await repo.addReminder('交周报',
        dueAt: DateTime(2026, 11, 26, 9), detail: '周五前');
    var items = await repo.getReminders();
    expect(items.length, 1);
    expect(items.first.title, '交周报');
    expect(items.first.isPending, isTrue);

    await repo.setReminderDone(id);
    items = await repo.getReminders();
    expect(items.first.isDone, isTrue);
    expect(items.first.doneAt, isNotNull);

    await repo.updateReminder(id, title: '交月报');
    items = await repo.getReminders();
    expect(items.first.title, '交月报');

    await repo.deleteReminder(id);
    items = await repo.getReminders();
    expect(items, isEmpty);
  });

  // ============ 七、导航（widget） ============

  testWidgets('V4.0 导航：顶栏三选一 + 概览隐藏底栏 + 底栏按域渲染',
      (tester) async {
    final domains = fakeDomains();
    final hub = DomainHub(life: domains.life, work: domains.work);

    await tester.pumpWidget(MaterialApp(
      home: HomePage(repository: domains.life.repository, hub: hub),
    ));
    await tester.pumpAndSettle();

    // 顶栏三选一。
    expect(find.byKey(const Key('top_section_switch')), findsOneWidget);
    expect(find.text('概览'), findsOneWidget);
    expect(find.text('生活'), findsOneWidget);
    expect(find.text('工作'), findsOneWidget);

    // 生活区底栏五项固定全显示。
    final nav = tester.widget<BottomNavigationBar>(
      find.byKey(const Key('home_bottom_nav')),
    );
    expect(nav.items.length, 5);
    expect(nav.items[0].label, '仓储');
    expect(nav.items[4].label, '衣橱');

    // 切到工作区：底栏按需长出（本轮只有工作仓储）。
    // Flutter 的 BottomNavigationBar 要求至少两项 → 单模块域用单按钮底栏。
    await tester.tap(find.text('工作'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home_bottom_nav')), findsNothing);
    expect(find.byKey(const Key('home_bottom_nav_single')), findsOneWidget);
    expect(find.text('工作仓储'), findsOneWidget);
    expect(hub.currentDomain, InventoryDomain.work);

    // 切到概览：底栏隐藏（PM 拍板）。
    await tester.tap(find.text('概览'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home_bottom_nav')), findsNothing);
    expect(find.byKey(const Key('overview_page')), findsOneWidget);
  });

  testWidgets('V4.0 语音：跨域落库落目标账，界面不切域', (tester) async {
    final domains = fakeDomains();
    final hub = DomainHub(life: domains.life, work: domains.work);

    await tester.pumpWidget(MaterialApp(
      home: HomePage(repository: domains.life.repository, hub: hub),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const Key('phrase_field')), '工作区放梯子在书房');
    await tester.pump();
    // 提交按钮在屏幕下方：先滚到可见再点（不滚动会点空）。
    await tester.ensureVisible(find.byKey(const Key('submit_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('submit_button')));
    await tester.pumpAndSettle();

    // 落工作库。
    expect((await domains.work.repository.getAllItemsWithLocations()).length, 1);
    expect((await domains.life.repository.getAllItemsWithLocations()).length, 0,
        reason: '生活库不该有这条记录');
    // 界面不切域（仍在生活区）。
    expect(hub.currentDomain, InventoryDomain.life);
  });

  testWidgets('V4.0 语音：工作区不支持提醒 → 报错并给引导按钮', (tester) async {
    final domains = fakeDomains();
    final hub = DomainHub(life: domains.life, work: domains.work);

    await tester.pumpWidget(MaterialApp(
      home: HomePage(repository: domains.life.repository, hub: hub),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const Key('phrase_field')), '工作区提醒我明天交周报');
    await tester.pump();
    // 提交按钮在屏幕下方：先滚到可见再点（不滚动会点空）。
    await tester.ensureVisible(find.byKey(const Key('submit_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('submit_button')));
    await tester.pumpAndSettle();

    // 引导弹窗（不是静默记到生活库）。
    expect(find.byKey(const Key('cross_domain_dialog')), findsOneWidget);
    expect(find.textContaining('工作区暂不支持提醒'), findsOneWidget);
    final lifeReminders = domains.life.repository as ReminderRepository;
    final workReminders = domains.work.repository as ReminderRepository;
    expect((await lifeReminders.getReminders()).length, 0,
        reason: '没落库前不能有任何写入');
    expect((await workReminders.getReminders()).length, 0);

    // 点【切换到生活区】→ 切域 + 预填该条提醒。
    await tester.tap(find.byKey(const Key('cross_domain_switch')));
    await tester.pumpAndSettle();
    expect(hub.currentDomain, InventoryDomain.life);
    final field = tester.widget<TextField>(find.byKey(const Key('phrase_field')));
    expect(field.controller!.text, contains('提醒我'));
  });
}

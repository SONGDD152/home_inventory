// ignore_for_file: deprecated_member_use
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:home_inventory/data/domain.dart';
import 'package:home_inventory/data/reminder.dart';
import 'package:home_inventory/data/todo_state.dart';
import 'package:home_inventory/domain/overview_reader.dart';
import 'package:home_inventory/domain/reminder_source.dart';
import 'package:home_inventory/domain/reminder_sources.dart';
import 'package:home_inventory/domain/todo_state_writer.dart';
import 'package:home_inventory/ui/overview_page.dart';

import 'fake_domain_repository.dart';

/// 造一个「借出到期」源的**测试桩**。
///
/// ## 为什么不直接用 `lendItem`
///
/// `FakeDomainRepository.lendItem` 抛 `UnimplementedError`、
/// `getAllLoans()` 返回空——共享 fake 不实现借出。
/// **改共享 fake 会动到 613 条旧测试的地基**，不值得。
/// 这里用一个最小 stub 直接提供「到期条目」，测的正是
/// **催办区的分组结构**，不需要真的走借出流程。
class _StubLoanDueSource implements ReminderSource {
  const _StubLoanDueSource(this.domain, this.entries);

  /// 本桩所属的域（`ReminderSource` 接口本身**没有** `domain` 成员，
  /// 所以这里不能加 `@override` —— 加了 analyzer 会报
  /// `override_on_non-overriding_member`）。
  final InventoryDomain domain;

  /// 该源提供的条目（测试自己造）。
  final List<OverviewEntry> entries;

  /// 源 id 带 `loan_due_` 前缀 → `isSystemHint` 为真（借出到期用箱子图标），
  /// 但**不与真实源的 `loan_due_life` 撞 id**（撞了会重复 key 崩页）。
  @override
  String get id => 'loan_due_stub_${domain.id}';

  @override
  String get displayName => '${domain.label}·仓储借出到期';

  @override
  Future<List<OverviewEntry>> loadEntries() async => entries;
}

/// V4.1.1 **整改 3 + 整改 4** 专项。
///
/// ## 整改 3：新建提醒必选区域（分区破口）
///
/// PM 2026-11-27 真机手点：新建的提醒**一律带「生活」标签**，
/// 工作区**无入口可选**——用户没法把提醒放进工作那本账。
///
/// 修法：
/// - 新建表单加**区域二选一**（生活区 / 工作区），**不选不能存**；
/// - **去掉默认落区**（不预选，逼用户明确表态）；
/// - 打开工作域的提醒能力开关（`domainCapabilities`）。
///
/// 回归：**工作区新建 → 仅工作区催办可见，生活区查不到。**
///
/// ## 整改 4：催办只分两块（PM 拍板）
///
/// 催办列表**只按区域分成两块**——生活区、工作区。
/// **不拆四块、不设三级分类、不设子标签、不设额外筛选。**
/// 同一区域里，到期与提醒**混在一起**（用图标区分类型）。
///
/// 回归：**催办块数恒为 2**，且块标题就是区域名。
void main() {
  /// 泵一个概览页（两域 fake + 两个提醒源）。
  Future<void> pumpOverview(
    WidgetTester tester, {
    required FakeDomainRepository life,
    required FakeDomainRepository work,
    Set<InventoryDomain> editable = const <InventoryDomain>{},
    Future<void> Function(InventoryDomain domain, dynamic draft)?
        onCreateReminder,
    List<ReminderSource>? extraSources,
  }) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: OverviewPage(
          reader: InventoryOverviewReader(life: life, work: work),
          sources: <ReminderSource>[
            LoanDueReminderSource(life, InventoryDomain.life),
            LoanDueReminderSource(work, InventoryDomain.work),
            ScheduleReminderSource(life, InventoryDomain.life),
            ScheduleReminderSource(work, InventoryDomain.work),
            ...?extraSources,
          ],
          todoWriters: <InventoryDomain, TodoStateWriter>{
            InventoryDomain.life: life,
            InventoryDomain.work: work,
          },
          editableScheduleDomains: editable,
          onCreateReminder: onCreateReminder == null
              ? null
              : (domain, draft) => onCreateReminder(domain, draft),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  // ─────────────────────── 整改 3 ───────────────────────

  testWidgets('整改3：新建提醒时必须选区域，不选不能存', (tester) async {
    final life = FakeDomainRepository();
    final work = FakeDomainRepository();

    await pumpOverview(tester,
        life: life,
        work: work,
        editable: const <InventoryDomain>{
          InventoryDomain.life,
          InventoryDomain.work,
        },
        onCreateReminder: (domain, draft) async {
          final target = domain == InventoryDomain.life ? life : work;
          await target.addReminder(draft.title, dueAt: draft.dueAt);
        });

    await tester.tap(find.byKey(const Key('overview_tab_schedule')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('schedule_add')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reminder_edit_dialog')), findsOneWidget);

    // 区域二选一都在。
    expect(find.byKey(const Key('reminder_domain_life')), findsOneWidget);
    expect(find.byKey(const Key('reminder_domain_work')), findsOneWidget);

    // **默认不预选**（整改 3：去掉默认落区）。
    final lifeChip =
        tester.widget<ChoiceChip>(find.byKey(const Key('reminder_domain_life')));
    final workChip =
        tester.widget<ChoiceChip>(find.byKey(const Key('reminder_domain_work')));
    expect(lifeChip.selected, isFalse, reason: '不能默认落生活区');
    expect(workChip.selected, isFalse, reason: '不能默认落工作区');

    // 填了标题但**没选区域** → 「保存」按钮不可用（不能存）。
    await tester.enterText(
        find.byKey(const Key('reminder_title_field')), '要存的提醒');
    await tester.pump();
    final save = tester.widget<TextButton>(
        find.byKey(const Key('reminder_save')));
    expect(save.onPressed, isNull,
        reason: '整改3：没选区域时不能存');
    expect(find.byKey(const Key('reminder_domain_hint')), findsOneWidget);

    // 选了工作区 → 可以存了。
    await tester.tap(find.byKey(const Key('reminder_domain_work')));
    await tester.pump();
    final save2 = tester.widget<TextButton>(
        find.byKey(const Key('reminder_save')));
    expect(save2.onPressed, isNotNull,
        reason: '选了区域后必须能存');
  }, timeout: const Timeout(Duration(seconds: 90)));

  testWidgets('整改3：工作区新建 → 仅工作区催办可见，生活区查不到',
      (tester) async {
    final life = FakeDomainRepository();
    final work = FakeDomainRepository();

    await pumpOverview(tester,
        life: life,
        work: work,
        editable: const <InventoryDomain>{
          InventoryDomain.life,
          InventoryDomain.work,
        },
        onCreateReminder: (domain, draft) async {
          final target = domain == InventoryDomain.life ? life : work;
          await target.addReminder(draft.title, dueAt: draft.dueAt);
        });

    await tester.tap(find.byKey(const Key('overview_tab_schedule')));
    await tester.pumpAndSettle();

    // 在**工作区**建一条提醒（**带到期日**——没到期日的提醒不进催办区）。
    await tester.tap(find.byKey(const Key('schedule_add')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('reminder_title_field')), '交周报');
    await tester.pump();
    // 选日期（弹窗里的「选日期」按钮）。
    await tester.tap(find.byKey(const Key('reminder_due_pick')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reminder_domain_work')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('reminder_save')));
    await tester.pumpAndSettle();

    // **落库分域**：工作库有、生活库没有。
    expect((await work.getReminders()).length, 1,
        reason: '整改3：应落工作库');
    expect((await life.getReminders()).length, 0,
        reason: '整改3：生活区查不到这条');

    // 催办区：**只在工作区块里可见**。
    await tester.tap(find.byKey(const Key('overview_tab_report')));
    await tester.pumpAndSettle();
    final workBlock = find.byKey(const Key('overview_block_work'));
    expect(workBlock, findsOneWidget);
    expect(
      find.descendant(of: workBlock, matching: find.text('交周报')),
      findsOneWidget,
      reason: '整改3：工作区催办必须可见',
    );
    // 生活区块里没有这条（生活库压根没有这条数据）。
    final lifeBlockEntries = find.descendant(
      of: find.byKey(const Key('overview_block_life')),
      matching: find.text('交周报'),
    );
    expect(lifeBlockEntries, findsNothing,
        reason: '整改3：生活区催办里不该出现工作区那条');
  }, timeout: const Timeout(Duration(seconds: 90)));

  testWidgets('整改3：编辑既有提醒不显示区域选择（不改归属）', (tester) async {
    final life = FakeDomainRepository();
    final work = FakeDomainRepository();
    await life.addReminder('已存在的提醒', dueAt: DateTime.now());

    // **开放生活域的日程编辑**——否则时间轴上不渲染编辑按钮。
    await pumpOverview(tester,
        life: life,
        work: work,
        editable: const <InventoryDomain>{InventoryDomain.life});

    await tester.tap(find.byKey(const Key('overview_tab_schedule')));
    await tester.pumpAndSettle();

    // 点编辑 → 弹窗里**不该**有区域选择（一条提醒已属于某本账）。
    // 条目 id 带域（`reminder_life_1`），编辑按钮的 key 是
    // `schedule_edit_<条目id>`。
    await tester.tap(find.byKey(const Key('schedule_edit_reminder_life_1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reminder_edit_dialog')), findsOneWidget);
    expect(find.byKey(const Key('reminder_domain_life')), findsNothing,
        reason: '编辑既有提醒不改归属，不给区域选择');
  }, timeout: const Timeout(Duration(seconds: 90)));

  // ─────────────────────── 整改 4 ───────────────────────

  testWidgets('整改4：催办块数恒为 2（生活区 / 工作区）', (tester) async {
    final life = FakeDomainRepository();
    final work = FakeDomainRepository();
    // 两个域、两类事项（借出到期 + 日程提醒）都在。
    await life.addReminder('生活区的日程', dueAt: DateTime.now());
    await work.addReminder('工作区的日程', dueAt: DateTime.now());

    await pumpOverview(tester, life: life, work: work);

    // 块数恒为 2。
    expect(find.byKey(const Key('overview_block_life')), findsOneWidget);
    expect(find.byKey(const Key('overview_block_work')), findsOneWidget);

    // **不得**出现按源拆的四块（旧结构）。
    for (final old in const <String>[
      'overview_group_loan_due_life',
      'overview_group_loan_due_work',
      'overview_group_schedule_reminders_life',
      'overview_group_schedule_reminders_work',
    ]) {
      expect(find.byKey(Key(old)), findsNothing,
          reason: '整改4：不得再按源拆块（$old）');
    }
  }, timeout: const Timeout(Duration(seconds: 90)));

  testWidgets('整改4：块内混合到期与提醒，块标题就是区域名', (tester) async {
    final life = FakeDomainRepository();
    final work = FakeDomainRepository();
    // 生活区：一条借出到期 + 一条日程提醒。
    await life.addReminder('生活区的日程', dueAt: DateTime.now());
    final now = DateTime.now();
    final loanStub = _StubLoanDueSource(
      InventoryDomain.life,
      <OverviewEntry>[
        OverviewEntry(
          id: 'loan_life_1',
          title: '梯子（借给张三）',
          subtitle: '借出 2026-11-20 · 预期 3 天 · 今天到期',
          dueAt: now.millisecondsSinceEpoch,
          domain: InventoryDomain.life,
          sourceType: TodoSourceType.loanDue,
          sourceId: 1,
          priority: ReminderPriority.high,
        ),
      ],
    );

    await pumpOverview(tester,
        life: life, work: work, extraSources: <ReminderSource>[loanStub]);

    // 块标题是**区域名**，不是「生活区·某某」。
    expect(find.text('生活区'), findsOneWidget);
    expect(find.text('工作区'), findsOneWidget);
    expect(find.text('生活区·仓储借出到期'), findsNothing,
        reason: '整改4：不得再出现三级分类标题');
    expect(find.text('生活区·日程提醒'), findsNothing,
        reason: '整改4：不得再出现三级分类标题');

    // **块内混合**：借出到期与日程提醒都在生活区块里。
    final lifeBlock = find.byKey(const Key('overview_block_life'));
    expect(
      find.descendant(
          of: lifeBlock, matching: find.textContaining('梯子')),
      findsWidgets,
      reason: '整改4：借出到期要在生活区块里',
    );
    expect(
      find.descendant(
          of: lifeBlock, matching: find.text('生活区的日程')),
      findsWidgets,
      reason: '整改4：日程提醒也要在同一块里',
    );
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('整改4：代码注释写明「催办块数恒为 2」（源码级）', () {
    // 结构性口径要落到**代码注释**里（不是只在测试里断言）——
    // 将来改结构的人一眼能看到这条铁律。
    final src =
        File('lib/ui/overview_page.dart').readAsStringSync();
    expect(src, contains('恒为 2'),
        reason: '整改4：代码注释必须写明催办块数恒为 2');
    expect(src, contains('overview_block_'),
        reason: '整改4：块 key 前缀必须是 overview_block_');
  });
}

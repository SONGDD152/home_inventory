// ignore_for_file: deprecated_member_use
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:home_inventory/data/domain.dart';
import 'package:home_inventory/domain/overview_reader.dart';
import 'package:home_inventory/domain/reminder_source.dart';
import 'package:home_inventory/domain/reminder_sources.dart';
import 'package:home_inventory/domain/todo_state_writer.dart';
import 'package:home_inventory/ui/overview_page.dart';

import 'fake_domain_repository.dart';

/// V4.1.2 真机复验整改专项：日报签 = **两个独立滚动框，各滑各的**。
///
/// ## 产品口径（元宝 2026-11-27 需求澄清，PM 转发确认）
///
/// 「像聊天框一样滑动」= 生活区 / 工作区各是一个独立滚动容器：
/// 在生活区块内上滑只翻生活区条目、在工作区块内上滑只翻工作区条目，
/// 两框互不带动、各有滚动边界；**不是整页统一滚到底**。
///
/// ## 为什么旧实现不通过真机
///
/// 原来日报签整页一个 `ListView` 包住两块 → 一屏装不下时只滚整页，
/// 工作区 3 条被截在屏外拖不到。本专项锁死「两框各自能滚、互不带动」。
///
/// ## 判据：量位移（`ScrollableState.position.pixels`）
///
/// 跟 v47 一致——不以「第 N 条不可见」判（ListView 只 build 可见条目），
/// 只看拖动前后 scrollOffset 是否变化。
void main() {
  Future<void> seed(
    FakeDomainRepository repo,
    String prefix,
    int count,
  ) async {
    final now = DateTime.now();
    for (var i = 1; i <= count; i++) {
      await repo.addReminder('$prefix$i',
          dueAt: DateTime(now.year, now.month, now.day, 9, i));
    }
  }

  Future<void> pump(
    WidgetTester tester,
    FakeDomainRepository life,
    FakeDomainRepository work,
  ) async {
    // 真机逻辑 360×640（物理 1080×1920 ÷ dpr 3.0）。
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: OverviewPage(
          reader: InventoryOverviewReader(life: life, work: work),
          sources: <ReminderSource>[
            ScheduleReminderSource(life, InventoryDomain.life),
            ScheduleReminderSource(work, InventoryDomain.work),
          ],
          todoWriters: <InventoryDomain, TodoStateWriter>{
            InventoryDomain.life: life,
            InventoryDomain.work: work,
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  double offsetOf(WidgetTester tester, String domainId) {
    final scrollable = find.descendant(
      of: find.byKey(Key('overview_block_list_$domainId')),
      matching: find.byType(Scrollable),
    );
    final state = tester.state<ScrollableState>(scrollable.first);
    return state.position.pixels;
  }

  testWidgets('V4.1.2：日报签两框各自可滚、拖生活区框不带动工作区框',
      (tester) async {
    final life = FakeDomainRepository();
    final work = FakeDomainRepository();
    // 两域各 8 条 → 每框都超出框高（360×640 下每框约 250px）。
    await seed(life, '生活提醒', 8);
    await seed(work, '工作提醒', 8);
    await pump(tester, life, work);

    expect(find.byKey(const Key('overview_block_list_life')), findsOneWidget,
        reason: '生活区必须有自己的滚动容器');
    expect(find.byKey(const Key('overview_block_list_work')), findsOneWidget,
        reason: '工作区必须有自己的滚动容器');
    expect(offsetOf(tester, 'life'), 0, reason: '生活区框初始在顶');
    expect(offsetOf(tester, 'work'), 0, reason: '工作区框初始在顶');

    // 在生活区框内上滑 → 生活区 offset 变大；工作区纹丝不动。
    await tester.drag(
      find.byKey(const Key('overview_block_list_life')),
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();

    expect(offsetOf(tester, 'life'), greaterThan(0),
        reason: 'V4.1.2：生活区框内上滑必须能滚（各滑各的）');
    expect(offsetOf(tester, 'work'), 0,
        reason: 'V4.1.2：拖生活区框绝不带动工作区框');
  }, timeout: const Timeout(Duration(seconds: 90)));

  testWidgets('V4.1.2：拖工作区框不带动生活区框（反向对称）', (tester) async {
    final life = FakeDomainRepository();
    final work = FakeDomainRepository();
    await seed(life, '生活提醒', 8);
    await seed(work, '工作提醒', 8);
    await pump(tester, life, work);

    await tester.drag(
      find.byKey(const Key('overview_block_list_work')),
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();

    expect(offsetOf(tester, 'work'), greaterThan(0),
        reason: 'V4.1.2：工作区框内上滑必须能滚');
    expect(offsetOf(tester, 'life'), 0,
        reason: 'V4.1.2：拖工作区框绝不带动生活区框');
  }, timeout: const Timeout(Duration(seconds: 90)));

  testWidgets('V4.1.2：折叠一块后另一块的滚轮仍在', (tester) async {
    final life = FakeDomainRepository();
    final work = FakeDomainRepository();
    await seed(life, '生活提醒', 8);
    await seed(work, '工作提醒', 8);
    await pump(tester, life, work);

    // 折起生活区 → 生活区滚轮消失，工作区滚轮还在且仍能滚。
    await tester.tap(find.text('生活区'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('overview_block_list_life')), findsNothing);
    expect(find.byKey(const Key('overview_block_list_work')), findsOneWidget);

    await tester.drag(
      find.byKey(const Key('overview_block_list_work')),
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();
    expect(offsetOf(tester, 'work'), greaterThan(0),
        reason: 'V4.1.2：折起另一块不影响本框滚动');
  }, timeout: const Timeout(Duration(seconds: 90)));

  /// 剥注释再查（项目教训：源码级锁要剥注释，v41 已有同名辅助，不造第二套）。
  String codeOnly(String path) {
    final file = File(path);
    expect(file.existsSync(), isTrue, reason: '应能读到源码 $path');
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

  test('V4.1.2：源码级——两框结构 + 经典图标（无 M3 怪字）', () {
    final src = codeOnly('lib/ui/overview_page.dart');
    expect(src, contains('overview_block_list_'),
        reason: '每块必须有自己的滚动容器 key');
    expect(src, contains('Expanded'), reason: '两框必须拿有界高度');
    // 真机渲染成竖排「仑」状怪字的两个 M3 glyph 必须已移除（剥注释后）。
    expect(src, isNot(contains('Icons.more_time')),
        reason: '延期图标不得用真机不渲染的 Icons.more_time');
    expect(src, isNot(contains('Icons.sticky_note_2_outlined')),
        reason: '备注图标不得用真机不渲染的 Icons.sticky_note_2_outlined');
    expect(src, contains('Icons.access_time'), reason: '延期用经典时钟图标');
    expect(src, contains('Icons.comment'), reason: '备注用经典对话图标');
    // 旧铁律仍在（注释里的「恒为 2」由 v48 的原文断言单独锁）。
    expect(src, contains('overview_block_'), reason: '块 key 前缀不变');
  });
}

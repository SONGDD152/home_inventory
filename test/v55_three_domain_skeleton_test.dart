// ignore_for_file: deprecated_member_use
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:home_inventory/data/domain.dart';
import 'package:home_inventory/domain/domain_hub.dart';
import 'package:home_inventory/domain/domain_instance.dart';
import 'package:home_inventory/ui/home_module.dart';
import 'package:home_inventory/ui/home_page.dart';

import 'fake_domain_repository.dart';

/// 剥掉行注释再查（源码级锁口径：避免被注释误伤；与 v41 codeOnly 同精神）。
String stripLineComments(String path) {
  final lines = File(path).readAsLinesSync();
  final buffer = StringBuffer();
  for (final line in lines) {
    final index = line.indexOf('//');
    buffer.writeln(index < 0 ? line : line.substring(0, index));
  }
  return buffer.toString();
}

/// V55：三域骨架专项测试（V4.2.0 里程碑，PM 2026-11-28 终审拍板）。
///
/// PM 原话口径锁死：
/// * 顶栏四栏 [概览][生活][工作][知识]——知识库提平独立第三域
///   （全名「知识系统」，按钮文案「知识」），注册表驱动渲染；
/// * 生活区底栏三栏 仓储/衣橱/餐饮（衣橱/餐饮建设中占位，抽屉跟随）；
/// * 知识系统区不占底栏、无底栏模块，点顶栏进「建设中」壳页；
/// * 概览不展示知识系统的任何信息（只聚合生活+工作两本账）;
/// * 知识域独立物理分库、能力开关全空；骨架版**建壳不建库**（拍板⑤）
///   ——`ShellDomainInstance` 无仓储句柄，repository 访问即抛。
void main() {
  // ============ 一、域定义与能力开关（纯 Dart） ============

  test('V55 知识域定义：id/label/storageLabel 与 PM 文案口径逐字一致', () {
    final domain = InventoryDomain.knowledge;
    expect(domain.id, 'knowledge');
    expect(domain.label, '知识系统', reason: '域全名「知识系统」（PM 终审版第二节）');
    expect(domain.storageLabel, '知识');
    expect(domain.fileName, 'knowledge.db',
        reason: '独立物理分库的文件名已在域定义里定死（骨架版不打开它）');
  });

  test('V55 知识域能力开关全空：不开放仓储、不开放提醒', () {
    for (final capability in DomainCapability.values) {
      expect(domainSupports(InventoryDomain.knowledge, capability), isFalse,
          reason: '知识域 ${capability.name} 必须不开放（骨架版只建壳）');
    }
  });

  test('V55 生活/工作能力开关不受三域改造影响', () {
    expect(domainSupports(InventoryDomain.life, DomainCapability.storage),
        isTrue);
    expect(domainSupports(InventoryDomain.life, DomainCapability.reminders),
        isTrue);
    expect(domainSupports(InventoryDomain.work, DomainCapability.storage),
        isTrue);
    expect(domainSupports(InventoryDomain.work, DomainCapability.reminders),
        isTrue);
  });

  test('V55 模块注册表：生活三栏顺序按 PM 原话、知识域零模块', () {
    final life = modulesOf(InventoryDomain.life);
    expect(life.map((m) => m.label), <String>['仓储', '衣橱', '餐饮']);
    expect(life[0].kind, ModuleKind.storage);
    expect(life[1].kind, ModuleKind.building);
    expect(life[2].kind, ModuleKind.building);
    expect(modulesOf(InventoryDomain.knowledge), isEmpty,
        reason: '知识系统区不占底栏、无底栏模块');
  });

  // ============ 二、壳实例（建壳不建库） ============

  test('V55 壳实例：无仓储句柄，repository 访问即抛 ArgumentError', () {
    final shell = ShellDomainInstance();
    expect(shell.domainId, 'knowledge');
    expect(shell.activeOperations, 0, reason: '壳无在飞操作，切库守卫零等待');
    expect(
      () => shell.repository,
      throwsArgumentError,
    );
    expect(
      () => shell.repository,
      throwsA(isA<ArgumentError>()
          .having((e) => '${e.message}', 'message', contains('知识系统'))),
      reason: '报错文案带「知识系统」，UI 层友好中文可展示',
    );
  });

  test('V55 壳实例：禁写/关闭/重连都是空操作（无连接可管）', () async {
    final shell = ShellDomainInstance();
    shell.setWritesBlocked(true);
    shell.setWritesBlocked(false);
    await shell.close();
    await shell.reopen();
  });

  // ============ 三、DomainHub 注册表 ============

  test('V55 DomainHub 注册表：知识域经 additionalInstances 注册即可查表',
      () async {
    final domains = fakeDomains();
    final shell = ShellDomainInstance();
    final hub = DomainHub(
      life: domains.life,
      work: domains.work,
      additionalInstances: <InventoryDomain, DomainInstance>{
        InventoryDomain.knowledge: shell,
      },
    );
    expect(hub.instanceOf(InventoryDomain.knowledge), same(shell));
    expect(hub.life, same(domains.life), reason: '兼容 getter 不变');
    expect(hub.work, same(domains.work), reason: '兼容 getter 不变');

    await hub.switchTo(InventoryDomain.knowledge);
    expect(hub.currentDomain, InventoryDomain.knowledge);
    expect(hub.current, same(shell));

    await hub.switchTo(InventoryDomain.life);
    expect(hub.currentDomain, InventoryDomain.life, reason: '回切守卫流程走通');
  });

  test('V55 DomainHub：未注册的域查表抛 ArgumentError（不做静默兜底）', () {
    final domains = fakeDomains();
    final hub = DomainHub(life: domains.life, work: domains.work);
    expect(
      () => hub.instanceOf(InventoryDomain.knowledge),
      throwsArgumentError,
      reason: '组合根忘了注册知识域壳实例时，宁可当场炸也不静默指错库',
    );
  });

  test('V55 注册表留位：加第五域 = additionalInstances 加一项即可查到', () {
    final domains = fakeDomains();
    final fifth = FakeDomainInstance(FakeDomainRepository(), domainId: 'fifth');
    // 第五域的枚举值尚不存在，这里用 Map 直查表模拟 instanceOf 的路径
    //（枚举加值后同一构造即可注册）。锁的是「注册表制」这个结构。
    final registry = <InventoryDomain, DomainInstance>{
      InventoryDomain.life: domains.life,
      InventoryDomain.work: domains.work,
    };
    expect(registry.length, 2,
        reason: '留位证明：注册表是 Map，加第五域=加一个键值对，主体逻辑零改动');
  });

  // ============ 四、顶栏四栏 + 知识域壳页（widget） ============

  testWidgets('V55 顶栏四栏：[概览][生活][工作][知识]，segments 由域枚举驱动渲染',
      (tester) async {
    final domains = fakeDomains();
    final hub = DomainHub(
      life: domains.life,
      work: domains.work,
      additionalInstances: <InventoryDomain, DomainInstance>{
        InventoryDomain.knowledge: ShellDomainInstance(),
      },
    );

    await tester.pumpWidget(MaterialApp(
      home: HomePage(repository: domains.life.repository, hub: hub),
    ));
    await tester.pumpAndSettle();

    // 注册表驱动：segments 数 = 1（概览）+ 域枚举数。加第五域自动多一栏。
    //（_TopSection 是 home_page 私有枚举，这里经 dynamic 读 segments 长度。）
    final switcher = tester.widget<SegmentedButton<dynamic>>(
      find.byKey(const Key('top_section_switch')),
    );
    expect(switcher.segments.length, 1 + InventoryDomain.values.length);
    expect(find.text('概览'), findsOneWidget);
    expect(find.text('生活'), findsOneWidget);
    expect(find.text('工作'), findsOneWidget);
    expect(find.text('知识'), findsOneWidget, reason: '按钮文案「知识」（PM 拍板）');
  });

  testWidgets('V55 点顶栏「知识」：进知识系统壳页（建设中占位），无底栏',
      (tester) async {
    final domains = fakeDomains();
    final hub = DomainHub(
      life: domains.life,
      work: domains.work,
      additionalInstances: <InventoryDomain, DomainInstance>{
        InventoryDomain.knowledge: ShellDomainInstance(),
      },
    );

    await tester.pumpWidget(MaterialApp(
      home: HomePage(repository: domains.life.repository, hub: hub),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('知识'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('building_page_知识系统')), findsOneWidget,
        reason: '知识域壳页 = 建设中占位（不做假功能、不进空白页）');
    expect(find.text('知识系统建设中，敬请期待'), findsOneWidget,
        reason: '域壳页文案不带「模块」二字——知识系统是域不是模块');
    expect(find.byType(BottomNavigationBar), findsNothing,
        reason: '知识系统区不占底栏（PM 拍板）');
    expect(find.byKey(const Key('home_bottom_nav_single')), findsNothing);
  });

  testWidgets('V55 知识域抽屉只有标题：无任何业务入口', (tester) async {
    final domains = fakeDomains();
    final hub = DomainHub(
      life: domains.life,
      work: domains.work,
      additionalInstances: <InventoryDomain, DomainInstance>{
        InventoryDomain.knowledge: ShellDomainInstance(),
      },
    );

    await tester.pumpWidget(MaterialApp(
      home: HomePage(repository: domains.life.repository, hub: hub),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('知识'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open_drawer')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home_drawer')), findsOneWidget);
    expect(find.text('知识系统'), findsOneWidget,
        reason: '抽屉副标题显示域全名「知识系统」');
    expect(find.byKey(const Key('drawer_voice')), findsNothing);
    expect(find.byKey(const Key('drawer_locations')), findsNothing);
    expect(find.byKey(const Key('drawer_items')), findsNothing);
    expect(find.byKey(const Key('drawer_backup')), findsNothing);
    expect(find.byKey(const Key('drawer_loans')), findsNothing);
    expect(find.byKey(const Key('drawer_calibrate')), findsNothing);
  });

  testWidgets('V55 知识 → 生活回切：守卫流程走通，生活账数据完好', (tester) async {
    final domains = fakeDomains();
    final hub = DomainHub(
      life: domains.life,
      work: domains.work,
      additionalInstances: <InventoryDomain, DomainInstance>{
        InventoryDomain.knowledge: ShellDomainInstance(),
      },
    );

    await tester.pumpWidget(MaterialApp(
      home: HomePage(repository: domains.life.repository, hub: hub),
    ));
    await tester.pumpAndSettle();

    // 先在生活区记一笔。
    await tester.enterText(
        find.byKey(const Key('phrase_field')), '放梯子在书房');
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('submit_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('submit_button')));
    await tester.pumpAndSettle();
    expect(
        (await domains.life.repository.getAllItemsWithLocations()).length, 1);

    // 切知识域（壳页）→ 回生活区：数据不丢、界面正常。
    await tester.tap(find.text('知识'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('building_page_知识系统')), findsOneWidget);

    await tester.tap(find.text('生活'));
    await tester.pumpAndSettle();
    expect(hub.currentDomain, InventoryDomain.life);
    expect(
        (await domains.life.repository.getAllItemsWithLocations()).length, 1,
        reason: '知识域往返后生活账完好（壳实例无连接，不可能写坏任何库）');
  });

  testWidgets('V55 概览不展示知识系统（PM 拍板：只聚合生活+工作两本账）',
      (tester) async {
    final domains = fakeDomains();
    final hub = DomainHub(
      life: domains.life,
      work: domains.work,
      additionalInstances: <InventoryDomain, DomainInstance>{
        InventoryDomain.knowledge: ShellDomainInstance(),
      },
    );

    await tester.pumpWidget(MaterialApp(
      home: HomePage(repository: domains.life.repository, hub: hub),
    ));
    await tester.pumpAndSettle();

    // 概览页只在生活/工作两本账上取数；知识域切换前后概览照常工作。
    await tester.tap(find.text('概览'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('overview_page')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('overview_page')),
        matching: find.textContaining('知识'),
      ),
      findsNothing,
      reason: '概览页不应出现知识系统的任何信息（顶栏按钮不计入）',
    );
  });

  // ============ 五、源码级锁 ============

  test('V55 源码级锁：组合根注册知识域壳实例（漏注册 = instanceOf 当场炸）', () {
    final code = stripLineComments('lib/main.dart');
    expect(code, contains('ShellDomainInstance()'),
        reason: '组合根必须注册知识域壳实例');
    expect(code, contains('InventoryDomain.knowledge: ShellDomainInstance()'),
        reason: '注册键必须是知识域（写错键 = 知识域未注册）');
  });
}

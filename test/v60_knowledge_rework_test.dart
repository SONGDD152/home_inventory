// ignore_for_file: deprecated_member_use
// V4.3.1（+38）+37 返工补丁专项测试（PM 真机验收两硬伤的回归锁定）。
//
// 硬伤一：知识页主题行没有「⋮」删除入口、条目树内没有删除入口
//         （deleteNode 接口做了、界面没画——「方法存在≠接线存在」复发）。
// 补丁一：主题行 ⋮ → 删除主题（有子条目拦「先清空或转移子条目」）；
//         条目长按 → 删除；确认文案统一 PM 口径。
// 硬伤二：数据管理签知识区按钮置灰、全系统备份 knowledge 分区是壳
//         （组合根没把 knowledgeStore 接进 FullSystemBackup / DataManagementView）。
// 补丁二：知识区按钮解锁、知识备份/恢复接真库、全系统备份 knowledge 填实。
//
// 坑位（台账教训）：widget 测试不碰真 ffi 库（isolate 与 FakeAsync 不同步
// 卡死）——本文件全部用纯 Dart 内存 fake store；数据层真实行为由 v58 盖。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:home_inventory/home_inventory.dart';
import 'package:home_inventory/data/domain.dart';
import 'package:home_inventory/data/knowledge_database.dart';
import 'package:home_inventory/domain/full_system_backup.dart';
import 'package:home_inventory/ui/data_management_page.dart';
import 'package:home_inventory/ui/knowledge_page.dart';

import 'fake_loan_mixin.dart';

void main() {
  late _FakeKnowledgeStore store;

  setUp(() {
    store = _FakeKnowledgeStore();
  });

  int literarySubjectId() => store.subjectsSync
      .firstWhere((s) => s['title'] == '文学')['id'] as int;

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    // FakeAsync 陷阱：pumpAndSettle 可能在「弹窗 pop → 删除 → onChanged」
    // 微任务链入队后因无新帧提前退出，补两帧把尾部微任务链冲完。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// 长 settle：等弹出层/展开动画走完。
  Future<void> settleLong(WidgetTester tester) => settle(tester);

  /// 打开知识页 → 切到树视图页签 → 展开「文学」学科。
  /// 知识页本体不带 Scaffold（宿主页包着），测试里用 Scaffold 承载。
  Future<void> openLiterarySubject(WidgetTester tester, int subjectId) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: KnowledgePage(store: store)),
    ));
    await settle(tester);
    // 树视图是第 2 个页签（今日学习 → 知识系统 → 创作表达）。
    await tester.tap(find.byKey(const Key('knowledge_tab_tree')));
    await settle(tester);
    await tester.tap(find.byKey(Key('knowledge_subject_$subjectId')));
    await settle(tester);
  }

  // ---------- 补丁一：主题/条目删除入口 ----------

  testWidgets('主题行有「⋮」菜单含删除主题；有子条目时拦住不删', (tester) async {
    final subjectId = literarySubjectId();
    final topicId = store.addTopicSync(subjectId, '唐诗');
    store.addEntrySync(topicId, title: '静夜思', coreSummary: '床前明月光，思乡的月光');

    await openLiterarySubject(tester, subjectId);


    // 主题行右侧 ⋮ 存在（+37 硬伤一：此前整个没有）。
    await tester.tap(find.byKey(Key('knowledge_topic_menu_$topicId')));
    await settleLong(tester);
    await tester.tap(find.text('删除主题'));
    await settleLong(tester);

    // 有子条目 → 拦住并提示，不弹确认框、主题还在。
    expect(find.textContaining('先清空或转移子条目'), findsOneWidget);
    expect(find.byKey(const Key('knowledge_delete_confirm_dialog')),
        findsNothing);
    final children = store.childrenSync(subjectId);
    expect(children.map((t) => t['title']), contains('唐诗'),
        reason: '有子条目时主题不能被删');
  });

  testWidgets('空主题删除：二次确认文案 PM 口径，确认后软删（不进搜索）', (tester) async {
    final subjectId = literarySubjectId();
    final topicId = store.addTopicSync(subjectId, '宋词');

    await openLiterarySubject(tester, subjectId);
    await tester.tap(find.byKey(Key('knowledge_topic_menu_$topicId')));
    await settleLong(tester);
    await tester.tap(find.text('删除主题'));
    await settleLong(tester);

    // 二次确认弹窗，文案 = PM 回执原文。
    expect(find.byKey(const Key('knowledge_delete_confirm_dialog')),
        findsOneWidget);
    expect(find.textContaining('删除后从知识树隐藏'), findsOneWidget);
    expect(find.textContaining('数据保留在本地备份'), findsOneWidget);
    expect(find.textContaining('不可在界面恢复'), findsOneWidget);

    // 取消 → 不删。
    await tester.tap(find.text('取消'));
    await settle(tester);
    expect(store.childrenSync(subjectId).map((t) => t['title']),
        contains('宋词'));

    // 再走一遍 → 确认 → 软删（数据留底：nodeById 仍能查到 is_deleted=1）。
    await tester.tap(find.byKey(Key('knowledge_topic_menu_$topicId')));
    await settleLong(tester);
    await tester.tap(find.text('删除主题'));
    await settleLong(tester);
    await tester.tap(find.byKey(const Key('knowledge_delete_confirm_ok')));
    await settleLong(tester);

    expect(store.childrenSync(subjectId).map((t) => t['title']),
        isNot(contains('宋词')), reason: '软删后不进树视图');
    final node = store.nodeByIdSync(topicId);
    expect(node?['is_deleted'], 1, reason: '红线：软删留底，不物理删');
    expect(store.searchEntriesSync('宋词'), isEmpty,
        reason: '软删后不进搜索');
  });

  testWidgets('条目树内长按 → 删除入口可达，确认后条目消失', (tester) async {
    final subjectId = literarySubjectId();
    final topicId = store.addTopicSync(subjectId, '散文');
    final entryId = store.addEntrySync(topicId,
        title: '背影', coreSummary: '父亲爬月台买橘子');

    await openLiterarySubject(tester, subjectId);
    // 展开主题露出条目。
    await tester.tap(find.byKey(Key('knowledge_topic_$topicId')));
    await settleLong(tester);

    final entryTile = find.byKey(Key('knowledge_entry_$entryId'));
    expect(entryTile, findsOneWidget);
    await tester.longPress(entryTile);
    await settleLong(tester);

    expect(find.byKey(const Key('knowledge_delete_confirm_dialog')),
        findsOneWidget);
    expect(find.textContaining('删除后从知识树隐藏'), findsOneWidget);
    await tester.tap(find.byKey(const Key('knowledge_delete_confirm_ok')));
    await settleLong(tester);

    expect(find.byKey(Key('knowledge_entry_$entryId')), findsNothing,
        reason: '软删后条目从树视图消失');
    expect(store.nodeByIdSync(entryId)?['is_deleted'], 1,
        reason: '软删留底，备份可回溯');
    expect(store.searchEntriesSync('背影'), isEmpty,
        reason: '软删后不进搜索、不进统计');
  });

  // ---------- 补丁二：知识区接线 ----------

  testWidgets('知识区按钮解锁：备份经网关导出真数据', (tester) async {
    final gateway = _FakeGateway();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DataManagementView(
          lifeRepository: _StubLifeRepo(),
          knowledgeStore: store,
          gateway: gateway,
        ),
      ),
    ));
    await settle(tester);

    // 不再置灰：key 从 *_disabled 变为正式 key，且按钮可点。
    expect(find.byKey(const Key('data_knowledge_backup_disabled')),
        findsNothing);
    // 知识区在长滚动页底部，先滚到可见再点。
    await tester.ensureVisible(
        find.byKey(const Key('data_knowledge_backup')));
    await settle(tester);
    final backupBtn = find.byKey(const Key('data_knowledge_backup'));
    expect(backupBtn, findsOneWidget);

    await tester.tap(backupBtn);
    await settle(tester);

    // 网关收到 JSON，内含 knowledge_nodes 真数据（种子 9 学科 + 上述主题）。
    final written = gateway.lastWrittenJson;
    expect(written, isNotNull);
    final data = jsonDecode(written!) as Map<String, Object?>;
    expect(data['app'], 'home_inventory');
    expect(data['domain'], 'knowledge');
    expect((data['knowledge_nodes'] as List), isNotEmpty,
        reason: '导出 JSON 含知识 6 表真数据，不再是壳分区');
    expect(find.textContaining('知识备份已生成'), findsOneWidget);
  });

  testWidgets('知识区按钮解锁：恢复走文件选择器，报数 N 学科 / M 条目', (tester) async {
    // 先导出一份真备份，再建一条新主题，用恢复把它冲掉（恢复=清空重灌）。
    final backup = jsonEncode(store.exportBackupSync());
    store.addTopicSync(literarySubjectId(), '汉赋');
    final gateway = _FakeGateway();
    gateway.nextPickJson = backup;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DataManagementView(
          lifeRepository: _StubLifeRepo(),
          knowledgeStore: store,
          gateway: gateway,
        ),
      ),
    ));
    await settle(tester);

    await tester.ensureVisible(
        find.byKey(const Key('data_knowledge_restore')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('data_knowledge_restore')));
    await settle(tester);
    await settle(tester);

    // 恢复后「汉赋」被清掉（备份里没有它）。
    expect(store.childrenSync(literarySubjectId()).map((t) => t['title']),
        isNot(contains('汉赋')));
    expect(find.textContaining('知识库已恢复'), findsOneWidget);
    expect(find.textContaining('学科 / '), findsOneWidget,
        reason: '报数格式「N 学科 / M 条目」');
  });

  testWidgets('未注入 knowledgeStore：知识区保持置灰提示（单域形态回归保护）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DataManagementView(
          lifeRepository: _StubLifeRepo(),
          gateway: _FakeGateway(),
        ),
      ),
    ));
    await settle(tester);

    expect(find.byKey(const Key('data_knowledge_backup_disabled')),
        findsOneWidget);
    expect(find.byKey(const Key('data_knowledge_restore_disabled')),
        findsOneWidget);
    expect(find.textContaining('知识库建库后开放'), findsOneWidget);
  });

  test('组合根接线：FullSystemBackup 注入 knowledgeStore 后 knowledge 分区填实', () async {
    final topicId = store.addTopicSync(literarySubjectId(), '乐府');
    store.addEntrySync(topicId, title: '孔雀东南飞', coreSummary: '焦仲卿与刘兰芝');

    // 与组合根 _buildDataManagementTab 同构：repositories 空 + knowledgeStore。
    final service = FullSystemBackup(
      repositories: const <InventoryDomain, InventoryRepository>{},
      knowledgeStore: store,
    );
    final exported = await service.exportAll();
    final knowledge =
        (exported['domains'] as Map)['knowledge'] as Map;
    expect(knowledge.containsKey('knowledge_nodes'), isTrue,
        reason: '+37 硬伤二根因：组合根没接线时这里是壳分区，注入后必须填实');
    final nodes = knowledge['knowledge_nodes'] as List;
    expect(nodes.map((n) => (n as Map)['title']), contains('乐府'));
    expect(knowledge['knowledge_entries'] as List, isNotEmpty);
  });
}

// ---------- 纯 Dart 内存版知识库（只实现 UI 用到的子集） ----------

/// 知识库内存假实现：语义与真库对齐（软删 is_deleted、子树递归、报数口径），
/// 无任何真实 I/O——widget 测试安全（FakeAsync 兼容）。
class _FakeKnowledgeStore extends KnowledgeDatabase {
  _FakeKnowledgeStore() : super(injectedPath: '__fake_never_opened__.db') {
    _seed();
  }

  final List<Map<String, Object?>> _nodes = <Map<String, Object?>>[];
  int _nextId = 0;

  /// 种子：9 学科 + 创作表达 4 系统主题（与真库口径一致）。
  void _seed() {
    const subjects = <String>[
      '文学', '哲学', '历史', '专业', '外语', '杂学', '心理学', '创作表达', '社会时事',
    ];
    for (final s in subjects) {
      final id = _nextId + 1;
      _nodes.add(_newNode(title: s, nodeType: 'subject', isSystem: 1));
      if (s == '创作表达') {
        for (final t in const <String>[
          '写作手法拆解', '情景描写积累', '素材本', '我的写作练习',
        ]) {
          _nodes.add(_newNode(
              parentId: id, title: t, nodeType: 'topic', isSystem: 1));
        }
      }
    }
  }

  Map<String, Object?> _newNode({
    int? parentId,
    required String title,
    required String nodeType,
    int? maturity,
    int isSystem = 0,
    int? learnedAt,
  }) =>
      <String, Object?>{
        'id': ++_nextId,
        'parent_id': parentId,
        'title': title,
        'node_type': nodeType,
        'maturity': maturity,
        'is_system': isSystem,
        'is_deleted': 0,
        'learned_at': learnedAt,
        'created_at': 1,
        'updated_at': 1,
      };

  List<Map<String, Object?>> get subjectsSync => _nodes
      .where((n) => n['parent_id'] == null &&
          (n['is_deleted'] as int) == 0 &&
          n['node_type'] == 'subject')
      .toList();
  List<Map<String, Object?>> childrenSync(int parentId) => _nodes
      .where((n) => n['parent_id'] == parentId &&
          (n['is_deleted'] as int) == 0)
      .toList();

  Map<String, Object?>? nodeByIdSync(int id) => _nodes
      .where((n) => n['id'] == id)
      .firstOrNull;

  int addTopicSync(int parentId, String title) {
    final node = _newNode(parentId: parentId, title: title, nodeType: 'topic');
    _nodes.add(node);
    return node['id'] as int;
  }

  int addEntrySync(int topicId,
      {required String title, required String coreSummary}) {
    final node = _newNode(
        parentId: topicId, title: title, nodeType: 'entry', learnedAt: 1)
      ..['core_summary'] = coreSummary;
    _nodes.add(node);
    return node['id'] as int;
  }

  /// 子树软删（与真库口径一致：递归标 is_deleted，不物理删）。
  void deleteNodeSync(int id) {
    void mark(int target) {
      for (final n in _nodes) {
        if (n['id'] == target) {
          if ((n['is_deleted'] as int) == 0) {
            n['is_deleted'] = 1;
          }
        } else if (n['parent_id'] == target &&
            (n['is_deleted'] as int) == 0) {
          mark(n['id'] as int);
        }
      }
    }

    mark(id);
  }

  List<Map<String, Object?>> searchEntriesSync(String query) => _nodes
      .where((n) =>
          n['node_type'] == 'entry' &&
          (n['is_deleted'] as int) == 0 &&
          (n['title'] as String).contains(query))
      .toList();

  Map<String, Object?> exportBackupSync() => <String, Object?>{
        'app': 'home_inventory',
        'domain': 'knowledge',
        'schemaVersion': KnowledgeDatabase.version,
        'knowledge_nodes': _nodes.map((n) => Map.of(n)).toList(),
        'knowledge_entries': _nodes
            .where((n) => n['node_type'] == 'entry')
            .map((n) => <String, Object?>{
                  'node_id': n['id'],
                  'core_summary': n['core_summary'],
                  'learned_at': n['learned_at'],
                })
            .toList(),
        'knowledge_tags': const <Object?>[],
        'knowledge_entry_tags': const <Object?>[],
        'knowledge_links': const <Object?>[],
        'knowledge_entry_meta': const <Object?>[],
      };

  /// 恢复 = 清空重灌（与真库口径一致）。
  void restoreFromBackupSync(Map<String, Object?> data) {
    _nodes
      ..clear()
      ..addAll((data['knowledge_nodes'] as List)
          .map((r) => Map<String, Object?>.from(r as Map)));
    _nextId = _nodes
        .map((n) => n['id'] as int)
        .fold(0, (a, b) => a > b ? a : b);
  }

  String countSummarySync() {
    final subjects = _nodes
        .where((n) => (n['is_deleted'] as int) == 0 &&
            n['node_type'] == 'subject')
        .length;
    final entries = _nodes
        .where((n) => (n['is_deleted'] as int) == 0 &&
            n['node_type'] == 'entry')
        .length;
    return '$subjects 学科 / $entries 条目';
  }

  // ---------- KnowledgeDatabase 接口覆写（无 I/O） ----------

  @override
  Future<List<Map<String, Object?>>> subjects() async => subjectsSync;

  @override
  Future<List<Map<String, Object?>>> childrenOf(int nodeId) async =>
      childrenSync(nodeId);

  @override
  Future<Map<String, Object?>?> nodeById(int id) async => nodeByIdSync(id);

  @override
  Future<int> addTopic(int parentId, String title) async =>
      addTopicSync(parentId, title);

  @override
  Future<int> addEntry(
    int topicId, {
    required String title,
    String? source,
    required String coreSummary,
    int? learnedAt,
    int maturity = 0,
    String? template,
    Map<String, String> meta = const <String, String>{},
  }) async =>
      addEntrySync(topicId, title: title, coreSummary: coreSummary);

  @override
  Future<int> deleteNode(int nodeId) async {
    deleteNodeSync(nodeId);
    return nodeId;
  }

  @override
  Future<List<Map<String, Object?>>> searchEntries(String query) async =>
      searchEntriesSync(query);

  @override
  Future<Map<String, int>> fruitCountOf(int nodeId) async {
    final entries = childrenSync(nodeId)
        .where((n) => n['node_type'] == 'entry')
        .toList();
    return <String, int>{
      'total': entries.length,
      'unripe': entries.where((e) => e['maturity'] == 0).length,
      'half': entries.where((e) => e['maturity'] == 1).length,
      'ripe': entries.where((e) => e['maturity'] == 2).length,
    };
  }

  @override
  Future<List<Map<String, Object?>>> timeline({
    int? dayStartMs,
    int? dayEndMs,
    int? limit,
  }) async =>
      const <Map<String, Object?>>[];

  @override
  Future<List<Map<String, Object?>>> entriesOfTopic(
      int topicId, {String? template}) async => const <Map<String, Object?>>[];

  @override
  Future<List<Map<String, Object?>>> creativeTopics() async => const [];

  @override
  Future<List<Map<String, Object?>>> searchNodes(String query) async => const [];

  @override
  Future<Map<String, Object?>?> entryDetail(int nodeId) async => null;

  @override
  Future<void> setMaturity(int nodeId, int maturity) async {}

  @override
  Future<void> updateEntry(
    int nodeId, {
    String? title,
    String? source,
    String? coreSummary,
    int? learnedAt,
    int? maturity,
    Map<String, String>? meta,
  }) async {}

  @override
  Future<void> updateNodeTitle(int nodeId, String title) async {}

  @override
  Future<Map<String, Object?>> exportBackup() async => exportBackupSync();

  @override
  Future<void> restoreBackup(Map<String, Object?> data) async =>
      restoreFromBackupSync(data);

  @override
  Future<String> countSummary() async => countSummarySync();
}

// ---------- 数据管理页测试桩 ----------

/// 备份网关测试桩：记录写入内容、可控文件选择。
class _FakeGateway implements BackupGateway {
  String? lastWrittenJson;
  String? nextPickJson;

  @override
  Future<String> writeBackupFile(String json) async {
    lastWrittenJson = json;
    return '/tmp/fake_kb_backup.json';
  }

  @override
  Future<void> shareFile(String path) async {}

  @override
  Future<String?> saveBytesToDevice(String fileName, Uint8List bytes) async =>
      null;

  @override
  Future<String?> pickBackupFile() async => nextPickJson == null
      ? null
      : '/tmp/fake_kb_restore.json';

  @override
  Future<String> readBackupFile(String path) async =>
      nextPickJson ?? '{}';
}

/// 生活区仓储桩：数据管理页构建只需存在，本测试不触它的账。
class _StubLifeRepo with FakeLoanMixin implements InventoryRepository {
  @override
  Future<ItemWithLocations?> findByName(String name) async => null;
  @override
  Future<List<Location>> getAllLocations() async => const <Location>[];
  @override
  Future<List<ItemWithLocations>> getAllItemsWithLocations() async =>
      const <ItemWithLocations>[];
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
  Future<int> addLocation(String name, {String? remark}) async => 1;
  @override
  Future<UpsertResult> upsertItemLocation(String itemName, int locationId,
      {String? rawText, int? quantity, bool additive = false}) async {
    throw UnimplementedError('本测试用不到');
  }

  @override
  Future<MoveResult> moveItem(String itemName, int locationId,
          {String? rawText}) async =>
      throw UnimplementedError('本测试用不到');

  @override
  Future<Map<String, Object?>> exportBackup() async =>
      <String, Object?>{'app': 'home_inventory'};

  @override
  Future<void> restoreBackup(Map<String, Object?> data) async {}
}

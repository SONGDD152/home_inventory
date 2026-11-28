// ignore_for_file: deprecated_member_use
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_inventory/data/domain.dart';
import 'package:home_inventory/data/daily_report_service.dart';
import 'package:home_inventory/domain/overview_reader.dart';
import 'package:home_inventory/data/inventory_database.dart';
import 'package:home_inventory/data/knowledge_database.dart';
import 'package:home_inventory/domain/full_system_backup.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// V58：+37 知识库功能专项（PM 终审开工回执七点 + 真机验收清单）。
///
/// 覆盖：建库 v14 / 种子幂等不复活 / Writer 七写口 / 树三层封顶 /
/// 软删子树不进搜索 / links 边不软删恢复接回 / practice 成熟度锁死 /
/// 全系统备份 knowledge 报数「N 学科 / M 条目」/ 日报知识段两态 /
/// 创作区 4 模板 meta 存取。
void main() {
  sqfliteFfiInit();

  int _tmpSeq = 0;

  /// 临时文件库（不用 :memory:——内存库 close 即销毁，
  /// 测「重开不复活种子」必须真落盘再重开）。
  Future<KnowledgeDatabase> newStore() async {
    final dir = await Directory.systemTemp.createTemp('v58_knowledge');
    final path =
        '${dir.path}/knowledge_${_tmpSeq++}_${DateTime.now().microsecondsSinceEpoch}.db';
    return KnowledgeDatabase(
      injectedFactory: databaseFactoryFfi,
      injectedPath: path,
    );
  }

  Future<InventoryDatabase> newInventory(InventoryDomain domain) async {
    final dir = await Directory.systemTemp.createTemp('v58_inventory');
    final path =
        '${dir.path}/${domain.id}_${_tmpSeq++}_${DateTime.now().microsecondsSinceEpoch}.db';
    return InventoryDatabase(
      databaseFactory: databaseFactoryFfi,
      databasePath: path,
      domain: domain,
    );
  }

  // ============ 一、建库与种子 ============

  test('V58 建库：schemaVersion=14，种子 9 学科 + 创作表达 4 主题', () async {
    final store = await newStore();
    await store.open();
    final subjects = await store.subjects();
    expect(subjects.length, 9, reason: '9 学科预置（PM 终审版清单）');
    expect(
        subjects.map((s) => s['title']),
        containsAll(<String>[
          '文学', '哲学', '历史', '专业', '外语', '杂学', '心理学', '创作表达', '社会时事',
        ]));
    final creative = subjects.firstWhere((s) => s['title'] == '创作表达');
    final topics = await store.childrenOf(creative['id'] as int);
    expect(topics.length, 4);
    expect(topics.every((t) => t['is_system'] == 1), isTrue,
        reason: '创作表达 4 主题系统预置（可改名不可删）');
    final summary = await store.countSummary();
    expect(summary, '9 学科 / 0 条目', reason: '报数口径「N 学科 / M 条目」');
    await store.close();
  });

  test('V58 种子幂等：重复开库不重复种；软删根节点不被复活', () async {
    final store = await newStore();
    await store.open();
    final first = await store.subjects();
    expect(first.length, 9);
    // 删掉一个学科（软删）。
    final target = first.firstWhere((s) => s['title'] == '杂学');
    await store.deleteNode(target['id'] as int);
    // 关掉重开（触发 seed 再次执行）。
    await store.close();
    await store.open();
    final after = await store.subjects();
    expect(after.length, 8,
        reason: '用户删掉的根节点不被 seed 复活（开工回执第 5 点）');
    expect(after.map((s) => s['title']), isNot(contains('杂学')));
    await store.close();
  });

  // ============ 二、Writer：三层封顶与写口 ============

  test('V58 Writer：三层封顶——主题只挂学科、条目只挂主题、错层拒绝', () async {
    final store = await newStore();
    await store.open();
    final subjects = await store.subjects();
    final literatureId = subjects.firstWhere((s) => s['title'] == '文学')['id'] as int;

    // 条目不能直接挂学科。
    expect(
      () => store.addEntry(literatureId,
          title: '错层', coreSummary: '一句话'),
      throwsArgumentError,
    );
    // 主题不能挂主题。
    final topicId = await store.addTopic(literatureId, '东野圭吾');
    expect(
      () => store.addTopic(topicId, '再分一层'),
      throwsArgumentError,
      reason: '树三层封顶：学科→主题→条目',
    );
    // 正确链路：学科→主题→条目。
    final entryId = await store.addEntry(topicId,
        title: '《白夜行》', source: '东野圭吾',
        coreSummary: '世上最深的黑夜，是两个人一起走过的白昼');
    expect(entryId, greaterThan(0));
    await store.close();
  });

  test('V58 Writer：一句话核心强制非空（对抗遗忘的防线）', () async {
    final store = await newStore();
    await store.open();
    final subjects = await store.subjects();
    final literatureId = subjects.firstWhere((s) => s['title'] == '文学')['id'] as int;
    final topicId = await store.addTopic(literatureId, '东野圭吾');
    expect(
      () => store.addEntry(topicId, title: 'x', coreSummary: '  '),
      throwsArgumentError,
    );
    await store.close();
  });

  test('V58 updateNodeTitle：改名后 search_text 重算（新名命中、旧名不脏）', () async {
    final store = await newStore();
    await store.open();
    final subjects = await store.subjects();
    final literatureId = subjects.firstWhere((s) => s['title'] == '文学')['id'] as int;
    final topicId = await store.addTopic(literatureId, '推理小说');
    final entryId = await store.addEntry(topicId,
        title: '旧题名', source: '旧来源', coreSummary: '核心句');
    // 改名前：旧名命中。
    expect((await store.searchEntries('旧题名')).length, 1);
    // 改名。
    await store.updateNodeTitle(entryId, '新题名');
    expect((await store.searchEntries('新题名')).length, 1,
        reason: '改名后 search_text 同步重算，不留脏索引');
    expect((await store.searchEntries('旧题名')), isEmpty);
    expect((await store.searchEntries('旧来源')).length, 1,
        reason: '来源与核心句仍在索引里');
    await store.close();
  });

  test('V58 moveNode：防环 + 深度校验 + 学科不可移动', () async {
    final store = await newStore();
    await store.open();
    final subjects = await store.subjects();
    final litId = subjects.firstWhere((s) => s['title'] == '文学')['id'] as int;
    final philId = subjects.firstWhere((s) => s['title'] == '哲学')['id'] as int;
    final t1 = await store.addTopic(litId, '主题甲');
    final t2 = await store.addTopic(philId, '主题乙');
    final entry = await store.addEntry(t1, title: '条目', coreSummary: '核心');

    // 学科不可移动。
    expect(() => store.moveNode(litId, philId), throwsArgumentError);
    // 条目不能移动到学科下（只能挂主题）。
    expect(() => store.moveNode(entry, philId), throwsArgumentError);
    // 不能移动到自己的后代（防环：先建主题→条目，再把主题移到自己条目下）。
    expect(() => store.moveNode(t1, entry), throwsArgumentError);
    // 正常跨学科迁移。
    await store.moveNode(entry, t2);
    final moved = await store.nodeById(entry);
    expect(moved!['parent_id'], t2);
    await store.close();
  });

  // ============ 三、软删与恢复 ============

  test('V58 deleteNode：整棵子树软删、不进搜索、links 边不软删', () async {
    final store = await newStore();
    await store.open();
    final subjects = await store.subjects();
    final litId = subjects.firstWhere((s) => s['title'] == '文学')['id'] as int;
    final t1 = await store.addTopic(litId, '主题甲');
    final e1 = await store.addEntry(t1, title: '条目甲', coreSummary: '核心甲');
    final t2 = await store.addTopic(litId, '主题乙');
    final e2 = await store.addEntry(t2, title: '条目乙', coreSummary: '核心乙');
    // 关联边：条目甲 ↔ 条目乙。
    final db = await store.open();
    await db.insert(KnowledgeDatabase.tableLinks,
        <String, Object?>{'from_node_id': e1, 'to_node_id': e2,
          'created_at': DateTime.now().millisecondsSinceEpoch});

    // 删主题甲（条目甲随子树软删）。
    await store.deleteNode(t1);
    // 软删不进搜索。
    expect((await store.searchEntries('条目甲')), isEmpty);
    expect((await store.searchEntries('核心甲')), isEmpty);
    // 树视图不再显示。
    expect((await store.childrenOf(litId)).map((n) => n['title']),
        <String>['主题乙']);
    // links 边不软删（物理仍在）。
    final links = await db.query(KnowledgeDatabase.tableLinks);
    expect(links.length, 1, reason: '边不软删：恢复子树后边自动接回');
    await store.close();
  });

  test('V58 系统预置主题不可删；学科可删', () async {
    final store = await newStore();
    await store.open();
    final subjects = await store.subjects();
    final creative = subjects.firstWhere((s) => s['title'] == '创作表达');
    final topics = await store.childrenOf(creative['id'] as int);
    expect(
      () => store.deleteNode(topics.first['id'] as int),
      throwsArgumentError,
      reason: '创作表达 4 主题可改名不可删',
    );
    // 学科可删。
    final zaxue = subjects.firstWhere((s) => s['title'] == '杂学');
    expect(await store.deleteNode(zaxue['id'] as int), greaterThan(0));
    await store.close();
  });

  // ============ 四、创作区 4 模板 ============

  test('V58 创作区：模板条目落 entries 主表 + meta 扩展表，模板标识 _template', () async {
    final store = await newStore();
    await store.open();
    final topics = await store.creativeTopics();
    // 4 个系统主题按序对应 4 模板。
    expect(topics.map((t) => t['title']),
        <String>['写作手法拆解', '情景描写积累', '素材本', '我的写作练习']);

    // technique 模板条目。
    final techniqueId = topics[0]['id'] as int;
    await store.addEntry(techniqueId,
        title: '《白夜行》',
        source: '东野圭吾',
        coreSummary: '把凶器藏进时代里',
        learnedAt: DateTime.now().millisecondsSinceEpoch,
        template: 'technique',
        meta: <String, String>{
          '_template': 'technique',
          'book': '《白夜行》',
          'excerpt': '我的天空里没有太阳……',
        });
    // practice 模板条目。
    final practiceId = topics[3]['id'] as int;
    final practiceEntry = await store.addEntry(practiceId,
        title: '描写练习第一天',
        coreSummary: '写了窗外的雨',
        learnedAt: DateTime.now().millisecondsSinceEpoch,
        template: 'practice',
        meta: <String, String>{
          '_template': 'practice',
          'written': '雨下了一整天，像谁在天上倒水。',
        });

    // 详情回带 meta（空字段不占位：只存过的键返回）。
    final detail =
        await store.entryDetail(practiceEntry) as Map<String, Object?>;
    final meta = detail['meta'] as Map<String, String>;
    expect(meta['_template'], 'practice');
    expect(meta['written'], '雨下了一整天，像谁在天上倒水。');
    expect(meta.containsKey('feeling'), isFalse, reason: '空字段不占位');

    // 按模板取条目。
    final techniqueItems =
        await store.entriesOfTopic(techniqueId, template: 'technique');
    expect(techniqueItems.length, 1);
    await store.close();
  });

  test('V58 写作练习成熟度锁死🔴：写完即完成，不给改', () async {
    final store = await newStore();
    await store.open();
    final topics = await store.creativeTopics();
    final practiceId = topics[3]['id'] as int;
    final entryId = await store.addEntry(practiceId,
        title: '练习', coreSummary: '核心',
        learnedAt: DateTime.now().millisecondsSinceEpoch,
        template: 'practice',
        meta: <String, String>{'_template': 'practice'});
    expect(
      () => store.setMaturity(entryId, 0),
      throwsArgumentError,
      reason: 'practice 成熟度固定熟果（PM 拍板，不参与青果/半熟统计）',
    );
    // 普通条目三档可标。
    final topics2 = await store.subjects();
    final litId = topics2.firstWhere((s) => s['title'] == '文学')['id'] as int;
    final t = await store.addTopic(litId, '普通主题');
    final normal = await store.addEntry(t, title: '普通条目', coreSummary: '核心');
    await store.setMaturity(normal, 1);
    final node = await store.nodeById(normal);
    expect(node!['maturity'], 1);
    await store.close();
  });

  // ============ 五、全系统备份：knowledge 报数 ============

  test('V58 全系统备份：knowledge 分区带真数据，恢复往返保真，报数「N 学科 / M 条目」',
      () async {
    final store = await newStore();
    await store.open();
    final life = await newInventory(InventoryDomain.life);
    final work = await newInventory(InventoryDomain.work);
    await life.open();
    await work.open();
    // 造知识数据。
    final subjects = await store.subjects();
    final litId = subjects.firstWhere((s) => s['title'] == '文学')['id'] as int;
    final t = await store.addTopic(litId, '推理');
    await store.addEntry(t,
        title: '《白夜行》', source: '东野圭吾',
        coreSummary: '核心句',
        learnedAt: DateTime.now().millisecondsSinceEpoch);

    final service = FullSystemBackup(
      repositories: <InventoryDomain, InventoryRepositoryImpl>{
        InventoryDomain.life: life,
        InventoryDomain.work: work,
      },
      knowledgeStore: store,
    );
    final backup = await service.exportAll();
    final domains = backup['domains']! as Map<String, Object?>;
    expect(domains.keys.toSet(),
        <String>{'life', 'work', 'knowledge'});
    final knowledge = domains['knowledge']! as Map<String, Object?>;
    expect(knowledge['schemaVersion'], KnowledgeDatabase.version,
        reason: 'knowledge 分区版本号 = 14（分域版本号）');
    final nodes = knowledge['knowledge_nodes']! as List;
    expect(nodes.whereType<Map>().where((n) => n['node_type'] == 'entry').length,
        1);

    // 报数：N 学科 / M 条目。
    final text = service.restoreResultText(backup);
    expect(text, contains('知识系统：9 学科 / 1 条目'),
        reason: '逐域报数（9 学科预置，条目 1）');

    // 恢复到全新库 → 搜索照常命中（search_text 重建）。
    final fresh = await newStore();
    await fresh.open();
    final freshSubjects = await fresh.subjects();
    final freshLit =
        freshSubjects.firstWhere((s) => s['title'] == '文学')['id'] as int;
    await fresh.deleteNode(freshLit); // 清空文学学科，验证恢复把它带回来。
    final life2 = await newInventory(InventoryDomain.life);
    final work2 = await newInventory(InventoryDomain.work);
    await life2.open();
    await work2.open();
    final service2 = FullSystemBackup(
      repositories: <InventoryDomain, InventoryRepositoryImpl>{
        InventoryDomain.life: life2,
        InventoryDomain.work: work2,
      },
      knowledgeStore: fresh,
    );
    await service2.restoreAll(backup);
    expect((await fresh.searchEntries('《白夜行》')).length, 1,
        reason: '恢复后派生列重建，搜索照常命中');
    final summary = await fresh.countSummary();
    expect(summary, '9 学科 / 1 条目');
    await fresh.close();
    await store.close();
  });

  // ============ 六、日报知识段两态 ============

  test('V58 日报知识段：有则显示（模板前缀+成熟度）、无则不出现', () async {
    final store = await newStore();
    await store.open();
    final life = await newInventory(InventoryDomain.life);
    await life.open();
    final work = await newInventory(InventoryDomain.work);
    await work.open();

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    // 无知识条目 → 段不出现。
    final empty = DailyReportService(
        storage: life,
        reminders: life,
        overview: InventoryOverviewReader(life: life, work: work),
        knowledgeReader: store);
    final emptyContent = await empty.buildContent(today);
    expect(emptyContent.contains('## 今日学习'), isFalse,
        reason: '知识段有则显示、无则不出现（PM 拍板）');

    // 有知识条目 → 段出现，带模板前缀与成熟度。
    final topics = await store.creativeTopics();
    await store.addEntry(topics[0]['id'] as int,
        title: '《白夜行》',
        source: '东野圭吾',
        coreSummary: '核心句',
        learnedAt: today.millisecondsSinceEpoch,
        template: 'technique',
        meta: <String, String>{'_template': 'technique'});
    final service = DailyReportService(
        storage: life,
        reminders: life,
        overview: InventoryOverviewReader(life: life, work: work),
        knowledgeReader: store);
    final content = await service.buildContent(today);
    expect(content.contains('## 今日学习'), isTrue);
    expect(content.contains('写作手法拆解·《白夜行》'), isTrue);
    expect(content.contains('🔴'), isFalse, reason: '普通模板默认青果🟤');
    expect(content.contains('🟤'), isTrue);
    expect(content.contains('来源：东野圭吾'), isTrue);

    // 无知识库能力（reader=null）→ 段不出现。
    final legacy = DailyReportService(
        storage: life,
        reminders: life,
        overview: InventoryOverviewReader(life: life, work: work));
    final legacyContent = await legacy.buildContent(today);
    expect(legacyContent.contains('## 今日学习'), isFalse);
    await store.close();
  });
}

/// InventoryRepositoryImpl 别名（FullSystemBackup 构造参数类型）。
typedef InventoryRepositoryImpl = InventoryDatabase;

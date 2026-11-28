import 'package:sqflite/sqflite.dart';

import 'domain.dart';

/// V4.3（+37 知识库功能）：知识域数据库（`knowledge.db`）。
///
/// **独立物理分库、独立表集**——与生活/工作仓储账（`InventoryDatabase`，
/// 9 表）完全不同的领域：知识树 + 条目详情 + 标签 + 关联边 + 模板扩展。
/// 因此不塞进 `InventoryDatabase`（那是仓储账目的语义），单独一类。
///
/// ## schema（knowledge.db 专用，schemaVersion=14）
///
/// 版本号说明：生活/工作两库仍是 v13（本版不动它们任何表）；
/// knowledge.db 是**首次建库**，直接建到 14。**分域版本号各自独立演进**
/// （2026-11-28 台账留档），旧「两库齐平」口径由分域版本号取代。
/// 旧版 app 恢复含 knowledge 分区（schemaVersion=14）的全系统备份 →
/// 走既有「版本过高拒绝」校验链，礼貌指路升级、不炸。
///
/// ## 表（6 张真数据表；FTS 不建虚拟表）
///
/// * `knowledge_nodes` —— 树节点（自引用 parent_id，三层封顶
///   subject → topic → entry）；maturity 只挂 entry 节点。
/// * `knowledge_entries` —— 条目详情（source / core_summary / learned_at），
///   1:1 挂 entry 节点；`search_text` 派生列聚合 标题+一句话核心+来源。
/// * `knowledge_tags` / `knowledge_entry_tags` —— 标签与条目多对多。
/// * `knowledge_links` —— 条目间关联边；**软删节点不动边**（查询 JOIN
///   主表过滤 is_deleted=0，恢复子树后边自动接回）。
/// * `knowledge_entry_meta` —— 模板扩展字段（键值对），创作区 4 模板
///   共用此表，模板标识用 `_template` 键。
///
/// ## 为什么不用 FTS5
///
/// Android 系统 SQLite 由 ROM 决定编译选项，**FTS5 在大量真机上不可用**
/// （运行时建虚拟表直接报错）。知识库数据量级（个人笔记，万条以内）
/// 用派生列 + LIKE 足够，接口语义（搜索命中/更新重算）与 FTS 方案一致。
/// **技术偏离已留档**（台账 2026-11-28 + 发版简报如实报）。
///
/// ## 软删口径（沿用 V4.1.7）
///
/// 删除 = 整棵子树软删（is_deleted=1 + deleted_at），不物理清除；
/// 软删节点不进搜索、不进日报、不进树；全系统备份照常带走（可回溯）；
/// 恢复 = 完整还原。`knowledge_links` 边不软删。
///
/// ## 种子（幂等）
///
/// 9 学科根节点 + 创作表达下 4 个系统预置主题。重复启动不产生重复；
/// **用户删掉的根节点不被 seed 复活**（判重时把软删行也算「已存在」）。
/// 4 个预置主题 `is_system=1`：可改名、不可删。
class KnowledgeDatabase {
  KnowledgeDatabase({DatabaseFactory? injectedFactory, String? injectedPath})
      : _injectedFactory = injectedFactory,
        _injectedPath = injectedPath;

  final DatabaseFactory? _injectedFactory;
  final String? _injectedPath;

  /// knowledge.db 专用 schema 版本（见类注释：分域版本号独立演进）。
  static const int version = 14;

  Database? _db;
  bool _writesBlocked = false;

  /// 在飞操作数（切库守卫等它归零）。
  int activeOperations = 0;

  DatabaseFactory get _factory => _injectedFactory ?? databaseFactory;

  Future<String> _resolvePath() async {
    final injected = _injectedPath;
    if (injected != null) return injected;
    return _joinPath(await getDatabasesPath(), InventoryDomain.knowledge.fileName);
  }

  /// sqflite 的 path join（避免直接依赖 path 包，走 sqflite 自带）。
  static String _joinPath(String a, String b) {
    if (a.endsWith('/')) return '$a$b';
    return '$a/$b';
  }

  Future<Database> open() async {
    final existing = _db;
    if (existing != null && existing.isOpen) return existing;
    final db = await _factory.openDatabase(
      await _resolvePath(),
      options: OpenDatabaseOptions(
        version: version,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
    _db = db;
    await _ensureSeed(db);
    return db;
  }

  bool get isOpen => _db?.isOpen ?? false;

  /// 切库守卫：切换期间禁止写入（写方法先问这里）。
  void setWritesBlocked(bool blocked) => _writesBlocked = blocked;

  Future<void> close() async {
    final db = _db;
    _db = null;
    if (db != null && db.isOpen) await db.close();
  }

  /// 脏连接自愈：关掉重开，schema 与数据不动（种子幂等，不会重复种）。
  Future<void> reopen() async {
    await close();
    await open();
  }

  void _guardWrite() {
    if (_writesBlocked) throw const DomainSwitchInProgress();
  }

  // ---------- 表名常量 ----------

  static const String tableNodes = 'knowledge_nodes';
  static const String tableEntries = 'knowledge_entries';
  static const String tableTags = 'knowledge_tags';
  static const String tableEntryTags = 'knowledge_entry_tags';
  static const String tableLinks = 'knowledge_links';
  static const String tableEntryMeta = 'knowledge_entry_meta';

  // ---------- 建库 ----------

  Future<void> _onCreate(Database db, int newVersion) async {
    await db.execute('''
      CREATE TABLE $tableNodes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        parent_id INTEGER,
        title TEXT NOT NULL,
        node_type TEXT NOT NULL,
        maturity INTEGER,
        is_system INTEGER NOT NULL DEFAULT 0,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        deleted_at INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE $tableEntries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        node_id INTEGER NOT NULL,
        source TEXT,
        core_summary TEXT NOT NULL,
        learned_at INTEGER,
        template TEXT,
        search_text TEXT NOT NULL DEFAULT '',
        is_deleted INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        deleted_at INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE $tableTags (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE $tableEntryTags (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        node_id INTEGER NOT NULL,
        tag_id INTEGER NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE $tableLinks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        from_node_id INTEGER NOT NULL,
        to_node_id INTEGER NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE $tableEntryMeta (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        node_id INTEGER NOT NULL,
        meta_key TEXT NOT NULL,
        meta_value TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_nodes_parent ON $tableNodes(parent_id)');
    await db.execute(
        'CREATE INDEX idx_entries_node ON $tableEntries(node_id)');
    await db.execute(
        'CREATE INDEX idx_meta_node ON $tableEntryMeta(node_id)');
  }

  Future<void> _onUpgrade(
      Database db, int oldVersion, int newVersion) async {
    // knowledge.db 首版即 14，未来升版在这里补 CREATE TABLE IF NOT EXISTS。
  }

  // ---------- 种子（幂等；软删不复活） ----------

  /// 9 学科根节点（PM 终审版学科清单）。
  static const List<String> seedSubjects = <String>[
    '文学', '哲学', '历史', '专业', '外语', '杂学', '心理学', '创作表达', '社会时事',
  ];

  /// 创作表达下的 4 个系统预置主题（可改名不可删）。
  static const Map<String, List<String>> seedTopics = <String, List<String>>{
    '创作表达': <String>['写作手法拆解', '情景描写积累', '素材本', '我的写作练习'],
  };

  Future<void> _ensureSeed(Database db) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final title in seedSubjects) {
      // 判重把软删行也算「已存在」——用户删掉的根节点不被复活。
      final existing = await db.query(tableNodes,
          where: 'parent_id IS NULL AND title = ? AND node_type = ?',
          whereArgs: <Object?>[title, 'subject'], limit: 1);
      if (existing.isNotEmpty) continue;
      await db.insert(tableNodes, <String, Object?>{
        'parent_id': null,
        'title': title,
        'node_type': 'subject',
        'maturity': null,
        'is_system': 0,
        'is_deleted': 0,
        'created_at': now,
        'updated_at': now,
        'deleted_at': null,
      });
    }
    // 创作表达 4 主题（is_system=1，可改名不可删）。
    final creative = await db.query(tableNodes,
        where: 'parent_id IS NULL AND title = ? AND node_type = ?',
        whereArgs: <Object?>['创作表达', 'subject'], limit: 1);
    if (creative.isEmpty) return; // 理论不可达（上面刚种过）；防御。
    final creativeId = creative.first['id'] as int;
    for (final topic in (seedTopics['创作表达'] ?? const <String>[])) {
      final existing = await db.query(tableNodes,
          where: 'parent_id = ? AND title = ? AND node_type = ?',
          whereArgs: <Object?>[creativeId, topic, 'topic'], limit: 1);
      if (existing.isNotEmpty) continue;
      await db.insert(tableNodes, <String, Object?>{
        'parent_id': creativeId,
        'title': topic,
        'node_type': 'topic',
        'maturity': null,
        'is_system': 1,
        'is_deleted': 0,
        'created_at': now,
        'updated_at': now,
        'deleted_at': null,
      });
    }
  }

  // ---------- 读取口（Query） ----------

  /// 学科列表（根节点，未删），按创建序。
  Future<List<Map<String, Object?>>> subjects() async {
    final db = await open();
    return db.query(tableNodes,
        where: 'parent_id IS NULL AND is_deleted = 0 AND node_type = ?',
        whereArgs: <Object?>['subject'],
        orderBy: 'id ASC');
  }

  /// 某节点的直接子节点（未删），按创建序。
  Future<List<Map<String, Object?>>> childrenOf(int nodeId) async {
    final db = await open();
    return db.query(tableNodes,
        where: 'parent_id = ? AND is_deleted = 0',
        whereArgs: <Object?>[nodeId],
        orderBy: 'id ASC');
  }

  /// 单节点。
  Future<Map<String, Object?>?> nodeById(int id) async {
    final db = await open();
    final rows = await db.query(tableNodes,
        where: 'id = ?', whereArgs: <Object?>[id], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// 某节点的果实数统计（未删 entry 后代）。返回 {青果, 半熟, 熟果, 总数}。
  Future<Map<String, int>> fruitCountOf(int nodeId) async {
    final db = await open();
    final rows = await db.rawQuery('''
      SELECT n.maturity AS m, COUNT(*) AS c
      FROM $tableNodes n
      WHERE n.is_deleted = 0 AND n.node_type = 'entry'
        AND n.parent_id IN (
          WITH RECURSIVE down(id) AS (
            SELECT ? UNION ALL
            SELECT child.id FROM $tableNodes child
            JOIN down ON child.parent_id = down.id
            WHERE child.is_deleted = 0
          )
          SELECT id FROM down
        )
      GROUP BY n.maturity
    ''', <Object?>[nodeId]);
    final out = <String, int>{'unripe': 0, 'half': 0, 'ripe': 0, 'total': 0};
    for (final row in rows) {
      final m = row['m'] as int?;
      final c = row['c'] as int;
      out['total'] = out['total']! + c;
      if (m == 0) out['unripe'] = out['unripe']! + c;
      if (m == 1) out['half'] = out['half']! + c;
      if (m == 2) out['ripe'] = out['ripe']! + c;
    }
    return out;
  }

  /// 条目详情（entry 节点 JOIN entries 详情 + meta 键值）。
  /// 返回 {node:…, entry:…, meta:{k:v}}；节点已删返回 null。
  Future<Map<String, Object?>?> entryDetail(int nodeId) async {
    final db = await open();
    final nodeRows = await db.query(tableNodes,
        where: 'id = ? AND is_deleted = 0 AND node_type = ?',
        whereArgs: <Object?>[nodeId, 'entry'],
        limit: 1);
    if (nodeRows.isEmpty) return null;
    final entryRows = await db.query(tableEntries,
        where: 'node_id = ? AND is_deleted = 0',
        whereArgs: <Object?>[nodeId],
        limit: 1);
    final metaRows = await db.query(tableEntryMeta,
        where: 'node_id = ?',
        whereArgs: <Object?>[nodeId],
        orderBy: 'id ASC');
    final meta = <String, String>{};
    for (final row in metaRows) {
      meta[row['meta_key'] as String] =
          (row['meta_value'] as String?) ?? '';
    }
    return <String, Object?>{
      'node': nodeRows.first,
      'entry': entryRows.isEmpty ? null : entryRows.first,
      'meta': meta,
    };
  }

  /// 时间线：某天（或全部）学习的条目，learned_at 倒序。
  /// 每条带节点标题/成熟度/模板与详情。日报知识段与「今日学习摘要」共用。
  Future<List<Map<String, Object?>>> timeline({
    int? dayStartMs,
    int? dayEndMs,
    int? limit,
  }) async {
    final db = await open();
    var where =
        'e.is_deleted = 0 AND n.is_deleted = 0 AND n.node_type = ? '
        'AND e.learned_at IS NOT NULL';
    final args = <Object?>['entry'];
    if (dayStartMs != null && dayEndMs != null) {
      where += ' AND e.learned_at >= ? AND e.learned_at < ?';
      args..add(dayStartMs)..add(dayEndMs);
    }
    final rows = await db.query(
      '$tableEntries e JOIN $tableNodes n ON e.node_id = n.id',
      columns: <String>[
        'n.id AS node_id', 'n.title AS title', 'n.maturity AS maturity',
        'e.source AS source', 'e.core_summary AS core_summary',
        'e.learned_at AS learned_at', 'e.template AS template',
      ],
      where: where,
      whereArgs: args,
      orderBy: 'e.learned_at DESC',
      limit: limit,
    );
    return rows;
  }

  /// 搜索条目：search_text（标题+一句话核心+来源）LIKE 命中，
  /// 回带 node_type 与 maturity；软删不进结果。
  Future<List<Map<String, Object?>>> searchEntries(String query) async {
    final db = await open();
    final q = query.trim();
    if (q.isEmpty) return const <Map<String, Object?>>[];
    return db.query(
      '$tableEntries e JOIN $tableNodes n ON e.node_id = n.id',
      columns: <String>[
        'n.id AS node_id', 'n.title AS title', 'n.node_type AS node_type',
        'n.maturity AS maturity', 'e.source AS source',
        'e.core_summary AS core_summary', 'e.template AS template',
      ],
      where: 'e.is_deleted = 0 AND n.is_deleted = 0 AND e.search_text LIKE ?',
      whereArgs: <Object?>['%$q%'],
      orderBy: 'e.learned_at DESC',
      limit: 50,
    );
  }

  /// 搜节点（按学科/主题名找树节点），软删不进结果。
  Future<List<Map<String, Object?>>> searchNodes(String query) async {
    final db = await open();
    final q = query.trim();
    if (q.isEmpty) return const <Map<String, Object?>>[];
    return db.query(tableNodes,
        columns: <String>['id', 'title', 'node_type', 'maturity'],
        where: 'is_deleted = 0 AND title LIKE ? AND node_type != ?',
        whereArgs: <Object?>['%$q%', 'entry'],
        orderBy: 'id ASC',
        limit: 20);
  }

  /// 某主题下按模板取条目（创作区）。
  Future<List<Map<String, Object?>>> entriesOfTopic(
      int topicId, {String? template}) async {
    final db = await open();
    var where = 'n.parent_id = ? AND n.is_deleted = 0 '
        'AND n.node_type = ? AND e.is_deleted = 0';
    final args = <Object?>[topicId, 'entry'];
    if (template != null) {
      where += ' AND e.template = ?';
      args.add(template);
    }
    return db.query(
      '$tableNodes n JOIN $tableEntries e ON e.node_id = n.id',
      columns: <String>[
        'n.id AS node_id', 'n.title AS title', 'n.maturity AS maturity',
        'e.source AS source', 'e.core_summary AS core_summary',
        'e.learned_at AS learned_at', 'e.template AS template',
      ],
      where: where,
      whereArgs: args,
      orderBy: 'e.learned_at DESC',
    );
  }

  /// 创作表达的 4 个系统主题（创作区与日报模板名共用；找不到返回空）。
  Future<List<Map<String, Object?>>> creativeTopics() async {
    final all = await subjects();
    for (final s in all) {
      if (s['title'] == '创作表达') {
        return childrenOf(s['id'] as int);
      }
    }
    return const <Map<String, Object?>>[];
  }

  /// 报数口径：N 学科 / M 条目（全系统备份逐域报数与 UI 概览共用）。
  Future<String> countSummary() async {
    final db = await open();
    final subjects = await db.query(tableNodes,
        where: 'is_deleted = 0 AND node_type = ?', whereArgs: <Object?>['subject']);
    final entries = await db.query(tableNodes,
        where: 'is_deleted = 0 AND node_type = ?', whereArgs: <Object?>['entry']);
    return '${subjects.length} 学科 / ${entries.length} 条目';
  }

  // ---------- 写入口（Writer） ----------

  /// 新增学科（根节点）。返回新节点 id。
  Future<int> addSubject(String title) async {
    _guardWrite();
    final db = await open();
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.insert(tableNodes, <String, Object?>{
      'parent_id': null,
      'title': title,
      'node_type': 'subject',
      'maturity': null,
      'is_system': 0,
      'is_deleted': 0,
      'created_at': now,
      'updated_at': now,
      'deleted_at': null,
    });
  }

  /// 新增主题。父节点必须是 subject（树三层封顶：学科→主题→条目）。
  Future<int> addTopic(int parentId, String title) async {
    _guardWrite();
    final parent = await nodeById(parentId);
    if (parent == null || (parent['is_deleted'] as int) != 0) {
      throw ArgumentError.value(parentId, 'parentId', '父节点不存在');
    }
    if (parent['node_type'] != 'subject') {
      throw ArgumentError.value(
          parentId, 'parentId', '主题只能挂在学科下（树三层封顶）');
    }
    final db = await open();
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.insert(tableNodes, <String, Object?>{
      'parent_id': parentId,
      'title': title,
      'node_type': 'topic',
      'maturity': null,
      'is_system': 0,
      'is_deleted': 0,
      'created_at': now,
      'updated_at': now,
      'deleted_at': null,
    });
  }

  /// 新增条目（entry 节点 + entries 详情 + meta 键值）。
  /// 父节点必须是 topic；core_summary 强制非空（对抗遗忘的防线）。
  /// [template] 非空时写入 entries.template 与 meta `_template`。
  Future<int> addEntry(
    int topicId, {
    required String title,
    String? source,
    required String coreSummary,
    int? learnedAt,
    int maturity = 0,
    String? template,
    Map<String, String> meta = const <String, String>{},
  }) async {
    _guardWrite();
    if (coreSummary.trim().isEmpty) {
      throw ArgumentError.value(coreSummary, 'coreSummary', '一句话核心不能为空——说不出来就是没消化');
    }
    final parent = await nodeById(topicId);
    if (parent == null ||
        (parent['is_deleted'] as int) != 0 ||
        parent['node_type'] != 'topic') {
      throw ArgumentError.value(topicId, 'topicId', '条目只能挂在主题下');
    }
    final db = await open();
    final now = DateTime.now().millisecondsSinceEpoch;
    final nodeId = await db.insert(tableNodes, <String, Object?>{
      'parent_id': topicId,
      'title': title,
      'node_type': 'entry',
      'maturity': maturity.clamp(0, 2),
      'is_system': 0,
      'is_deleted': 0,
      'created_at': now,
      'updated_at': now,
      'deleted_at': null,
    });
    await db.insert(tableEntries, <String, Object?>{
      'node_id': nodeId,
      'source': source,
      'core_summary': coreSummary,
      'learned_at': learnedAt,
      'template': template,
      'search_text': _composeSearchText(title, coreSummary, source),
      'is_deleted': 0,
      'created_at': now,
      'updated_at': now,
      'deleted_at': null,
    });
    for (final e in meta.entries) {
      await db.insert(tableEntryMeta, <String, Object?>{
        'node_id': nodeId,
        'meta_key': e.key,
        'meta_value': e.value,
        'created_at': now,
        'updated_at': now,
      });
    }
    return nodeId;
  }

  /// 编辑节点标题（subject/topic/entry 通用）。
  /// entry 改名后 search_text 同步重算（不留脏索引）。
  Future<void> updateNodeTitle(int nodeId, String title) async {
    _guardWrite();
    final node = await nodeById(nodeId);
    if (node == null) {
      throw ArgumentError.value(nodeId, 'nodeId', '节点不存在');
    }
    if ((node['is_system'] as int) == 1) {
      // 系统预置主题：可改名（本方法就是改名口），无额外限制。
    }
    final db = await open();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      tableNodes,
      <String, Object?>{'title': title, 'updated_at': now},
      where: 'id = ?',
      whereArgs: <Object?>[nodeId],
    );
    if (node['node_type'] == 'entry') {
      final rows = await db.query(tableEntries,
          where: 'node_id = ?', whereArgs: <Object?>[nodeId], limit: 1);
      if (rows.isNotEmpty) {
        final e = rows.first;
        await db.update(
          tableEntries,
          <String, Object?>{
            'search_text': _composeSearchText(
              title,
              (e['core_summary'] as String?) ?? '',
              e['source'] as String?,
            ),
            'updated_at': now,
          },
          where: 'node_id = ?',
          whereArgs: <Object?>[nodeId],
        );
      }
    }
  }

  /// 编辑条目详情（source / core_summary / learned_at / maturity / meta）。
  /// [meta] 非 null 时整体替换该条目 meta 键值（模板表单整体保存语义）。
  Future<void> updateEntry(
    int nodeId, {
    String? title,
    String? source,
    String? coreSummary,
    int? learnedAt,
    int? maturity,
    Map<String, String>? meta,
  }) async {
    _guardWrite();
    final db = await open();
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = await db.query(tableEntries,
        where: 'node_id = ?', whereArgs: <Object?>[nodeId], limit: 1);
    if (rows.isEmpty) {
      throw ArgumentError.value(nodeId, 'nodeId', '条目不存在');
    }
    if (coreSummary != null && coreSummary.trim().isEmpty) {
      throw ArgumentError.value(coreSummary, 'coreSummary', '一句话核心不能为空——说不出来就是没消化');
    }
    if (title != null) {
      await updateNodeTitle(nodeId, title);
    }
    final patch = <String, Object?>{'updated_at': now};
    if (source != null) patch['source'] = source;
    if (coreSummary != null) patch['core_summary'] = coreSummary;
    if (learnedAt != null) patch['learned_at'] = learnedAt;
    await db.update(tableEntries, patch,
        where: 'node_id = ?', whereArgs: <Object?>[nodeId]);
    if (maturity != null) {
      await setMaturity(nodeId, maturity);
    }
    // 重算 search_text（core_summary/source 可能变了）。
    final fresh = await db.query(tableNodes,
        where: 'id = ?', whereArgs: <Object?>[nodeId], limit: 1);
    final freshEntry = await db.query(tableEntries,
        where: 'node_id = ?', whereArgs: <Object?>[nodeId], limit: 1);
    if (fresh.isNotEmpty && freshEntry.isNotEmpty) {
      await db.update(
        tableEntries,
        <String, Object?>{
          'search_text': _composeSearchText(
            (fresh.first['title'] as String?) ?? '',
            (freshEntry.first['core_summary'] as String?) ?? '',
            freshEntry.first['source'] as String?,
          ),
          'updated_at': now,
        },
        where: 'node_id = ?',
        whereArgs: <Object?>[nodeId],
      );
    }
    if (meta != null) {
      await db.delete(tableEntryMeta,
          where: 'node_id = ?', whereArgs: <Object?>[nodeId]);
      for (final e in meta.entries) {
        await db.insert(tableEntryMeta, <String, Object?>{
          'node_id': nodeId,
          'meta_key': e.key,
          'meta_value': e.value,
          'created_at': now,
          'updated_at': now,
        });
      }
    }
  }

  /// 标成熟度（只挂 entry）。practice（写作练习）条目锁死 🔴熟果。
  Future<void> setMaturity(int nodeId, int maturity) async {
    _guardWrite();
    final db = await open();
    final node = await nodeById(nodeId);
    if (node == null || node['node_type'] != 'entry') {
      throw ArgumentError.value(nodeId, 'nodeId', '成熟度只挂在条目上');
    }
    // 写作练习：写完即完成，成熟度固定红果（PM 拍板，不给用户改）。
    if ((node['is_system'] as int) == 0) {
      final metaRows = await db.query(tableEntryMeta,
          where: 'node_id = ? AND meta_key = ?',
          whereArgs: <Object?>[nodeId, '_template'],
          limit: 1);
      if (metaRows.isNotEmpty &&
          metaRows.first['meta_value'] == 'practice' &&
          maturity != 2) {
        throw ArgumentError.value(
            maturity, 'maturity', '写作练习条目完成即熟果，不能改成熟度');
      }
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      tableNodes,
      <String, Object?>{'maturity': maturity.clamp(0, 2), 'updated_at': now},
      where: 'id = ?',
      whereArgs: <Object?>[nodeId],
    );
  }

  /// 删除节点：**整棵子树软删**（nodes + entries 行标记，不物理清除）。
  /// knowledge_links 边**不软删**（JOIN 主表过滤，恢复后边自动接回）。
  /// 系统预置主题（is_system=1）不可删。
  Future<int> deleteNode(int nodeId) async {
    _guardWrite();
    final node = await nodeById(nodeId);
    if (node == null) return 0;
    if ((node['is_system'] as int) == 1) {
      throw ArgumentError.value(nodeId, 'nodeId', '系统预置主题不可删除');
    }
    final db = await open();
    final now = DateTime.now().millisecondsSinceEpoch;
    // 子树 = 自引用递归（应用层收集中，语句简单可控）。
    final ids = <int>[nodeId];
    var frontier = <int>[nodeId];
    while (frontier.isNotEmpty) {
      final placeholders =
          List.filled(frontier.length, '?').join(',');
      final rows = await db.query(tableNodes,
          columns: <String>['id'],
          where: 'parent_id IN ($placeholders) AND is_deleted = 0',
          whereArgs: frontier);
      frontier = rows.map((r) => r['id'] as int).toList();
      ids.addAll(frontier);
    }
    final placeholders = List.filled(ids.length, '?').join(',');
    final count = await db.update(
      tableNodes,
      <String, Object?>{'is_deleted': 1, 'deleted_at': now, 'updated_at': now},
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
    await db.update(
      tableEntries,
      <String, Object?>{'is_deleted': 1, 'deleted_at': now, 'updated_at': now},
      where: 'node_id IN ($placeholders)',
      whereArgs: ids,
    );
    return count;
  }

  /// 移动节点（跨主题迁移）。校验：不能挂到自己的后代下（防环）、
  /// 挂后深度不超三层。
  Future<void> moveNode(int nodeId, int newParentId) async {
    _guardWrite();
    final node = await nodeById(nodeId);
    if (node == null) throw ArgumentError.value(nodeId, 'nodeId', '节点不存在');
    final parent = await nodeById(newParentId);
    if (parent == null || (parent['is_deleted'] as int) != 0) {
      throw ArgumentError.value(newParentId, 'newParentId', '目标父节点不存在');
    }
    final type = node['node_type'] as String;
    final parentType = parent['node_type'] as String;
    // 深度约束：subject→topic→entry。entry 必须挂 topic；topic 必须挂 subject。
    if (type == 'entry' && parentType != 'topic') {
      throw ArgumentError.value(newParentId, 'newParentId', '条目只能挂在主题下');
    }
    if (type == 'topic' && parentType != 'subject') {
      throw ArgumentError.value(newParentId, 'newParentId', '主题只能挂在学科下');
    }
    if (type == 'subject') {
      throw ArgumentError.value(nodeId, 'nodeId', '学科是根节点，不能移动');
    }
    // 防环：newParentId 不能在 nodeId 的子树里。
    final db = await open();
    var cursor = newParentId;
    while (cursor != 0) {
      if (cursor == nodeId) {
        throw ArgumentError.value(newParentId, 'newParentId', '不能移动到自己的子树里');
      }
      final row = await db.query(tableNodes,
          columns: <String>['parent_id'],
          where: 'id = ?',
          whereArgs: <Object?>[cursor],
          limit: 1);
      if (row.isEmpty) break;
      final p = row.first['parent_id'] as int?;
      cursor = p ?? 0;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      tableNodes,
      <String, Object?>{'parent_id': newParentId, 'updated_at': now},
      where: 'id = ?',
      whereArgs: <Object?>[nodeId],
    );
  }

  // ---------- 备份（+37 填实：六表全量行；FTS/派生列不备份，恢复后重建） ----------

  /// 导出 knowledge 分区（六表全量行含软删，保证还原保真）。
  /// **不导 search_text**——派生列恢复后由 [_rebuildSearchText] 全量重建
  /// （FTS/派生列是可重建的索引，不是真数据；台账 2026-11-28 留档）。
  Future<Map<String, Object?>> exportBackup() async {
    final db = await open();
    return <String, Object?>{
      'app': 'home_inventory',
      'domain': InventoryDomain.knowledge.id,
      'schemaVersion': version,
      'exportedAt': DateTime.now().millisecondsSinceEpoch,
      tableNodes: await db.query(tableNodes, orderBy: 'id ASC'),
      tableEntries: await db.query(tableEntries, orderBy: 'id ASC'),
      tableTags: await db.query(tableTags, orderBy: 'id ASC'),
      tableEntryTags: await db.query(tableEntryTags, orderBy: 'id ASC'),
      tableLinks: await db.query(tableLinks, orderBy: 'id ASC'),
      tableEntryMeta: await db.query(tableEntryMeta, orderBy: 'id ASC'),
    };
  }

  /// 恢复 knowledge 分区：事务内清空重插（保留原 id），然后重建派生列。
  /// 校验链与仓储账同款（app/domain/schemaVersion），任何一步失败整体回滚。
  Future<void> restoreBackup(Map<String, Object?> data) async {
    if (data['app'] != 'home_inventory') {
      throw ArgumentError.value(data, 'data', '不是本应用的备份文件');
    }
    final backupDomain = data['domain'];
    if (backupDomain != InventoryDomain.knowledge.id) {
      throw ArgumentError.value(
        backupDomain,
        'domain',
        '这是${InventoryDomain.fromId(backupDomain as String?)?.label ?? '其他区域'}'
            '的备份，不能恢复到${InventoryDomain.knowledge.label}',
      );
    }
    if (data['kind'] == 'full_system') {
      throw ArgumentError.value(data['kind'], 'kind',
          '这是全系统备份文件，请用全系统恢复入口');
    }
    final backupVersion = (data['schemaVersion'] as num?)?.toInt();
    if (backupVersion == null || backupVersion > version) {
      throw ArgumentError.value(backupVersion, 'schemaVersion',
          '备份版本高于当前应用支持的数据库版本（$version）');
    }
    _guardWrite();
    final db = await open();
    await db.transaction((txn) async {
      await txn.delete(tableNodes);
      await txn.delete(tableEntries);
      await txn.delete(tableTags);
      await txn.delete(tableEntryTags);
      await txn.delete(tableLinks);
      await txn.delete(tableEntryMeta);
      for (final table in <String>[tableNodes, tableEntries, tableTags,
        tableEntryTags, tableLinks, tableEntryMeta]) {
        for (final row in _rowsOf(data, table)) {
          final clean = <String, Object?>{...row}
            ..remove('search_text'); // 派生列不进库，恢复后重建。
          await txn.insert(table, clean);
        }
      }
    });
    await _rebuildSearchText(db);
  }

  /// 全量重建 search_text 派生列（恢复收口）。
  Future<void> _rebuildSearchText(Database db) async {
    final rows = await db.query(
      '$tableEntries e JOIN $tableNodes n ON e.node_id = n.id',
      columns: <String>['e.node_id AS node_id', 'n.title AS title',
        'e.core_summary AS core_summary', 'e.source AS source'],
    );
    for (final row in rows) {
      await db.update(
        tableEntries,
        <String, Object?>{
          'search_text': _composeSearchText(
            (row['title'] as String?) ?? '',
            (row['core_summary'] as String?) ?? '',
            row['source'] as String?,
          ),
        },
        where: 'node_id = ?',
        whereArgs: <Object?>[row['node_id']],
      );
    }
  }

  /// search_text 组合口径（唯一实现）：标题 + 一句话核心 + 来源，空段跳过。
  static String _composeSearchText(
      String title, String coreSummary, String? source) {
    return <String>[
      title.trim(),
      coreSummary.trim(),
      (source ?? '').trim(),
    ].where((s) => s.isNotEmpty).join(' ');
  }

  static List<Map<String, Object?>> _rowsOf(
      Map<String, Object?> data, String table) {
    final rows = data[table];
    if (rows is List) {
      return rows.whereType<Map>().map((r) {
        return <String, Object?>{
          for (final e in r.entries) e.key: e.value,
        };
      }).toList();
    }
    return <Map<String, Object?>>[];
  }
}

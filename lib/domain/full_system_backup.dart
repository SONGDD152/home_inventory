import '../data/domain.dart';
import '../data/inventory_database.dart';
import '../data/inventory_repository.dart';
import '../data/knowledge_database.dart';
import 'backup_integrity.dart';

/// V4.2.1（+34）：**全系统备份**——生活区 + 工作区两本账打包成**一份 JSON**。
///
/// 背景（V4.1.7 改名迁移演练实锤的痛点）：物理分库后备份按域拆成两份文件，
/// 迁移要先导生活、再切工作导一份，恢复时也要来两轮——多一步就多一次
/// 「漏了某一个域」的机会。本服务把两份合成一份：一次导出、一次恢复。
///
/// 格式（formatVersion=1）：
/// ```json
/// {
///   "app": "home_inventory",
///   "kind": "full_system",
///   "formatVersion": 1,
///   "exportedAt": 1234567890,
///   "domains": {
///     "life": { ...单域备份结构原样（app/domain/schemaVersion/9 表）... },
///     "work": { ...同上... }
///   }
/// }
/// ```
///
/// **域条目沿用单域备份的原结构**——恢复时逐域 delegate 到
/// [InventoryRepository.restoreBackup]，旧域恢复链路里的全部收口
/// （schemaVersion 校验、模型列闸、软删行 quantity 保真、legacy 分配）
/// **一行不重写、天然继承**（两套迟早漂移，铁律）。
///
/// 口径：
/// * 仓储数据覆盖**开放仓储能力的域**（[DomainCapability.storage]，生产：
///   life + work）；
/// * **V4.2.3（+36 终审边界）：全系统文件带知识壳分区**——`domains.knowledge`
///   恒在（无库时是只含归属标识的空壳分区），「三域 JSON：生活+工作+知识」。
///   壳分区不带任何表键，恢复时空壳直接跳过；带表键（未来版本导出）在
///   尚未建库的当前版本上**明确拒绝**，不静默不炸页。旧格式文件（无
///   knowledge 分区）照常兼容；旧版应用恢复新文件会被旧版校验以
///   「不支持的分区」明确拒绝（文案已有，无需旧版改动）；
/// * 恢复前**先整体校验后逐域落库**（结构/域归属/版本全过才开始写第一本账），
///   把「第一本恢复成功第二本失败」的窗口压到只剩磁盘级故障；
/// * 与单域备份**互拒**：全系统文件进分区恢复入口、单域文件进全系统入口，
///   文案都明确指路，不静默。
class FullSystemBackup {
  /// 只收开放仓储能力的域 → 仓储（生产：life + work）。
  ///
  /// [knowledgeStore] 非空 = +37 建库版，knowledge 分区导出真数据；
  /// null = +36 壳形态，knowledge 分区恒空壳（行为与 +36 一字不差）。
  FullSystemBackup({
    required Map<InventoryDomain, InventoryRepository> repositories,
    KnowledgeDatabase? knowledgeStore,
  })  : _repositories =
            Map<InventoryDomain, InventoryRepository>.of(repositories),
        _knowledgeStore = knowledgeStore;

  final Map<InventoryDomain, InventoryRepository> _repositories;

  /// 知识库读写口（null = 未建库形态，knowledge 分区恒空壳）。
  final KnowledgeDatabase? _knowledgeStore;

  /// 全系统备份的类型标识（顶层 `kind` 字段）。
  static const String kindFullSystem = 'full_system';

  /// 格式版本（与 schemaVersion 无关——这是**外层信封**的版本，
  /// 将来信封结构变化时递增，域条目各自的 schemaVersion 照旧独立校验）。
  static const int formatVersion = 1;

  /// 参与全系统备份的域（开放仓储能力的域，枚举序稳定）。
  List<InventoryDomain> get domains => InventoryDomain.values
      .where((d) => domainSupports(d, DomainCapability.storage))
      .toList(growable: false);

  /// 全系统文件分区覆盖的域：仓储域 + 知识壳分区（+36 终审边界，
  /// 三域 JSON）。恢复校验按此白名单放行，未知的分区仍拒。
  List<InventoryDomain> get partitionDomains => InventoryDomain.values;

  /// 知识壳分区：只带归属标识，不带任何表键（未注入 knowledgeStore 时的兜底）。
  Map<String, Object?> _knowledgeShellPartition() => <String, Object?>{
        'app': 'home_inventory',
        'domain': InventoryDomain.knowledge.id,
        'schemaVersion': InventoryDatabase.currentSchemaVersion,
      };

  /// 导出全系统备份。
  ///
  /// 纯读取不改库；任何一域导出失败即整体失败（不让用户拿到半份备份）。
  /// +37 建库版：knowledge 分区导出六表真数据；未注入 store 时仍输出壳分区。
  /// V4.3.1（+38 P0-2）：每个分区导出后先过**完整性校验**（关键字段非空 +
  /// 外键指向存在），不通过整体抛错——坏数据绝不进备份文件。
  Future<Map<String, Object?>> exportAll() async {
    final entries = <String, Object?>{};
    for (final domain in partitionDomains) {
      final repo = _repositories[domain];
      if (repo != null &&
          domainSupports(domain, DomainCapability.storage)) {
        final body = await repo.exportBackup();
        BackupIntegrity.ensureValid(body, knowledge: false);
        entries[domain.id] = body;
      } else if (domain == InventoryDomain.knowledge &&
          _knowledgeStore != null) {
        final body = await _knowledgeStore.exportBackup();
        BackupIntegrity.ensureValid(body, knowledge: true);
        entries[domain.id] = body;
      } else {
        entries[domain.id] = _knowledgeShellPartition();
      }
    }
    return <String, Object?>{
      'app': 'home_inventory',
      'kind': kindFullSystem,
      'formatVersion': formatVersion,
      'exportedAt': DateTime.now().millisecondsSinceEpoch,
      'domains': entries,
    };
  }

  /// 恢复全系统备份：**先整体校验，后逐域落库**。
  ///
  /// 校验（任何一条不过就 ArgumentError，文案可直出 UI）：
  /// ① 顶层 `app` 归属；② `kind` 必须是 full_system（单域文件明确拒 +
  /// 指路）；③ `domains` 是非空映射；④ 每个 key 是已知的仓储域；
  /// ⑤ 域条目的 `domain` 字段与 key 一致（防手改文件错位）；
  /// ⑥ 域条目 `schemaVersion` 不高于当前库。
  ///
  /// 校验全过后逐域 delegate [InventoryRepository.restoreBackup]。
  Future<void> restoreAll(Map<String, Object?> data) async {
    // ① 顶层归属。
    if (data['app'] != 'home_inventory') {
      throw ArgumentError.value(data, 'data', '不是本应用的备份文件');
    }
    // ② 类型互拒：单域文件明确指路。
    if (data['kind'] != kindFullSystem) {
      throw ArgumentError.value(
        data['kind'],
        'kind',
        '这是分区备份（单个区域的文件），'
        '请到「数据管理」对应区域（生活区/工作区）的备份恢复入口恢复',
      );
    }
    // ③ domains 映射。
    final rawDomains = data['domains'];
    if (rawDomains is! Map || rawDomains.isEmpty) {
      throw ArgumentError.value(
        rawDomains,
        'domains',
        '全系统备份缺少各区域的数据（domains）',
      );
    }
    // ④⑤ 逐条校验：key 已知、条目归属一致、版本不高于当前库。
    // V4.2.3：白名单从「仓储域」扩为「分区覆盖域」（含 knowledge 壳分区）。
    final validated = <InventoryDomain, Map<String, Object?>>{};
    for (final entry in rawDomains.entries) {
      final key = '${entry.key}';
      final domain = InventoryDomain.fromId(key);
      if (domain == null || !partitionDomains.contains(domain)) {
        throw ArgumentError.value(
          key,
          'domains',
          '全系统备份里有本应用不支持的分区（$key），可能不是本应用导出的文件',
        );
      }
      final body = entry.value;
      if (body is! Map) {
        throw ArgumentError.value(
          key,
          'domains',
          '分区（${domain.label}）的数据结构不对，可能不是本应用导出的文件',
        );
      }
      final bodyMap = <String, Object?>{
        for (final e in body.entries) '${e.key}': e.value,
      };
      if (bodyMap['app'] != 'home_inventory') {
        throw ArgumentError.value(
          key,
          'domains',
          '分区（${domain.label}）的数据不是本应用导出的',
        );
      }
      if (bodyMap['domain'] != key) {
        throw ArgumentError.value(
          bodyMap['domain'],
          'domain',
          '分区数据与位置不匹配（$key 里放的是别的区域的账），'
              '文件可能被改动过，拒绝恢复',
        );
      }
      final schemaVersion = (bodyMap['schemaVersion'] as num?)?.toInt();
      // 版本上限**按域独立**：knowledge.db 分域版本号（+37 起 v14），
      // 仓储两库 v14（+38 借出补丁起，v13→v14 加 loans.from_location_id）
      // ——分域版本号各自演进（台账留档）。
      final maxVersion = domain == InventoryDomain.knowledge
          ? KnowledgeDatabase.version
          : InventoryDatabase.currentSchemaVersion;
      if (schemaVersion == null || schemaVersion > maxVersion) {
        throw ArgumentError.value(
          schemaVersion,
          'schemaVersion',
          '分区（${domain.label}）的备份版本高于当前应用支持的数据库版本'
              '（$maxVersion）',
        );
      }
      validated[domain] = bodyMap;
    }

    // 校验全过 → 逐域落库（delegate 单域恢复，收口全继承）。
    // 知识分区：+37 建库版真数据恢复（delegate KnowledgeDatabase.restoreBackup）；
    // 未注入 store 时维持 +36 口径——空壳跳过、带表键明确拒绝指路升级。
    for (final entry in validated.entries) {
      if (!_repositories.containsKey(entry.key)) {
        if (entry.key == InventoryDomain.knowledge &&
            _knowledgeStore != null) {
          await _knowledgeStore.restoreBackup(entry.value);
          continue;
        }
        final extraKeys = entry.value.keys
            .where((k) =>
                k != 'app' && k != 'domain' && k != 'schemaVersion')
            .toList();
        if (extraKeys.isNotEmpty) {
          final reason = entry.key == InventoryDomain.knowledge
              ? '（知识库尚未建库）'
              : '（该区域在当前应用未启用）';
          throw ArgumentError.value(
            entry.key,
            'domains',
            '分区（${entry.key}）带有当前应用还不能恢复的数据$reason，'
                '请升级应用后恢复这份备份',
          );
        }
        continue; // 空壳分区：无账可恢复，跳过。
      }
      await _repositories[entry.key]!.restoreBackup(entry.value);
    }
  }

  /// 恢复完成的提示文案：**逐域分行**报核心账行数 + 缺表点名。
  ///
  /// 全系统恢复一次动两本账，行数必须按区分开报，演练核对清单
  /// 才有数字可对（V4.1.7 口径的跨域版）。
  String restoreResultText(Map<String, Object?> data) {
    final rawDomains = data['domains'];
    if (rawDomains is! Map) return '恢复完成。';
    final lines = <String>[];
    for (final entry in rawDomains.entries) {
      final domain = InventoryDomain.fromId('${entry.key}');
      final body = entry.value;
      if (domain == null || body is! Map) continue;
      lines.add(_describeDomain(domain, <String, Object?>{
        for (final e in body.entries) '${e.key}': e.value,
      }));
    }
    return lines.isEmpty ? '恢复完成。' : lines.join('\n');
  }

  String _describeDomain(InventoryDomain domain, Map<String, Object?> body) {
    // 知识分区（+37）：带 nodes 表 → 报「N 学科 / M 条目」；
    // 空壳（无任何表键）→ 报一行状态。
    if (domain == InventoryDomain.knowledge) {
      if (!body.containsKey(KnowledgeDatabase.tableNodes)) {
        return '知识系统：暂无数据（备份通道已就绪，知识库建库后自动纳入）';
      }
      int nodeCount(String type) {
        final rows = body[KnowledgeDatabase.tableNodes] as List? ?? const [];
        return rows.whereType<Map>().where((r) => r['node_type'] == type).length;
      }

      return '知识系统：${nodeCount('subject')} 学科 / '
          '${nodeCount('entry')} 条目';
    }
    int countOf(String table) => (body[table] as List?)?.length ?? 0;
    final parts = <String>[
      '物品 ${countOf(InventoryDatabase.tableItems)} 条',
      '日程 ${countOf(InventoryDatabase.tableReminders)} 条',
      '催办状态 ${countOf(InventoryDatabase.tableTodoStates)} 条',
      '借出 ${countOf(InventoryDatabase.tableLoans)} 条',
      '日报 ${countOf(InventoryDatabase.tableDailyReports)} 条',
    ];
    const missingLabels = <String, String>{
      InventoryDatabase.tableReminders: '日程',
      InventoryDatabase.tableDailyReports: '日报',
      InventoryDatabase.tableTodoStates: '催办状态',
      InventoryDatabase.tableLoans: '借出记录',
      InventoryDatabase.tableBorrowers: '借阅人',
      InventoryDatabase.tableItemDiscards: '废弃流水',
    };
    final missing = missingLabels.entries
        .where((e) => !body.containsKey(e.key))
        .map((e) => e.value)
        .toList();
    final head = '${domain.label}：${parts.join('、')}';
    return missing.isEmpty
        ? head
        : '$head（注意：${domain.label}这份备份导出较早，'
            '不含${missing.join('、')}，无法找回）';
  }
}

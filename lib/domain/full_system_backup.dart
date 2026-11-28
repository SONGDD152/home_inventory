import '../data/domain.dart';
import '../data/inventory_database.dart';
import '../data/inventory_repository.dart';

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
/// * 只覆盖**开放仓储能力的域**（[DomainCapability.storage]）——知识域
///   壳实例没有账可备，永不出现；
/// * 恢复前**先整体校验后逐域落库**（结构/域归属/版本全过才开始写第一本账），
///   把「第一本恢复成功第二本失败」的窗口压到只剩磁盘级故障；
/// * 与单域备份**互拒**：全系统文件进分区恢复入口、单域文件进全系统入口，
///   文案都明确指路，不静默。
class FullSystemBackup {
  /// 只收开放仓储能力的域 → 仓储（生产：life + work）。
  FullSystemBackup({required Map<InventoryDomain, InventoryRepository> repositories})
      : _repositories = Map<InventoryDomain, InventoryRepository>.of(repositories);

  final Map<InventoryDomain, InventoryRepository> _repositories;

  /// 全系统备份的类型标识（顶层 `kind` 字段）。
  static const String kindFullSystem = 'full_system';

  /// 格式版本（与 schemaVersion 无关——这是**外层信封**的版本，
  /// 将来信封结构变化时递增，域条目各自的 schemaVersion 照旧独立校验）。
  static const int formatVersion = 1;

  /// 参与全系统备份的域（开放仓储能力的域，枚举序稳定）。
  List<InventoryDomain> get domains => InventoryDomain.values
      .where((d) => domainSupports(d, DomainCapability.storage))
      .toList(growable: false);

  /// 导出全系统备份。
  ///
  /// 纯读取不改库；任何一域导出失败即整体失败（不让用户拿到半份备份）。
  Future<Map<String, Object?>> exportAll() async {
    final entries = <String, Object?>{};
    for (final domain in domains) {
      entries[domain.id] = await _repositories[domain]!.exportBackup();
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
        '请到对应区域的「数据管理 → 分区备份」页签恢复',
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
    final validated = <InventoryDomain, Map<String, Object?>>{};
    for (final entry in rawDomains.entries) {
      final key = '${entry.key}';
      final domain = InventoryDomain.fromId(key);
      if (domain == null || !domains.contains(domain)) {
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
      if (schemaVersion == null ||
          schemaVersion > InventoryDatabase.currentSchemaVersion) {
        throw ArgumentError.value(
          schemaVersion,
          'schemaVersion',
          '分区（${domain.label}）的备份版本高于当前应用支持的数据库版本'
              '（${InventoryDatabase.currentSchemaVersion}）',
        );
      }
      validated[domain] = bodyMap;
    }

    // 校验全过 → 逐域落库（delegate 单域恢复，收口全继承）。
    for (final entry in validated.entries) {
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

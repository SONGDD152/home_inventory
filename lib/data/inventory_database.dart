import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'item.dart';
import 'inventory_repository.dart';
import 'normalize.dart';

/// 家庭仓储数据访问层（三张表：物品 / 位置 / 关联）。
///
/// 关系模型：
///  * 一件物品可以放在多个位置；一个位置可以放多件物品（多对多）；
///  * [tableItemLocations] 是关联表，用 (item_id, location_id) 唯一约束防重复。
///
/// 依赖可注入：[databaseFactory]（生产用 sqflite 默认工厂，测试注入 ffi）、
/// [databasePath]（测试指向临时文件库，验证重开仍有数据）。
///
/// 这里不解析自然语言；「梯子在哪」的拆分由上层完成，本层只接收精确字段值。
class InventoryDatabase implements InventoryRepository {
  /// 生产构造：不暴露任何测试钩子，生产入口 main.dart 用此构造。
  InventoryDatabase({
    DatabaseFactory? databaseFactory,
    String? databasePath,
    this.version = 5,
  })  : _injectedFactory = databaseFactory,
        _injectedPath = databasePath,
        _migrationFailureHook = null,
        _migrationV5FailureHook = null;

  /// 测试专用构造：注入迁移失败钩子，验证 onUpgrade 事务整体回滚。
  /// 仅供测试使用，生产代码路径不调用（见 V1_ACCEPTANCE.md R2）。
  /// 两个钩子分别覆盖 v4 名称清洗与 v5 加列阶段的失败回滚。
  InventoryDatabase.forTesting({
    DatabaseFactory? databaseFactory,
    String? databasePath,
    this.version = 5,
    void Function()? migrationFailureHook,
    void Function()? migrationV5FailureHook,
  })  : _injectedFactory = databaseFactory,
        _injectedPath = databasePath,
        _migrationFailureHook = migrationFailureHook,
        _migrationV5FailureHook = migrationV5FailureHook;

  static const String tableItems = 'items';
  static const String tableLocations = 'locations';
  static const String tableItemLocations = 'item_locations';

  static const String columnId = 'id';
  static const String columnName = 'name';
  static const String columnItemId = 'item_id';
  static const String columnLocationId = 'location_id';
  static const String columnIsDeleted = 'is_deleted';
  static const String columnCreatedAt = 'created_at';
  static const String columnUpdatedAt = 'updated_at';
  // V3 交互说明新增列（可空，兼容 v4 旧库）。
  static const String columnRemark = 'remark';
  static const String columnRawText = 'raw_text';
  static const String columnTags = 'tags';

  /// 未删除记录的唯一约束：物品名唯一、位置名唯一、同一(物品,位置)关联唯一。
  static const String itemsUniqueIndex = 'idx_items_name_unique';
  static const String locationsUniqueIndex = 'idx_locations_name_unique';
  static const String associationUniqueIndex = 'idx_assoc_item_location_unique';

  /// 名称长度上限，超出抛 ArgumentError（超长位置是明确的验收点）。
  static const int maxNameLength = 100;

  final DatabaseFactory? _injectedFactory;
  final String? _injectedPath;
  final int version;

  /// 仅供测试的失败注入点：在 v4 清洗的清表之后、重建之前调用。
  /// 私有字段，仅 [InventoryDatabase.forTesting] 可注入，生产构造恒为 null。
  final void Function()? _migrationFailureHook;

  /// 技术审核条件③：v5 加列事务的失败注入点，在 remark 加完、另两列之前调用，
  /// 验证三段 ALTER 包在一个事务里、失败整体回滚不留半迁移态。
  /// 私有字段，仅 [InventoryDatabase.forTesting] 可注入，生产构造恒为 null。
  final void Function()? _migrationV5FailureHook;

  Database? _db;

  DatabaseFactory get _factory => _injectedFactory ?? databaseFactory;

  Future<String> _resolvePath() async {
    final injected = _injectedPath;
    if (injected != null) return injected;
    return p.join(await getDatabasesPath(), 'home_inventory.db');
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
    return db;
  }

  bool get isOpen => _db?.isOpen ?? false;

  Future<void> close() async {
    final db = _db;
    _db = null;
    if (db != null && db.isOpen) await db.close();
  }

  Future<void> _onCreate(Database db, int newVersion) async {
    await db.execute('''
      CREATE TABLE $tableItems (
        $columnId INTEGER PRIMARY KEY AUTOINCREMENT,
        $columnName TEXT NOT NULL,
        $columnIsDeleted INTEGER NOT NULL DEFAULT 0,
        $columnCreatedAt INTEGER NOT NULL,
        $columnUpdatedAt INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE $tableLocations (
        $columnId INTEGER PRIMARY KEY AUTOINCREMENT,
        $columnName TEXT NOT NULL,
        $columnIsDeleted INTEGER NOT NULL DEFAULT 0,
        $columnCreatedAt INTEGER NOT NULL,
        $columnUpdatedAt INTEGER NOT NULL,
        $columnRemark TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE $tableItemLocations (
        $columnId INTEGER PRIMARY KEY AUTOINCREMENT,
        $columnItemId INTEGER NOT NULL,
        $columnLocationId INTEGER NOT NULL,
        $columnIsDeleted INTEGER NOT NULL DEFAULT 0,
        $columnCreatedAt INTEGER NOT NULL,
        $columnUpdatedAt INTEGER NOT NULL,
        $columnRawText TEXT,
        $columnTags TEXT
      )
    ''');
    await _createIndexes(db);
  }

  Future<void> _createIndexes(Database db) async {
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS $itemsUniqueIndex '
      'ON $tableItems($columnName) WHERE $columnIsDeleted = 0',
    );
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS $locationsUniqueIndex '
      'ON $tableLocations($columnName) WHERE $columnIsDeleted = 0',
    );
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS $associationUniqueIndex '
      'ON $tableItemLocations($columnItemId, $columnLocationId) '
      'WHERE $columnIsDeleted = 0',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_assoc_location '
      'ON $tableItemLocations($columnLocationId)',
    );
  }

  /// v1/v2 是单表 items(name, location, ...)；v3 改三张表；v4 起所有名称走
  /// [normalizeName] 单一入口。升级时按顺序补齐缺失的版本。
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 3) {
      // v1/v2 单表 → v3 三张表：每条旧 (name, location) 转成物品 + 位置 + 关联。
      List<Map<String, Object?>> legacyRows = const <Map<String, Object?>>[];
      try {
        legacyRows = await db.query(tableItems);
      } catch (_) {
        // 旧表不存在时按空库处理。
      }

      await db.execute('DROP TABLE IF EXISTS $tableItemLocations');
      await db.execute('DROP TABLE IF EXISTS $tableLocations');
      await db.execute('DROP TABLE IF EXISTS $tableItems');
      await _onCreate(db, 3);

      final now = DateTime.now().millisecondsSinceEpoch;
      for (final row in legacyRows) {
        final name = row['name'] as String?;
        final location = row['location'] as String?;
        if (name == null || location == null) continue;
        final itemName = normalizeName(name);
        final locationName = normalizeName(location);
        if (itemName.isEmpty || locationName.isEmpty) continue;
        final itemId = await _findOrCreateItem(db, itemName, now);
        final locationId = await _findOrCreateLocation(db, locationName, now);
        await _link(db, itemId, locationId, now);
      }
    }

    if (oldVersion < 4 && newVersion >= 4) {
      await _normalizeLegacyNames(db);
    }

    // v4 → v5：V3 交互说明新增三列（位置备注 remark、记录原文 raw_text、
    // 记录标签 tags）。用 ALTER TABLE ADD COLUMN，对已有数据零破坏、无需清表。
    // 幂等保护：重复升级（如测试中手工指定版本）时先探测列是否已存在。
    if (oldVersion < 5 && newVersion >= 5) {
      await _addColumnIfMissing(db, tableLocations, columnRemark);
      // 失败注入点：remark 已加、另两列未加时抛错。onUpgrade 在 sqflite 升级
      // 事务内，异常必须让三段 ALTER 整体回滚、版本退回 4（见回滚测试）。
      final v5Hook = _migrationV5FailureHook;
      if (v5Hook != null) v5Hook();
      await _addColumnIfMissing(db, tableItemLocations, columnRawText);
      await _addColumnIfMissing(db, tableItemLocations, columnTags);
    }
  }

  /// 若表中无此列则 ALTER ADD；列已存在则跳过（升级幂等）。
  Future<void> _addColumnIfMissing(
      DatabaseExecutor db, String table, String column) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    final exists = rows.any((row) => row['name'] == column);
    if (exists) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $column TEXT');
  }

  /// v3 → v4：历史数据名称归一化清洗。
  ///
  /// 旧版本存的是原始输入（如「梯子 」「ＬＡＤＤＥＲ」），v4 起写入/查询都走
  /// [normalizeName]。若不清洗，历史记录用新逻辑查不到、会被重复插入。
  ///
  /// 单人家庭仓储数据量小，采用"读出有效数据 → 归一化 → 重建"：归一化后同名
  /// 自动合并、重复关联由 [_link] 幂等消除。全过程在 sqflite 升级事务内完成，
  /// 任一步失败整体回滚。软删除记录与时间戳不迁移（V1 无删除入口）。
  Future<void> _normalizeLegacyNames(DatabaseExecutor db) async {
    final itemRows = await db.query(
      tableItems,
      columns: <String>[columnName],
      where: '$columnIsDeleted = 0',
    );
    final locationRows = await db.query(
      tableLocations,
      columns: <String>[columnName],
      where: '$columnIsDeleted = 0',
    );
    final assocRows = await db.rawQuery(
      'SELECT i.$columnName AS item_name, l.$columnName AS loc_name '
      'FROM $tableItemLocations AS a '
      'INNER JOIN $tableItems AS i ON a.$columnItemId = i.$columnId '
      'INNER JOIN $tableLocations AS l ON a.$columnLocationId = l.$columnId '
      'WHERE a.$columnIsDeleted = 0 '
      'AND i.$columnIsDeleted = 0 AND l.$columnIsDeleted = 0',
    );

    final itemNames = <String>{
      for (final row in itemRows) normalizeName(row[columnName] as String),
    }..remove('');
    final locationNames = <String>{
      for (final row in locationRows) normalizeName(row[columnName] as String),
    }..remove('');

    await db.delete(tableItemLocations);
    await db.delete(tableItems);
    await db.delete(tableLocations);

    // 测试失败注入：此刻旧数据已清空、新数据未写入，若抛异常必须整段回滚。
    final hook = _migrationFailureHook;
    if (hook != null) hook();

    final now = DateTime.now().millisecondsSinceEpoch;
    final itemIds = <String, int>{};
    for (final name in itemNames) {
      itemIds[name] = await db.insert(
        tableItems,
        Item(name: name, createdAt: now, updatedAt: now).toMap(),
      );
    }
    final locationIds = <String, int>{};
    for (final name in locationNames) {
      locationIds[name] = await db.insert(
        tableLocations,
        Location(name: name, createdAt: now, updatedAt: now).toMap(),
      );
    }
    for (final row in assocRows) {
      final itemId = itemIds[normalizeName(row['item_name'] as String)];
      final locationId = locationIds[normalizeName(row['loc_name'] as String)];
      if (itemId == null || locationId == null) continue;
      await _link(db, itemId, locationId, now);
    }
  }

  /// 校验并归一化名称：走共用 [normalizeName] 单一入口（trim + 全角转半角 + 大小写不敏感），
  /// 再做非空、长度校验。存库路径与去重比较都用本方法的返回值，保证同源。
  String _normalizeName(String value, String field) {
    final normalized = normalizeName(value);
    if (normalized.isEmpty) {
      throw ArgumentError.value(value, field, '$field 不能为空');
    }
    if (normalized.length > maxNameLength) {
      throw ArgumentError.value(value, field, '$field 不能超过 $maxNameLength 个字符');
    }
    return normalized;
  }

  Future<int> _findOrCreateItem(DatabaseExecutor db, String name, int now) async {
    final rows = await db.query(
      tableItems,
      columns: <String>[columnId],
      where: '$columnName = ? AND $columnIsDeleted = 0',
      whereArgs: <Object?>[name],
      limit: 1,
    );
    if (rows.isNotEmpty) return rows.first[columnId] as int;
    return db.insert(
      tableItems,
      Item(name: name, createdAt: now, updatedAt: now).toMap(),
    );
  }

  Future<int> _findOrCreateLocation(DatabaseExecutor db, String name, int now,
      {String? remark}) async {
    final rows = await db.query(
      tableLocations,
      columns: <String>[columnId],
      where: '$columnName = ? AND $columnIsDeleted = 0',
      whereArgs: <Object?>[name],
      limit: 1,
    );
    if (rows.isNotEmpty) return rows.first[columnId] as int;
    return db.insert(
      tableLocations,
      Location(name: name, createdAt: now, updatedAt: now, remark: remark)
          .toMap(),
    );
  }

  Future<int> _link(DatabaseExecutor db, int itemId, int locationId, int now,
      {String? rawText}) async {
    final rows = await db.query(
      tableItemLocations,
      columns: <String>[columnId],
      where: '$columnItemId = ? AND $columnLocationId = ? AND $columnIsDeleted = 0',
      whereArgs: <Object?>[itemId, locationId],
      limit: 1,
    );
    if (rows.isNotEmpty) return rows.first[columnId] as int;
    return db.insert(
      tableItemLocations,
      ItemLocation(
        itemId: itemId,
        locationId: locationId,
        createdAt: now,
        updatedAt: now,
        rawText: rawText,
      ).toMap(),
    );
  }

  /// 新增一个可选位置（trim、非空、超长校验）。同名未删除位置幂等返回原 id。
  /// V3：可选 [remark] 备注随新位置写入；命中已有位置时备注不变（幂等语义不变）。
  @override
  Future<int> addLocation(String name, {String? remark}) async {
    final valid = _normalizeName(name, '位置名称');
    final db = await open();
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.transaction<int>(
        (txn) => _findOrCreateLocation(txn, valid, now, remark: remark));
  }

  /// V3：编辑未删除位置的名称与备注。名称走共用归一化与校验。
  /// 改名撞到另一个未删除位置（唯一索引）时抛 ArgumentError，由 UI 兜底提示。
  @override
  Future<void> updateLocation(int id, {String? name, String? remark}) async {
    final db = await open();
    final now = DateTime.now().millisecondsSinceEpoch;
    final updates = <String, Object?>{columnUpdatedAt: now};
    if (name != null) updates[columnName] = _normalizeName(name, '位置名称');
    if (remark != null) updates[columnRemark] = remark;
    if (updates.length == 1) return; // 只有时间戳，无需更新。
    await db.update(
      tableLocations,
      updates,
      where: '$columnId = ? AND $columnIsDeleted = 0',
      whereArgs: <Object?>[id],
    );
  }

  /// V3：软删除位置。删除后不再出现在位置列表与查询关联里（沿用 v4 软删策略）。
  @override
  Future<void> deleteLocation(int id) async {
    final db = await open();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      tableLocations,
      <String, Object?>{columnIsDeleted: 1, columnUpdatedAt: now},
      where: '$columnId = ? AND $columnIsDeleted = 0',
      whereArgs: <Object?>[id],
    );
  }

  /// 列出全部未删除位置，供界面选择。按名称排序。
  @override
  Future<List<Location>> getAllLocations() async {
    final db = await open();
    final rows = await db.query(
      tableLocations,
      where: '$columnIsDeleted = 0',
      orderBy: '$columnName ASC',
    );
    return rows.map(Location.fromMap).toList(growable: false);
  }

  /// 按 id 取未删除位置。
  Future<Location?> getLocationById(int id) async {
    final db = await open();
    final rows = await db.query(
      tableLocations,
      where: '$columnId = ? AND $columnIsDeleted = 0',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Location.fromMap(rows.first);
  }

  /// 幂等录入：物品名 + 位置 id。
  ///
  /// 查重与写入在同一事务内，命中已有 (物品,位置) 关联只刷新时间戳、返回原 id。
  /// 界面连点两下不会产生重复关联。名称做 trim 与长度校验。
  @override
  Future<UpsertResult> upsertItemLocation(String itemName, int locationId,
      {String? rawText}) async {
    final valid = _normalizeName(itemName, '物品名称');
    final db = await open();

    final locationRows = await db.query(
      tableLocations,
      columns: <String>[columnId],
      where: '$columnId = ? AND $columnIsDeleted = 0',
      whereArgs: <Object?>[locationId],
      limit: 1,
    );
    if (locationRows.isEmpty) {
      throw ArgumentError.value(locationId, 'locationId', '位置不存在或已删除');
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    return db.transaction<UpsertResult>((txn) async {
      final itemId = await _findOrCreateItem(txn, valid, now);
      final rows = await txn.query(
        tableItemLocations,
        columns: <String>[columnId, columnCreatedAt],
        where: '$columnItemId = ? AND $columnLocationId = ? AND $columnIsDeleted = 0',
        whereArgs: <Object?>[itemId, locationId],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        final linkId = rows.first[columnId] as int;
        await txn.update(
          tableItemLocations,
          <String, Object?>{columnUpdatedAt: now},
          where: '$columnId = ?',
          whereArgs: <Object?>[linkId],
        );
        return UpsertResult(
          itemId: itemId,
          locationId: locationId,
          created: false,
        );
      }
      await _link(txn, itemId, locationId, now, rawText: rawText);
      return UpsertResult(itemId: itemId, locationId: locationId, created: true);
    });
  }

  /// 按精确名称查询，返回该物品及其全部未删除位置（同名多位置全量）。
  /// 名称走共用 [normalizeName] 归一化（与存库同源）；空名或非精确（如「梯」查「梯子」）都查不到。
  @override
  Future<ItemWithLocations?> findByName(String name) async {
    final key = normalizeName(name);
    if (key.isEmpty) return null;
    final db = await open();
    final itemRows = await db.query(
      tableItems,
      where: '$columnName = ? AND $columnIsDeleted = 0',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    if (itemRows.isEmpty) return null;
    final item = Item.fromMap(itemRows.first);

    final rows = await db.rawQuery(
      'SELECT loc.$columnId AS loc_id, loc.$columnName AS loc_name, '
      'loc.$columnIsDeleted AS loc_deleted, '
      'loc.$columnCreatedAt AS loc_created, '
      'loc.$columnUpdatedAt AS loc_updated '
      'FROM $tableItemLocations AS assoc '
      'INNER JOIN $tableLocations AS loc ON assoc.$columnLocationId = loc.$columnId '
      'WHERE assoc.$columnItemId = ? AND assoc.$columnIsDeleted = 0 '
      'AND loc.$columnIsDeleted = 0 '
      'ORDER BY loc.$columnName ASC',
      <Object?>[item.id],
    );
    final locations = rows
        .map(
          (row) => Location(
            id: row['loc_id'] as int,
            name: row['loc_name'] as String,
            isDeleted: (row['loc_deleted'] as int) == 1,
            createdAt: (row['loc_created'] as num).toInt(),
            updatedAt: (row['loc_updated'] as num).toInt(),
          ),
        )
        .toList(growable: false);
    return ItemWithLocations(item: item, locations: locations);
  }

  /// 全部未删除物品（按名称排序）。
  Future<List<Item>> getAllItems() async {
    final db = await open();
    final rows = await db.query(
      tableItems,
      where: '$columnIsDeleted = 0',
      orderBy: '$columnName ASC',
    );
    return rows.map(Item.fromMap).toList(growable: false);
  }

  /// 调试/验收用：统计未删除关联数。
  Future<int> countActiveAssociations() async {
    final db = await open();
    final rows = await db.query(
      tableItemLocations,
      columns: <String>['COUNT(*) AS n'],
      where: '$columnIsDeleted = 0',
    );
    return (rows.first['n'] as num).toInt();
  }
}

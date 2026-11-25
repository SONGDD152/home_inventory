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
    this.version = 8,
  })  : _injectedFactory = databaseFactory,
        _injectedPath = databasePath,
        _migrationFailureHook = null,
        _migrationV5FailureHook = null,
        _migrationV6FailureHook = null,
        _migrationV7FailureHook = null,
        _migrationV8FailureHook = null;

  /// 测试专用构造：注入迁移失败钩子，验证 onUpgrade 事务整体回滚。
  /// 仅供测试使用，生产代码路径不调用（见 V1_ACCEPTANCE.md R2）。
  /// 四个钩子分别覆盖 v4 名称清洗、v5 加列与 v6 加列阶段的失败回滚。
  InventoryDatabase.forTesting({
    DatabaseFactory? databaseFactory,
    String? databasePath,
    this.version = 8,
    void Function()? migrationFailureHook,
    void Function()? migrationV5FailureHook,
    void Function()? migrationV6FailureHook,
    void Function()? migrationV7FailureHook,
    void Function()? migrationV8FailureHook,
  })  : _injectedFactory = databaseFactory,
        _injectedPath = databasePath,
        _migrationFailureHook = migrationFailureHook,
        _migrationV5FailureHook = migrationV5FailureHook,
        _migrationV6FailureHook = migrationV6FailureHook,
        _migrationV7FailureHook = migrationV7FailureHook,
        _migrationV8FailureHook = migrationV8FailureHook;

  static const String tableItems = 'items';
  static const String tableLocations = 'locations';
  static const String tableItemLocations = 'item_locations';
  // V3.7 借阅管理：借阅人表 + 借出记录表。
  static const String tableBorrowers = 'borrowers';
  static const String tableLoans = 'loans';

  static const String columnId = 'id';
  static const String columnName = 'name';
  static const String columnItemId = 'item_id';
  static const String columnLocationId = 'location_id';
  static const String columnIsDeleted = 'is_deleted';
  static const String columnCreatedAt = 'created_at';
  static const String columnUpdatedAt = 'updated_at';
  // V3.6 回收站：物品软删（进回收站）时间戳（可空，兼容 v5 旧库）。
  static const String columnDeletedAt = 'deleted_at';
  // V3 交互说明新增列（可空，兼容 v4 旧库）。
  static const String columnRemark = 'remark';
  static const String columnRawText = 'raw_text';
  static const String columnTags = 'tags';
  // V3.7：物品数量（items）+ 借出记录字段（loans）。
  static const String columnQuantity = 'quantity';
  static const String columnItemName = 'item_name';
  static const String columnBorrowerName = 'borrower_name';
  static const String columnReturnedQty = 'returned_qty';
  static const String columnBorrowedAt = 'borrowed_at';
  static const String columnDueAt = 'due_at';
  static const String columnReturnedAt = 'returned_at';
  static const String columnIsPartial = 'is_partial';

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

  /// V3.6：v6 加列事务的失败注入点（deleted_at 加列前调用），
  /// 验证失败整体回滚、版本退回 5。私有字段，仅 forTesting 可注入。
  final void Function()? _migrationV6FailureHook;

  /// V3.7：v7 迁移失败注入点（建新表前调用），验证整体回滚、版本退回 6。
  /// 私有字段，仅 forTesting 可注入。
  final void Function()? _migrationV7FailureHook;

  /// V3.8：v8 迁移失败注入点（loans 加软删两列前调用），验证整体回滚、版本退回 7。
  /// 私有字段，仅 forTesting 可注入。
  final void Function()? _migrationV8FailureHook;

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
        $columnUpdatedAt INTEGER NOT NULL,
        $columnDeletedAt INTEGER,
        $columnQuantity INTEGER NOT NULL DEFAULT 1
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
    await _createBorrowTables(db);
    await _createIndexes(db);
  }

  /// V3.7：借阅人表 + 借出记录表。
  /// loans 冗余 item_name / borrower_name 快照：改名或软删借阅人后历史仍可读。
  /// V3.8：loans 增软删两列（is_deleted / deleted_at）——借出记录可进回收站。
  Future<void> _createBorrowTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableBorrowers (
        $columnId INTEGER PRIMARY KEY AUTOINCREMENT,
        $columnName TEXT NOT NULL,
        $columnIsDeleted INTEGER NOT NULL DEFAULT 0,
        $columnCreatedAt INTEGER NOT NULL,
        $columnUpdatedAt INTEGER NOT NULL,
        $columnDeletedAt INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableLoans (
        $columnId INTEGER PRIMARY KEY AUTOINCREMENT,
        $columnItemId INTEGER NOT NULL,
        $columnItemName TEXT NOT NULL,
        $columnBorrowerName TEXT NOT NULL,
        $columnQuantity INTEGER NOT NULL DEFAULT 1,
        $columnReturnedQty INTEGER NOT NULL DEFAULT 0,
        $columnBorrowedAt INTEGER NOT NULL,
        $columnDueAt INTEGER NOT NULL,
        $columnReturnedAt INTEGER,
        $columnIsPartial INTEGER NOT NULL DEFAULT 0,
        $columnUpdatedAt INTEGER NOT NULL,
        $columnIsDeleted INTEGER NOT NULL DEFAULT 0,
        $columnDeletedAt INTEGER
      )
    ''');
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
    // V3.7：借阅人名唯一（活跃行）、借出记录按到期日/物品索引。
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_borrowers_name_unique '
      'ON $tableBorrowers($columnName) WHERE $columnIsDeleted = 0',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_loans_due '
      'ON $tableLoans($columnDueAt)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_loans_item '
      'ON $tableLoans($columnItemId)',
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
        final itemId = await _findOrCreateItem(db, itemName, now,
            includeQuantity: false);
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

    // v5 → v6：V3.6 回收站新增物品删除时间戳 deleted_at（可空）。
    // 注意：is_deleted 列 v5 建表即有，**不可**再 ALTER（duplicate column），
    // 此处仅加 deleted_at。老数据 NULL，不迁移历史软删行的时间。
    if (oldVersion < 6 && newVersion >= 6) {
      // 失败注入点：加列前抛错，验证整体回滚、版本退回 5（见回滚测试）。
      final v6Hook = _migrationV6FailureHook;
      if (v6Hook != null) v6Hook();
      await _addColumnIfMissing(db, tableItems, columnDeletedAt,
          type: 'INTEGER');
    }

    // v6 → v7：V3.7 借阅管理——items 加 quantity（默认 1），
    // 新建 borrowers / loans 两张表。
    // 注意 oldVersion<3 时上面已走 _onCreate(db,3) 建的是 v3 三表结构，
    // 不含 quantity/借出表，所以这里统一按 oldVersion<7 判断补齐。
    if (oldVersion < 7 && newVersion >= 7) {
      // 失败注入点：在建表/加列前抛错，验证整体回滚、版本退回 6。
      final v7Hook = _migrationV7FailureHook;
      if (v7Hook != null) v7Hook();
      await _addColumnIfMissing(db, tableItems, columnQuantity,
          type: 'INTEGER NOT NULL DEFAULT 1');
      await _createBorrowTables(db);
      // 索引单独补（_createBorrowTables 里的索引在 _createIndexes 中，
      // 升级路径不会走 _createIndexes，这里补建借阅相关索引）。
      await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_borrowers_name_unique '
        'ON $tableBorrowers($columnName) WHERE $columnIsDeleted = 0',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_loans_due ON $tableLoans($columnDueAt)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_loans_item ON $tableLoans($columnItemId)',
      );
    }

    // v7 → v8：V3.8 借出记录可删除——loans 增软删两列
    // （is_deleted / deleted_at）。老库默认 is_deleted=0，历史记录全部视为
    // 未删，不会因为升级而从列表里消失。
    // 注意：is_deleted 与 items 表同名不同表，_addColumnIfMissing 先探测
    // 列是否存在，重复升级幂等（v6→v7 路径已建带列新表时直接跳过）。
    if (oldVersion < 8 && newVersion >= 8) {
      // 失败注入点：加列前抛错，验证整体回滚、版本退回 7。
      final v8Hook = _migrationV8FailureHook;
      if (v8Hook != null) v8Hook();
      await _addColumnIfMissing(db, tableLoans, columnIsDeleted,
          type: 'INTEGER NOT NULL DEFAULT 0');
      await _addColumnIfMissing(db, tableLoans, columnDeletedAt,
          type: 'INTEGER');
    }
  }

  /// 若表中无此列则 ALTER ADD；列已存在则跳过（升级幂等）。
  /// [type] 指定列类型（v5 三列是 TEXT；v6 的 deleted_at 是 INTEGER）。
  Future<void> _addColumnIfMissing(
      DatabaseExecutor db, String table, String column,
      {String type = 'TEXT'}) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    final exists = rows.any((row) => row['name'] == column);
    if (exists) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $column $type');
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
        Item(name: name, createdAt: now, updatedAt: now)
            .toMap(includeQuantity: false),
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

  Future<int> _findOrCreateItem(DatabaseExecutor db, String name, int now,
      {int quantity = 1, bool includeQuantity = true}) async {
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
      Item(name: name, createdAt: now, updatedAt: now, quantity: quantity)
          .toMap(includeQuantity: includeQuantity),
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

  /// V3.2：编辑未删除物品的名称。名称走共用归一化与校验（与位置侧同源）。
  ///
  /// 撞名检查只针对**未删除**物品（is_deleted=0，排除自身）——已删除物品
  /// 允许同名复活：部分唯一索引只约束活跃行，复活会插入新行、新 id，
  /// 历史软删行不受影响（技术审核确认点①的口径）。
  /// 事务内「预检查 + 写入」：预检查命中抛 ArgumentError（友好中文），
  /// 部分唯一索引兜底并发写。
  @override
  Future<void> updateItem(int id, String name) async {
    final valid = _normalizeName(name, '物品名称');
    final db = await open();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction<void>((txn) async {
      final rows = await txn.query(
        tableItems,
        columns: <String>[columnId],
        where: '$columnName = ? AND $columnIsDeleted = 0 AND $columnId != ?',
        whereArgs: <Object?>[valid, id],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        throw ArgumentError.value(name, 'name', '已存在同名物品');
      }
      await txn.update(
        tableItems,
        <String, Object?>{columnName: valid, columnUpdatedAt: now},
        where: '$columnId = ? AND $columnIsDeleted = 0',
        whereArgs: <Object?>[id],
      );
    });
  }

  /// V3.6：删除物品（软删进回收站，决策点③A）。
  ///
  /// 与 v3.2 版本的区别：关联行**不再物理清除**，改为同步软删留底——
  /// 恢复物品时关联行复活，位置关系完整还原；彻底删除（[purgeItem]）
  /// 时才物理清行。
  ///  * 物品行：is_deleted=1 + deleted_at=now 留底（回收站按 deleted_at 排序）；
  ///  * 该物品**活跃**关联行（is_deleted=0）：同步软删（is_deleted=1），
  ///    且 updated_at 置为与物品 deleted_at 完全相同的 now（同一事务同一
  ///    时间戳）。恢复时以 `updated_at == deleted_at` 精确匹配"删除时活跃"
  ///    的关联行复活，避免把更早的挪位软删历史行一并复活（复活的后果是
  ///    物品恢复后多位置并存，违背 V3 挪位=替换语义）。
  ///  * 挪位软删历史行（is_deleted=1 且 updated_at 更早）保持不动。
  /// 幂等：物品不存在或已删除时无操作。
  @override
  Future<void> deleteItem(int id) async {
    final db = await open();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction<void>((txn) async {
      final updated = await txn.update(
        tableItems,
        <String, Object?>{
          columnIsDeleted: 1,
          columnDeletedAt: now,
          columnUpdatedAt: now,
        },
        where: '$columnId = ? AND $columnIsDeleted = 0',
        whereArgs: <Object?>[id],
      );
      if (updated == 0) return; // 不存在或已删除，幂等返回。
      await txn.update(
        tableItemLocations,
        <String, Object?>{columnIsDeleted: 1, columnUpdatedAt: now},
        where: '$columnItemId = ? AND $columnIsDeleted = 0',
        whereArgs: <Object?>[id],
      );
    });
  }

  /// V3.6/V3.9：恢复回收站物品。
  ///
  /// V3.6 旧口径是"撞名即失败"；**V3.9 按 PM 拍板改为合并数量**——
  /// 明细里已有同名物品时，把回收站这件的数量累加到同名物品上、
  /// 位置关联一并并过去，而不是报错拒绝。返回 [RestoreOutcome]
  /// 如实说明是否发生了合并、合并后总数是多少（供 UI 回显）。
  ///
  /// 无同名冲突时走原恢复路径：
  ///  1. 物品行复活：is_deleted=0、deleted_at 置 NULL；
  ///  2. 关联行复活：仅复活"删除时活跃"的行——`is_deleted=1 AND
  ///     updated_at == 物品 deleted_at`（[deleteItem] 软删时写入的同一
  ///     时间戳），挪位软删历史行保持留底。
  /// 幂等：物品不存在或未删除时无操作（返回未合并的结果）。
  @override
  Future<RestoreOutcome> restoreItem(int id) async {
    final db = await open();
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.transaction<RestoreOutcome>((txn) async {
      final rows = await txn.query(
        tableItems,
        columns: <String>[columnName, columnDeletedAt, columnQuantity],
        where: '$columnId = ? AND $columnIsDeleted = 1',
        whereArgs: <Object?>[id],
        limit: 1,
      );
      if (rows.isEmpty) {
        // 不存在或未删除，幂等返回（不算合并）。
        return const RestoreOutcome(itemName: '', merged: false);
      }
      final itemName = rows.first[columnName] as String;
      final deletedAt = (rows.first[columnDeletedAt] as num?)?.toInt();
      final deletedQty = (rows.first[columnQuantity] as num?)?.toInt() ?? 1;

      final conflicts = await txn.query(
        tableItems,
        columns: <String>[columnId, columnQuantity],
        where: '$columnName = ? AND $columnIsDeleted = 0 AND $columnId != ?',
        whereArgs: <Object?>[itemName, id],
        limit: 1,
      );

      // V3.9（PM 拍板）：明细里已有同名物品 → 合并数量，不报错拒绝。
      // items 表有部分唯一索引（WHERE is_deleted=0），同名只可能有一行存活，
      // 因此合并 = 数量累加到存活行 + 位置关联并过去 + 物理删除已删行
      // （它已并入同名物品，不再作为独立物品存在）。
      if (conflicts.isNotEmpty) {
        final conflictId = (conflicts.first[columnId] as num).toInt();
        final conflictQty =
            (conflicts.first[columnQuantity] as num?)?.toInt() ?? 1;
        final total = conflictQty + deletedQty;

        await txn.update(
          tableItems,
          <String, Object?>{columnQuantity: total, columnUpdatedAt: now},
          where: '$columnId = ?',
          whereArgs: <Object?>[conflictId],
        );
        await _mergeItemAssociations(
          txn,
          fromItemId: id,
          toItemId: conflictId,
          deletedAt: deletedAt,
          now: now,
        );
        await txn.delete(
          tableItems,
          where: '$columnId = ? AND $columnIsDeleted = 1',
          whereArgs: <Object?>[id],
        );
        return RestoreOutcome(
          itemName: itemName,
          merged: true,
          totalQuantity: total,
        );
      }

      await txn.update(
        tableItems,
        <String, Object?>{
          columnIsDeleted: 0,
          columnDeletedAt: null,
          columnUpdatedAt: now,
        },
        where: '$columnId = ?',
        whereArgs: <Object?>[id],
      );
      // 历史软删行（deleted_at 为 NULL 的 v3.2 时代数据）无"删除时活跃"
      // 关联行可精确匹配，复活其全部软删关联行（当时物理删改软删前的
      // 历史行为无法追溯，全量复活位置最接近原状）。
      if (deletedAt == null) {
        await txn.update(
          tableItemLocations,
          <String, Object?>{columnIsDeleted: 0, columnUpdatedAt: now},
          where: '$columnItemId = ? AND $columnIsDeleted = 1',
          whereArgs: <Object?>[id],
        );
      } else {
        await txn.update(
          tableItemLocations,
          <String, Object?>{columnIsDeleted: 0, columnUpdatedAt: now},
          where: '$columnItemId = ? AND $columnIsDeleted = 1 '
              'AND $columnUpdatedAt = ?',
          whereArgs: <Object?>[id, deletedAt],
        );
      }
      return RestoreOutcome(itemName: itemName, merged: false);
    });
  }

  /// V3.9：把某物品的全部位置关联行并到另一件物品上（合并数量时用）。
  ///
  /// 规则：
  ///  * 目标物品已有**同位置活跃**关联行 → 该位置信息重复，直接丢弃
  ///    待迁移行（不产生两条同位置记录）；
  ///  * [deletedAt] 为 null（v3.2 时代软删数据）→ 全量复活；
  ///  * 否则只复活"删除时活跃"的行，软删的历史行迁移过去继续留底。
  Future<void> _mergeItemAssociations(
    DatabaseExecutor txn, {
    required int fromItemId,
    required int toItemId,
    required int? deletedAt,
    required int now,
  }) async {
    final assoc = await txn.query(
      tableItemLocations,
      where: '$columnItemId = ?',
      whereArgs: <Object?>[fromItemId],
    );
    for (final row in assoc) {
      final assocId = (row[columnId] as num).toInt();
      final locationId = (row[columnLocationId] as num).toInt();
      final wasActive = (row[columnIsDeleted] as num?)?.toInt() == 0;

      final dup = await txn.query(
        tableItemLocations,
        columns: <String>[columnId],
        where: '$columnItemId = ? AND $columnLocationId = ? '
            'AND $columnIsDeleted = 0',
        whereArgs: <Object?>[toItemId, locationId],
        limit: 1,
      );
      if (dup.isNotEmpty) {
        await txn.delete(
          tableItemLocations,
          where: '$columnId = ?',
          whereArgs: <Object?>[assocId],
        );
        continue;
      }

      final revive = deletedAt == null ? true : wasActive;
      await txn.update(
        tableItemLocations,
        <String, Object?>{
          columnItemId: toItemId,
          if (revive) columnIsDeleted: 0,
          columnUpdatedAt: now,
        },
        where: '$columnId = ?',
        whereArgs: <Object?>[assocId],
      );
    }
  }

  /// V3.6：彻底删除回收站物品（物理 DELETE，不可恢复）。
  ///
  /// 物品行与其**全部**关联行（活跃/软删历史一并）物理清除。
  /// 幂等：物品不存在时无操作。
  @override
  Future<void> purgeItem(int id) async {
    final db = await open();
    await db.transaction<void>((txn) async {
      await txn.delete(
        tableItems,
        where: '$columnId = ? AND $columnIsDeleted = 1',
        whereArgs: <Object?>[id],
      );
      await txn.delete(
        tableItemLocations,
        where: '$columnItemId = ?',
        whereArgs: <Object?>[id],
      );
    });
  }

  /// V3.6：清空回收站（物理 DELETE 全部 is_deleted=1 物品行
  /// 及其全部关联行，不可恢复）。
  @override
  Future<void> purgeAll() async {
    final db = await open();
    await db.transaction<void>((txn) async {
      // 先按已删物品删其关联行，再删物品行（顺序无外键约束要求，仅逻辑清晰）。
      await txn.execute(
        'DELETE FROM $tableItemLocations WHERE $columnItemId IN '
        '(SELECT $columnId FROM $tableItems WHERE $columnIsDeleted = 1)',
      );
      await txn.delete(tableItems,
          where: '$columnIsDeleted = 1');
      // V3.8：连带清空已软删的借出记录（回收站一并清空）。
      await txn.delete(tableLoans,
          where: '$columnIsDeleted = 1');
    });
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

  /// V3.1：软删除位置。删除后不再出现在位置列表与查询关联里（沿用 v4 软删策略）。
  ///
  /// V3.2 联动修正（技术审核决策点②）：事务内按以下**固定顺序**处理关联表，
  /// 顺序不能颠倒——颠倒会把刚软删的活跃关联一并物理清掉，"留底"失效：
  ///  1. 先物理 DELETE 该位置的**软删历史**关联行（is_deleted=1 的僵尸行）；
  ///  2. 再联动软删指向它的**活跃**关联行（is_deleted 0→1，留底）。
  /// 修正后任何时刻「活跃关联」都与「位置活跃」显性一致，不再依赖查询
  /// SQL 的 join 条件兜底。
  ///
  /// 「恢复/回显」语义（技术审核确认点②）：软删关联留底可回显的前提是
  /// **复活同一行**（把该位置行 is_deleted 改回 0，id 不变，备份恢复即此
  /// 语义）；**新建同名位置是新行、新 id**，旧软删关联不会跟随新 id 回显。
  @override
  Future<void> deleteLocation(int id) async {
    final db = await open();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction<void>((txn) async {
      final updated = await txn.update(
        tableLocations,
        <String, Object?>{columnIsDeleted: 1, columnUpdatedAt: now},
        where: '$columnId = ? AND $columnIsDeleted = 0',
        whereArgs: <Object?>[id],
      );
      if (updated == 0) return; // 不存在或已删除，幂等返回。
      // ① 先物理清软删历史关联行（僵尸行只增不减的清理路径）。
      await txn.delete(
        tableItemLocations,
        where: '$columnLocationId = ? AND $columnIsDeleted = 1',
        whereArgs: <Object?>[id],
      );
      // ② 再联动软删活跃关联行（留底：位置复活同一行时关联可回显）。
      await txn.update(
        tableItemLocations,
        <String, Object?>{columnIsDeleted: 1, columnUpdatedAt: now},
        where: '$columnLocationId = ? AND $columnIsDeleted = 0',
        whereArgs: <Object?>[id],
      );
    });
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
  ///
  /// V3.10：新增 [quantity] 与 [additive]。
  ///  * [quantity] 为 null = 本次不带数量，物品数量保持原样。
  ///  * [quantity] 有值 + [additive] false = **覆盖**（PM 拍板③：说「3个梯子」
  ///    是在纠正数量，覆盖原值）。
  ///  * [quantity] 有值 + [additive] true = **累加**（补充要求1：「再放N个」）。
  @override
  Future<UpsertResult> upsertItemLocation(String itemName, int locationId,
      {String? rawText, int? quantity, bool additive = false}) async {
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
      if (quantity != null) {
        await _applyQuantity(
          txn,
          itemId: itemId,
          quantity: quantity,
          additive: additive,
          now: now,
        );
      }
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

  /// V3.10：读某件物品的当前在库数。
  ///
  /// 权威值就是 `items.quantity`（借出即扣、归还即加）——
  /// **不再套 `max(quantity, 未归还借出数)` 兜底**：那层兜底会把
  /// 在借数减两遍（「录 3 个借出 2 个」会算出可借 0 个）。
  Future<int> _readStock(DatabaseExecutor txn, int itemId) async {
    final rows = await txn.query(
      tableItems,
      columns: <String>[columnQuantity],
      where: '$columnId = ?',
      whereArgs: <Object?>[itemId],
      limit: 1,
    );
    if (rows.isEmpty) return 0;
    return (rows.first[columnQuantity] as num?)?.toInt() ?? 1;
  }

  /// V3.10：写入物品的在库数量。
  ///
  /// 覆盖语义（PM 拍板③）：quantity 直接作为新的在库数。
  /// 累加语义（补充要求1：「再放N个」）：在库数 += quantity。
  ///
  /// 累加以**当前在库数**为基准——在库数已经是扣过借出的净值，
  /// 不再拿在借数去兜底，避免增量被吃掉或重复计。
  Future<void> _applyQuantity(
    DatabaseExecutor txn, {
    required int itemId,
    required int quantity,
    required bool additive,
    required int now,
  }) async {
    if (quantity < 1) {
      throw ArgumentError.value(quantity, 'quantity', '数量至少为 1');
    }
    final rows = await txn.query(
      tableItems,
      columns: <String>[columnQuantity],
      where: '$columnId = ?',
      whereArgs: <Object?>[itemId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final curQty = (rows.first[columnQuantity] as num?)?.toInt() ?? 1;
    final newQty = additive ? curQty + quantity : quantity;
    if (newQty == curQty) return;
    await txn.update(
      tableItems,
      <String, Object?>{columnQuantity: newQty, columnUpdatedAt: now},
      where: '$columnId = ?',
      whereArgs: <Object?>[itemId],
    );
  }

  /// 挪位语义（V3.2，UI 主链路）：把物品记到 [locationId]，此前所在的其他
  /// 位置关联**软删**（历史留底可审计），只保留目标位置。
  ///
  /// 返回 [MoveResult]：previousLocations 为挪位前其他位置名（不含目标）。
  /// 物品本身与位置本身只复用既有行，不做删除。
  @override
  Future<MoveResult> moveItem(String itemName, int locationId,
      {String? rawText, int? quantity, bool additive = false}) async {
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
    return db.transaction<MoveResult>((txn) async {
      final itemId = await _findOrCreateItem(txn, valid, now);

      // V3.10：数量写入（覆盖 / 累加）。
      var quantityChanged = false;
      var finalQuantity = 1;
      if (quantity != null) {
        final before = await _readStock(txn, itemId);
        await _applyQuantity(
          txn,
          itemId: itemId,
          quantity: quantity,
          additive: additive,
          now: now,
        );
        final after = await _readStock(txn, itemId);
        finalQuantity = after;
        quantityChanged = after != before;
      } else {
        finalQuantity = await _readStock(txn, itemId);
      }

      // 挪位前该物品的全部活动关联（含目标位）。
      final currentLinks = await txn.query(
        tableItemLocations,
        columns: <String>[columnId, columnLocationId],
        where: '$columnItemId = ? AND $columnIsDeleted = 0',
        whereArgs: <Object?>[itemId],
      );

      bool targetLinked = false;
      final staleLinkIds = <int>[];
      final staleLocationIds = <int>[];
      for (final row in currentLinks) {
        final linkLocationId = row[columnLocationId] as int;
        if (linkLocationId == locationId) {
          targetLinked = true;
        } else {
          staleLinkIds.add(row[columnId] as int);
          staleLocationIds.add(linkLocationId);
        }
      }

      // 其他位置名（挪位前），按关联 id 顺序（即记录顺序）。
      final previousLocations = <String>[];
      for (final staleLocationId in staleLocationIds) {
        final locRows = await txn.query(
          tableLocations,
          columns: <String>[columnName],
          where: '$columnId = ? AND $columnIsDeleted = 0',
          whereArgs: <Object?>[staleLocationId],
          limit: 1,
        );
        if (locRows.isNotEmpty) {
          previousLocations.add(locRows.first[columnName] as String);
        }
      }

      // 软删旧关联（留底）。
      for (final linkId in staleLinkIds) {
        await txn.update(
          tableItemLocations,
          <String, Object?>{columnIsDeleted: 1, columnUpdatedAt: now},
          where: '$columnId = ?',
          whereArgs: <Object?>[linkId],
        );
      }

      if (targetLinked) {
        // 物品已在目标位置：刷新时间戳即可。
        final targetLinkRow = currentLinks.firstWhere(
          (row) => row[columnLocationId] as int == locationId,
        );
        await txn.update(
          tableItemLocations,
          <String, Object?>{columnUpdatedAt: now},
          where: '$columnId = ?',
          whereArgs: <Object?>[targetLinkRow[columnId] as int],
        );
        return MoveResult(
          itemId: itemId,
          locationId: locationId,
          created: false,
          previousLocations: previousLocations,
          quantity: finalQuantity,
          quantityChanged: quantityChanged,
        );
      }

      await _link(txn, itemId, locationId, now, rawText: rawText);
      return MoveResult(
        itemId: itemId,
        locationId: locationId,
        created: true,
        previousLocations: previousLocations,
        quantity: finalQuantity,
        quantityChanged: quantityChanged,
      );
    });
  }

  /// V3.10：只改数量，**不动位置**。
  ///
  /// 与 [moveItem] 分开的原因：`moveItem` 是「挪位」语义——会把物品的其他
  /// 位置关联软删掉。「说『3个梯子』纠正数量」只想改数字，不想动位置，
  /// 走 moveItem 会顺手把「车库」的关联删了（真会被用户遇到的坑）。
  ///
  /// [quantity] ≥ 1；[additive] 为 true 时是「又添了 N 个」= 在库数 += N，
  /// 否则是「纠正数量」= 直接覆盖为 N。
  /// 物品没记录过 → 抛 ArgumentError（PM 拍板④：不能凭空造账）。
  /// 返回改完后的在库数。
  @override
  Future<int> setItemQuantity(
    String itemName,
    int quantity, {
    bool additive = false,
  }) async {
    final valid = _normalizeName(itemName, '物品名称');
    if (quantity < 1) {
      throw ArgumentError.value(quantity, 'quantity', '数量至少为 1');
    }
    final db = await open();
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.transaction<int>((txn) async {
      final rows = await txn.query(
        tableItems,
        columns: <String>[columnId],
        where: '$columnName = ? AND $columnIsDeleted = 0',
        whereArgs: <Object?>[valid],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw ArgumentError.value(
          valid,
          'itemName',
          '还没记录过「$valid」，先说一句「$valid放阳台」再记数量',
        );
      }
      final itemId = rows.first[columnId] as int;
      await _applyQuantity(
        txn,
        itemId: itemId,
        quantity: quantity,
        additive: additive,
        now: now,
      );
      return _readStock(txn, itemId);
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

  /// 物品明细页：全部未删除物品 + 各自全部未删除位置，按物品名排序。
  /// 两次查询在事务外完成（只读聚合，无一致性要求高于 findByName 的场景）。
  @override
  Future<List<ItemWithLocations>> getAllItemsWithLocations() =>
      _queryItemsWithLocations(deleted: false);

  /// V3.6：回收站视图复用同一聚合（活跃/已删切换）。
  @override
  Future<List<ItemWithLocations>> getDeletedItems() =>
      _queryItemsWithLocations(deleted: true);

  /// 聚合查询：物品 + 关联位置 + 记账原文/标签。
  ///
  /// deleted=false（明细页）：物品 is_deleted=0，仅取活跃关联行
  /// （assoc.is_deleted=0 且 loc.is_deleted=0），按物品名排序。
  /// deleted=true（回收站）：物品 is_deleted=1（deleted_at 倒序，NULL 排末尾），
  /// 取该物品**全部**关联行（含挪位软删历史）对应的有效位置
  /// （loc.is_deleted=0，按位置 id 去重），记账原文/标签聚合自全部关联行。
  Future<List<ItemWithLocations>> _queryItemsWithLocations(
      {required bool deleted}) async {
    final db = await open();
    final itemRows = await db.query(
      tableItems,
      where: '$columnIsDeleted = ${deleted ? 1 : 0}',
      orderBy: deleted
          ? '$columnDeletedAt DESC, $columnUpdatedAt DESC'
          : '$columnName ASC',
    );
    if (itemRows.isEmpty) return const <ItemWithLocations>[];

    // 一次取全部关联+位置，按 item_id 分组，避免 N+1 查询。
    final assocRows = await db.rawQuery(
      'SELECT assoc.$columnItemId AS assoc_item_id, '
      'assoc.$columnRawText AS assoc_raw_text, '
      'assoc.$columnTags AS assoc_tags, '
      'loc.$columnId AS loc_id, loc.$columnName AS loc_name, '
      'loc.$columnIsDeleted AS loc_deleted, '
      'loc.$columnCreatedAt AS loc_created, '
      'loc.$columnUpdatedAt AS loc_updated, '
      'loc.$columnRemark AS loc_remark '
      'FROM $tableItemLocations AS assoc '
      'INNER JOIN $tableLocations AS loc ON assoc.$columnLocationId = loc.$columnId '
      'WHERE ${deleted ? '' : 'assoc.$columnIsDeleted = 0 AND '}'
      'loc.$columnIsDeleted = 0 '
      'ORDER BY loc.$columnName ASC',
    );

    final locationsByItem = <int, Map<int, Location>>{};
    final rawTextsByItem = <int, Set<String>>{};
    final tagsByItem = <int, Set<String>>{};
    for (final row in assocRows) {
      final itemId = row['assoc_item_id'] as int;
      final locId = row['loc_id'] as int;
      locationsByItem[itemId] ??= <int, Location>{};
      locationsByItem[itemId]![locId] = Location(
        id: locId,
        name: row['loc_name'] as String,
        isDeleted: (row['loc_deleted'] as int?) == 1,
        createdAt: (row['loc_created'] as num).toInt(),
        updatedAt: (row['loc_updated'] as num).toInt(),
        remark: row['loc_remark'] as String?,
      );
      final rawText = row['assoc_raw_text'] as String?;
      if (rawText != null && rawText.trim().isNotEmpty) {
        (rawTextsByItem[itemId] ??= <String>{}).add(rawText);
      }
      final tag = row['assoc_tags'] as String?;
      if (tag != null && tag.trim().isNotEmpty) {
        (tagsByItem[itemId] ??= <String>{}).add(tag);
      }
    }

    return itemRows
        .map((row) {
          final item = Item.fromMap(row);
          final locMap = locationsByItem[item.id] ?? const <int, Location>{};
          final locations = locMap.values.toList(growable: false);
          return ItemWithLocations(
            item: item,
            locations: locations,
            rawTexts: rawTextsByItem[item.id]?.toList(growable: false) ??
                const <String>[],
            tags: tagsByItem[item.id]?.toList(growable: false) ??
                const <String>[],
          );
        })
        .toList(growable: false);
  }

  // ---------- V3.10 数量打通 ----------

  /// 单件物品的数量三口径（在库 / 在借 / 可借）。
  ///
  /// PM 2026-11-24 拍板①在库口径：`items.quantity` 就是**在库数**
  /// （借出即扣减、归还即加回），可借数 = 在库数。
  /// 在借数只作展示，**不再从在库数里减一次**。
  @override
  Future<QuantityInfo> getQuantityInfo(String itemName) async {
    final valid = _normalizeName(itemName, '物品名称');
    final db = await open();
    final rows = await db.query(
      tableItems,
      columns: <String>[columnId, columnQuantity],
      where: '$columnName = ? AND $columnIsDeleted = 0',
      whereArgs: <Object?>[valid],
      limit: 1,
    );
    if (rows.isEmpty) {
      return const QuantityInfo(stock: 0, lent: 0, available: 0);
    }
    final itemId = rows.first[columnId] as int;
    final stock = (rows.first[columnQuantity] as num?)?.toInt() ?? 1;
    final lent = await _sumOutstandingLent(db, itemId);
    return QuantityInfo(
      stock: stock,
      lent: lent,
      available: stock,
    );
  }

  /// 按 item_id 汇总未归还的借出总数（quantity − returned_qty）。
  /// 已软删的借出记录（进回收站）不计入。
  Future<int> _sumOutstandingLent(DatabaseExecutor db, int itemId) async {
    final rows = await db.rawQuery(
      'SELECT COALESCE(SUM(quantity - returned_qty), 0) AS lent '
      'FROM $tableLoans '
      'WHERE item_id = ? AND is_deleted = 0 AND returned_qty < quantity',
      <Object?>[itemId],
    );
    return (rows.first['lent'] as num?)?.toInt() ?? 0;
  }

  /// 全部活跃物品的数量三口径（明细页用，一次查完避免 N+1）。
  @override
  Future<Map<int, QuantityInfo>> getAllQuantityInfo() async {
    final db = await open();
    final result = <int, QuantityInfo>{};
    final itemRows = await db.query(
      tableItems,
      columns: <String>[columnId, columnQuantity],
      where: '$columnIsDeleted = 0',
    );
    if (itemRows.isEmpty) return result;
    // 一次性取全部未归还借出，按 item_id 分组。
    final lentRows = await db.rawQuery(
      'SELECT item_id AS item_id, '
      'COALESCE(SUM(quantity - returned_qty), 0) AS lent '
      'FROM $tableLoans '
      'WHERE is_deleted = 0 AND returned_qty < quantity '
      'GROUP BY item_id',
    );
    final lentByItem = <int, int>{};
    for (final row in lentRows) {
      lentByItem[row['item_id'] as int] = (row['lent'] as num?)?.toInt() ?? 0;
    }
    for (final row in itemRows) {
      final id = row[columnId] as int;
      final stock = (row[columnQuantity] as num?)?.toInt() ?? 1;
      final lent = lentByItem[id] ?? 0;
      result[id] = QuantityInfo(
        stock: stock,
        lent: lent,
        available: stock,
      );
    }
    return result;
  }

  /// V3.10「校准数量」工具（PM 2026-11-24 补充要求 2）：
  /// 按用户**实物清点**把数量改准。
  ///
  /// [totals] = 物品 id → 用户清点的「家里一共几个」（总拥有数）。
  /// 写入的**在库数 = 总拥有数 − 未归还借出数**（下限 0）。
  ///
  /// 为什么这样算：用户清点时数的是「我家一共有几个」，
  /// 借出去的那些人手里的不在家，所以从总数里扣掉在借数才是真正的在库数。
  /// 对存量老物品（`items.quantity` 恒为 1 的「总数」语义）和
  /// 新流程物品（「在库数」语义）**同一套公式都成立**，而且**幂等**：
  /// 同样的清点值反复校准，结果不变。
  ///
  /// 传空 [totals] = 只体检、不写库（details 里如实列出账面与清点的差异）。
  /// 只处理活跃物品；已软删（回收站）的物品不动。
  @override
  Future<CalibrationReport> calibrateQuantities({
    Map<int, int> totals = const <int, int>{},
  }) async {
    final db = await open();
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.transaction<CalibrationReport>((txn) async {
      final itemRows = await txn.query(
        tableItems,
        columns: <String>[columnId, columnName, columnQuantity],
        where: '$columnIsDeleted = 0',
      );
      final lentRows = await txn.rawQuery(
        'SELECT item_id AS item_id, '
        'COALESCE(SUM(quantity - returned_qty), 0) AS lent '
        'FROM $tableLoans '
        'WHERE is_deleted = 0 AND returned_qty < quantity '
        'GROUP BY item_id',
      );
      final lentByItem = <int, int>{};
      for (final row in lentRows) {
        lentByItem[row['item_id'] as int] = (row['lent'] as num?)?.toInt() ?? 0;
      }
      var changed = 0;
      final details = <String>[];
      for (final row in itemRows) {
        final id = row[columnId] as int;
        final name = row[columnName] as String;
        final curQty = (row[columnQuantity] as num?)?.toInt() ?? 1;
        final lent = lentByItem[id] ?? 0;
        final counted = totals[id];
        if (counted == null) continue; // 没清点这件就不动它。
        if (counted < lent) {
          // 清点总数比在借数还少——账已经打架了，如实说明，不硬写。
          details.add('$name：清点 $counted 个，比在借的 $lent 个还少，'
              '已跳过（请核对后重试）');
          continue;
        }
        final newQty = counted - lent;
        if (newQty != curQty) {
          await txn.update(
            tableItems,
            <String, Object?>{
              columnQuantity: newQty,
              columnUpdatedAt: now,
            },
            where: '$columnId = ?',
            whereArgs: <Object?>[id],
          );
          changed++;
          details.add('$name：共 $counted 个 − 在借 $lent 个 → 在库 $newQty 个'
              '（原记录 $curQty 个）');
        }
      }
      return CalibrationReport(changedCount: changed, details: details);
    });
  }

  /// 备份导出：全部表全量行（含软删行，保证还原保真），外加库名、schema 版本、导出时间。
  /// V3.7：新增 borrowers / loans 两张表；旧版恢复时缺表按空处理。
  /// 纯读取，不改库。
  @override
  Future<Map<String, Object?>> exportBackup() async {
    final db = await open();
    return <String, Object?>{
      'app': 'home_inventory',
      'schemaVersion': version,
      'exportedAt': DateTime.now().millisecondsSinceEpoch,
      tableItems: await db.query(tableItems, orderBy: '$columnId ASC'),
      tableLocations: await db.query(tableLocations, orderBy: '$columnId ASC'),
      tableItemLocations:
          await db.query(tableItemLocations, orderBy: '$columnId ASC'),
      tableBorrowers: await db.query(tableBorrowers, orderBy: '$columnId ASC'),
      tableLoans: await db.query(tableLoans, orderBy: '$columnId ASC'),
    };
  }

  /// 备份恢复：事务内清空所有表后按备份重插（保留原 id）。
  /// 校验备份归属与版本（版本高于当前库则拒绝），任何一步失败整体回滚。
  /// 兼容旧备份：无 borrowers/loans 键时按空表处理；旧物品行无 quantity 时
  /// [Item.fromMap] 自动补 1（元宝迁移兼容硬约束）。
  @override
  Future<void> restoreBackup(Map<String, Object?> data) async {
    if (data['app'] != 'home_inventory') {
      throw ArgumentError.value(data, 'data', '不是本应用的备份文件');
    }
    final backupVersion = (data['schemaVersion'] as num?)?.toInt();
    if (backupVersion == null || backupVersion > version) {
      throw ArgumentError.value(
        backupVersion,
        'schemaVersion',
        '备份版本高于当前应用支持的数据库版本（$version）',
      );
    }
    final itemMaps = _rowsOf(data, tableItems);
    final locationMaps = _rowsOf(data, tableLocations);
    final assocMaps = _rowsOf(data, tableItemLocations);
    final borrowerMaps = data.containsKey(tableBorrowers)
        ? _rowsOf(data, tableBorrowers)
        : <Map<String, Object?>>[];
    final loanMaps = data.containsKey(tableLoans)
        ? _rowsOf(data, tableLoans)
        : <Map<String, Object?>>[];

    final db = await open();
    await db.transaction<void>((txn) async {
      // 清空顺序：先子表后主表，避免外键/索引干扰。
      await txn.delete(tableLoans);
      await txn.delete(tableBorrowers);
      await txn.delete(tableItemLocations);
      await txn.delete(tableLocations);
      await txn.delete(tableItems);
      for (final row in itemMaps) {
        await txn.insert(tableItems, Item.fromMap(row).toMap());
      }
      for (final row in locationMaps) {
        await txn.insert(tableLocations, Location.fromMap(row).toMap());
      }
      for (final row in assocMaps) {
        await txn.insert(tableItemLocations, ItemLocation.fromMap(row).toMap());
      }
      for (final row in borrowerMaps) {
        await txn.insert(tableBorrowers, Borrower.fromMap(row).toMap());
      }
      for (final row in loanMaps) {
        await txn.insert(tableLoans, Loan.fromMap(row).toMap());
      }
    });
  }

  List<Map<String, Object?>> _rowsOf(Map<String, Object?> data, String key) {
    final raw = data[key];
    if (raw is! List) {
      throw ArgumentError.value(data, key, '备份缺少 $key 数据');
    }
    return raw
        .whereType<Map>()
        .map((row) => <String, Object?>{
              for (final e in row.entries) '${e.key}': e.value,
            })
        .toList(growable: false);
  }

  // ==================== V3.7 借阅管理 ====================

  /// 默认借期 3 天（元宝批复），单笔可在借出时覆盖。
  static const int defaultLoanDays = 3;

  /// 借出：物品 + 借阅人 + 数量 + 天数（默认 3 天）。
  /// 借阅人按名字复用活跃行（去重），物品按名字复用活跃行。
  /// due_at 用 UTC 毫秒（DateTime.now().toUtc() + 天数），本地显示由 UI 负责。
  /// 名称走归一化；数量 >= 1，天数 >= 1，否则抛 ArgumentError。
  @override
  Future<Loan> lendItem(
    String itemName,
    String borrowerName, {
    int quantity = 1,
    int? days,
  }) async {
    final validItem = _normalizeName(itemName, '物品名称');
    // V3.9.1 真机打回：解析器漏掉的一路（口语「梯子借给张三」）会把「借」
    // 留在名字里，物品被建成「梯子借」，借出记录也挂在这个脏名上，之后说
    // 「梯子借期改成5天」按「梯子」就再也查不到。落库前统一按词根归一，
    // 与解析器的修复构成双保险。
    final rootItem = stripLoanSuffix(validItem);
    final storeItem = rootItem.isEmpty ? validItem : rootItem;
    final validBorrower = _normalizeName(borrowerName, '借阅人姓名');
    if (quantity < 1) {
      throw ArgumentError.value(quantity, 'quantity', '借出数量至少为 1');
    }
    final loanDays = days ?? defaultLoanDays;
    if (loanDays < 1) {
      throw ArgumentError.value(loanDays, 'days', '借期至少为 1 天');
    }

    final db = await open();
    final nowUtc = DateTime.now().toUtc();
    final now = nowUtc.millisecondsSinceEpoch;
    final due = nowUtc.add(Duration(days: loanDays)).millisecondsSinceEpoch;

    return db.transaction<Loan>((txn) async {
      // V3.10（PM 拍板④）：**没记录过的东西不能直接借出**——引导用户先录入，
      // 不凭空造账。原来这里直接 _findOrCreateItem 会自动建出库存 0 的物品，
      // 让「家里没有的东西也能借走」，账面直接穿空。
      final itemRows = await txn.query(
        tableItems,
        columns: <String>[columnId, columnQuantity],
        where: '$columnName = ? AND $columnIsDeleted = 0',
        whereArgs: <Object?>[storeItem],
        limit: 1,
      );
      if (itemRows.isEmpty) {
        throw ArgumentError.value(
          storeItem,
          'itemName',
          '还没记录过「$storeItem」，先说一句「$storeItem放阳台」再借',
        );
      }
      final itemId = itemRows.first[columnId] as int;
      final stock = (itemRows.first[columnQuantity] as num?)?.toInt() ?? 1;

      // 可借数校验（PM 拍板②：借超要拦截，不允许负数）。
      // 在库数 = `items.quantity`（借出即扣、归还即加），可借数 = 在库数。
      final lentRows = await txn.rawQuery(
        'SELECT COALESCE(SUM(quantity - returned_qty), 0) AS lent '
        'FROM $tableLoans '
        'WHERE item_name = ? AND is_deleted = 0 AND returned_qty < quantity',
        <Object?>[storeItem],
      );
      final lent = (lentRows.first['lent'] as num?)?.toInt() ?? 0;
      final available = stock;
      if (quantity > available) {
        throw ArgumentError.value(
          quantity,
          'quantity',
          stock <= 0
              ? '「$storeItem」家里已经没有可借的了'
                  '（$lent 个都借出去了），先记着家里还有几个再借'
              : '家里只有$stock个「$storeItem」，可借$available个',
        );
      }

      // 借阅人：复用活跃行，软删的不复用（同名会新建）。
      final borrowerRows = await txn.query(
        tableBorrowers,
        columns: <String>[columnId],
        where: '$columnName = ? AND $columnIsDeleted = 0',
        whereArgs: <Object?>[validBorrower],
        limit: 1,
      );
      if (borrowerRows.isEmpty) {
        await txn.insert(
          tableBorrowers,
          Borrower(name: validBorrower, createdAt: now, updatedAt: now).toMap(),
        );
      }
      // 在库口径（PM 拍板①）：借出即扣减库存数。
      final newStock = stock - quantity;
      await txn.update(
        tableItems,
        <String, Object?>{columnQuantity: newStock, columnUpdatedAt: now},
        where: '$columnId = ?',
        whereArgs: <Object?>[itemId],
      );
      final loan = Loan(
        itemId: itemId,
        updatedAt: now,
        itemName: storeItem,
        borrowerName: validBorrower,
        quantity: quantity,
        borrowedAt: now,
        dueAt: due,
      );
      final id = await txn.insert(tableLoans, loan.toMap());
      return Loan(
        id: id,
        itemId: itemId,
        updatedAt: now,
        itemName: storeItem,
        borrowerName: validBorrower,
        quantity: quantity,
        borrowedAt: now,
        dueAt: due,
      );
    });
  }

  /// 归还：[quantity] 为空 = 全部归还；给定值 = 部分归还（累加 returnedQty，
  /// 标 isPartial）。数量非法或超借出量抛 ArgumentError。幂等：已还完再还无操作。
  @override
  Future<void> returnLoan(int loanId, {int? quantity}) async {
    final db = await open();
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await db.transaction<void>((txn) async {
      final rows = await txn.query(
        tableLoans,
        where: '$columnId = ?',
        whereArgs: <Object?>[loanId],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw ArgumentError.value(loanId, 'loanId', '借出记录不存在');
      }
      final loan = Loan.fromMap(rows.first);
      if (loan.isReturned) return; // 幂等
      final remaining = loan.quantity - loan.returnedQty;
      final amount = quantity ?? remaining;
      if (amount < 1 || amount > remaining) {
        throw ArgumentError.value(quantity, 'quantity', '归还数量超出未还数量');
      }
      final newReturned = loan.returnedQty + amount;
      final fullyReturned = newReturned >= loan.quantity;
      await txn.update(
        tableLoans,
        <String, Object?>{
          columnReturnedQty: newReturned,
          columnIsPartial: fullyReturned ? (loan.isPartial ? 1 : 0) : 1,
          if (fullyReturned) columnReturnedAt: now,
          columnUpdatedAt: now,
        },
        where: '$columnId = ?',
        whereArgs: <Object?>[loanId],
      );

      // V3.10（PM 拍板①在库口径）：归还即加回库存数，与借出严格对称。
      // 部分归还只加回本次还的数量（借 3 还 1 → 库存 +1，不是 +3）。
      // 物品行可能已被软删（进回收站）或已物理清除——此时无处加回，
      // 只更新 loans 即可，不报错（借出记录保留历史，V3.9.2 口径）。
      final itemRows = await txn.query(
        tableItems,
        columns: <String>[columnId, columnQuantity],
        where: '$columnId = ?',
        whereArgs: <Object?>[loan.itemId],
        limit: 1,
      );
      if (itemRows.isNotEmpty) {
        final itemRow = itemRows.first;
        final itemId = itemRow[columnId] as int;
        final curQty = (itemRow[columnQuantity] as num?)?.toInt() ?? 1;
        await txn.update(
          tableItems,
          <String, Object?>{
            columnQuantity: curQty + amount,
            columnUpdatedAt: now,
          },
          where: '$columnId = ?',
          whereArgs: <Object?>[itemId],
        );
      }
    });
  }

  /// 单笔改借期（天数从借出时刻起算，UTC）。
  @override
  Future<void> updateLoanDue(int loanId, int days) async {
    if (days < 1) {
      throw ArgumentError.value(days, 'days', '借期至少为 1 天');
    }
    final db = await open();
    final rows = await db.query(
      tableLoans,
      columns: <String>[columnBorrowedAt],
      where: '$columnId = ?',
      whereArgs: <Object?>[loanId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw ArgumentError.value(loanId, 'loanId', '借出记录不存在');
    }
    final borrowedAt = (rows.first[columnBorrowedAt] as num).toInt();
    final due = DateTime.fromMillisecondsSinceEpoch(borrowedAt, isUtc: true)
        .add(Duration(days: days))
        .millisecondsSinceEpoch;
    await db.update(
      tableLoans,
      <String, Object?>{
        columnDueAt: due,
        columnUpdatedAt: DateTime.now().toUtc().millisecondsSinceEpoch,
      },
      where: '$columnId = ?',
      whereArgs: <Object?>[loanId],
    );
  }

  /// 全部借出记录（未软删，含已还，按借出时间倒序；逾期由 UI 按 due_at 与 now 计算）。
  /// V3.8：已软删（进回收站）的记录不在此返回。
  @override
  Future<List<Loan>> getAllLoans() async {
    final db = await open();
    final rows = await db.query(
      tableLoans,
      where: '$columnIsDeleted = 0',
      orderBy: '$columnBorrowedAt DESC',
    );
    return rows.map(Loan.fromMap).toList(growable: false);
  }

  /// V3.8：回收站——已软删的借出记录（is_deleted=1，按删除时间倒序）。
  @override
  Future<List<Loan>> getDeletedLoans() async {
    final db = await open();
    final rows = await db.query(
      tableLoans,
      where: '$columnIsDeleted = 1',
      orderBy: '$columnDeletedAt DESC, $columnBorrowedAt DESC',
    );
    return rows.map(Loan.fromMap).toList(growable: false);
  }

  /// V3.8：软删借出记录（进回收站，可恢复）。
  /// 记录不存在或已软删时抛 ArgumentError。
  @override
  Future<void> deleteLoan(int id) async {
    final db = await open();
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final rows = await db.query(
      tableLoans,
      columns: <String>[columnId],
      where: '$columnId = ? AND $columnIsDeleted = 0',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw ArgumentError.value(id, 'id', '借出记录不存在');
    }
    await db.update(
      tableLoans,
      <String, Object?>{
        columnIsDeleted: 1,
        columnDeletedAt: now,
        columnUpdatedAt: now,
      },
      where: '$columnId = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// V3.8：恢复已软删的借出记录（回借出管理列表）。
  @override
  Future<void> restoreLoan(int id) async {
    final db = await open();
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final rows = await db.query(
      tableLoans,
      columns: <String>[columnId],
      where: '$columnId = ? AND $columnIsDeleted = 1',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw ArgumentError.value(id, 'id', '没有已删除的借出记录');
    }
    await db.update(
      tableLoans,
      <String, Object?>{
        columnIsDeleted: 0,
        columnDeletedAt: null,
        columnUpdatedAt: now,
      },
      where: '$columnId = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// V3.8：彻底删除借出记录（物理 DELETE，不可恢复）。
  @override
  Future<void> purgeLoan(int id) async {
    final db = await open();
    final rows = await db.query(
      tableLoans,
      columns: <String>[columnId],
      where: '$columnId = ? AND $columnIsDeleted = 1',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw ArgumentError.value(id, 'id', '没有已删除的借出记录');
    }
    await db.delete(
      tableLoans,
      where: '$columnId = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// 活跃借阅人（未软删，按名字排序）——借出时下拉去重来源。
  @override
  Future<List<Borrower>> getActiveBorrowers() async {
    final db = await open();
    final rows = await db.query(
      tableBorrowers,
      where: '$columnIsDeleted = 0',
      orderBy: '$columnName ASC',
    );
    return rows.map(Borrower.fromMap).toList(growable: false);
  }

  /// 软删借阅人（历史 loan 的 borrower_name 快照不受影响）。
  @override
  Future<void> softDeleteBorrower(int id) async {
    final db = await open();
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await db.update(
      tableBorrowers,
      <String, Object?>{
        columnIsDeleted: 1,
        columnDeletedAt: now,
        columnUpdatedAt: now,
      },
      where: '$columnId = ? AND $columnIsDeleted = 0',
      whereArgs: <Object?>[id],
    );
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

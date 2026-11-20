import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'item.dart';
import 'inventory_repository.dart';

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
  InventoryDatabase({
    DatabaseFactory? databaseFactory,
    String? databasePath,
    this.version = 3,
  })  : _injectedFactory = databaseFactory,
        _injectedPath = databasePath;

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

  /// 未删除记录的唯一约束：物品名唯一、位置名唯一、同一(物品,位置)关联唯一。
  static const String itemsUniqueIndex = 'idx_items_name_unique';
  static const String locationsUniqueIndex = 'idx_locations_name_unique';
  static const String associationUniqueIndex = 'idx_assoc_item_location_unique';

  /// 名称长度上限，超出抛 ArgumentError（超长位置是明确的验收点）。
  static const int maxNameLength = 100;

  final DatabaseFactory? _injectedFactory;
  final String? _injectedPath;
  final int version;

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
        $columnUpdatedAt INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE $tableItemLocations (
        $columnId INTEGER PRIMARY KEY AUTOINCREMENT,
        $columnItemId INTEGER NOT NULL,
        $columnLocationId INTEGER NOT NULL,
        $columnIsDeleted INTEGER NOT NULL DEFAULT 0,
        $columnCreatedAt INTEGER NOT NULL,
        $columnUpdatedAt INTEGER NOT NULL
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

  /// v1/v2 是单表 items(name, location, ...)。v3 改三张表：
  /// 把旧的每条 (name, location) 迁成一件物品 + 一个位置 + 一条关联。
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion >= 3) return;

    List<Map<String, Object?>> legacyRows = const <Map<String, Object?>>[];
    try {
      legacyRows = await db.query(tableItems);
    } catch (_) {
      // 旧表不存在时按空库处理。
    }

    await db.execute('DROP TABLE IF EXISTS $tableItemLocations');
    await db.execute('DROP TABLE IF EXISTS $tableLocations');
    await db.execute('DROP TABLE IF EXISTS $tableItems');
    await _onCreate(db, newVersion);

    final now = DateTime.now().millisecondsSinceEpoch;
    for (final row in legacyRows) {
      final name = row['name'] as String?;
      final location = row['location'] as String?;
      if (name == null || location == null) continue;
      final itemId = await _findOrCreateItem(db, name.trim(), now);
      final locationId = await _findOrCreateLocation(db, location.trim(), now);
      await _link(db, itemId, locationId, now);
    }
  }

  /// 校验并规范化名称：trim、非空、长度上限。
  String _normalizeName(String value, String field) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(value, field, '$field 不能为空');
    }
    if (trimmed.length > maxNameLength) {
      throw ArgumentError.value(value, field, '$field 不能超过 $maxNameLength 个字符');
    }
    return trimmed;
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

  Future<int> _findOrCreateLocation(DatabaseExecutor db, String name, int now) async {
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
      Location(name: name, createdAt: now, updatedAt: now).toMap(),
    );
  }

  Future<int> _link(DatabaseExecutor db, int itemId, int locationId, int now) async {
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
      ).toMap(),
    );
  }

  /// 新增一个可选位置（trim、非空、超长校验）。同名未删除位置幂等返回原 id。
  Future<int> addLocation(String name) async {
    final valid = _normalizeName(name, '位置名称');
    final db = await open();
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.transaction<int>((txn) => _findOrCreateLocation(txn, valid, now));
  }

  /// 列出全部未删除位置，供界面选择。按名称排序。
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
  Future<UpsertResult> upsertItemLocation(String itemName, int locationId) async {
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
      await _link(txn, itemId, locationId, now);
      return UpsertResult(itemId: itemId, locationId: locationId, created: true);
    });
  }

  /// 按精确名称查询，返回该物品及其全部未删除位置（同名多位置全量）。
  /// 名称 trim；空名或非精确（如「梯」查「梯子」）都查不到。
  Future<ItemWithLocations?> findByName(String name) async {
    final key = name.trim();
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

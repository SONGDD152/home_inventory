import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'item.dart';

/// 物品数据访问层。
///
/// 依赖可注入：
///  * [databaseFactory] —— 生产用 sqflite 默认工厂；测试可注入
///    sqflite_common_ffi 的 databaseFactoryFfi，从而在桌面/Dart VM 跑测试。
///  * [databasePath] —— 测试可指向临时文件库，验证「重开文件库仍有数据」。
///
/// 这里不解析自然语言；「把梯子放到阳台」这类语句的拆分由上层完成，
/// 本层只接收 name / location 的精确值。
class InventoryDatabase {
  InventoryDatabase({
    DatabaseFactory? databaseFactory,
    String? databasePath,
    this.version = 2,
  })  : _injectedFactory = databaseFactory,
        _injectedPath = databasePath;

  static const String tableItems = 'items';
  static const String columnId = 'id';
  static const String columnName = 'name';
  static const String columnLocation = 'location';
  static const String columnIsDeleted = 'is_deleted';
  static const String columnCreatedAt = 'created_at';
  static const String columnUpdatedAt = 'updated_at';

  /// 部分唯一索引：只对未软删除的行约束 (name, location) 唯一。
  /// 软删除后同名同位置可以重新录入，不会被旧记录挡住。
  static const String activeUniqueIndex = 'idx_items_active_unique';

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

  /// 打开（或复用）数据库连接。
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

  /// 当前是否持有打开的底层连接；未打开或已 [close] 时为 false。
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
        $columnLocation TEXT NOT NULL,
        $columnIsDeleted INTEGER NOT NULL DEFAULT 0,
        $columnCreatedAt INTEGER NOT NULL,
        $columnUpdatedAt INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_items_name ON $tableItems($columnName)',
    );
    await db.execute(
      'CREATE INDEX idx_items_location ON $tableItems($columnLocation)',
    );
    await _createActiveUniqueIndex(db);
  }

  Future<void> _createActiveUniqueIndex(Database db) async {
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS $activeUniqueIndex '
      'ON $tableItems($columnName, $columnLocation) '
      'WHERE $columnIsDeleted = 0',
    );
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // v1 -> v2：补上「未删除记录 (name, location) 唯一」的部分唯一索引。
    if (oldVersion < 2) {
      await _createActiveUniqueIndex(db);
    }
  }

  /// 校验并规范化名称/位置。
  ///
  /// 空或纯空白直接抛 [ArgumentError]，避免界面连点或误触写入脏数据；
  /// 首尾空白被裁掉，保证「梯子 」与「梯子」不会绕过唯一约束。
  Item _normalize(Item item) {
    final name = item.name.trim();
    final location = item.location.trim();
    if (name.isEmpty) {
      throw ArgumentError.value(item.name, 'name', '物品名称不能为空');
    }
    if (location.isEmpty) {
      throw ArgumentError.value(item.location, 'location', '存放位置不能为空');
    }
    return item.copyWith(name: name, location: location);
  }

  /// 新增一条物品记录，返回新记录 id。
  ///
  /// 会先做参数校验。若存在同名同位置的未删除记录，部分唯一索引会拒绝写入；
  /// 界面录入应优先用幂等的 [upsert]，避免连点两下产生重复或报错。
  Future<int> insert(Item item) async {
    final valid = _normalize(item);
    final db = await open();
    return db.insert(tableItems, valid.toMap());
  }

  /// 幂等写入：按「名称 + 位置 + 未删除」查重。
  ///
  /// 查重与写入在同一个事务里完成：已存在则只刷新 updated_at 并返回原 id，
  /// 不存在才插入。界面连点两下也只会得到一条记录。
  /// 返回 (id, 是否新建) 便于上层区分「新录入」与「重复点击」。
  Future<UpsertResult> upsert(Item item) async {
    final valid = _normalize(item);
    final db = await open();
    return db.transaction<UpsertResult>((txn) async {
      final rows = await txn.query(
        tableItems,
        columns: <String>[columnId],
        where: '$columnName = ? AND $columnLocation = ? AND $columnIsDeleted = 0',
        whereArgs: <Object?>[valid.name, valid.location],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        final id = rows.first[columnId] as int;
        await txn.update(
          tableItems,
          <String, Object?>{
            columnUpdatedAt: DateTime.now().millisecondsSinceEpoch,
          },
          where: '$columnId = ?',
          whereArgs: <Object?>[id],
        );
        return UpsertResult(id: id, created: false);
      }
      final id = await txn.insert(tableItems, valid.toMap());
      return UpsertResult(id: id, created: true);
    });
  }

  /// 查询物品。
  ///
  /// [includeDeleted] 默认 false：软删除的记录不出现在结果中。
  Future<List<Item>> getAll({bool includeDeleted = false}) async {
    final db = await open();
    final where = includeDeleted ? null : '$columnIsDeleted = 0';
    final rows = await db.query(
      tableItems,
      where: where,
      orderBy: '$columnId ASC',
    );
    return rows.map(Item.fromMap).toList(growable: false);
  }

  /// 按 id 取单条；默认同样过滤软删除记录。
  Future<Item?> getById(int id, {bool includeDeleted = false}) async {
    final db = await open();
    final clause = includeDeleted
        ? '$columnId = ?'
        : '$columnId = ? AND $columnIsDeleted = 0';
    final rows = await db.query(
      tableItems,
      where: clause,
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Item.fromMap(rows.first);
  }

  /// 软删除：只置 is_deleted，不物理删除行。
  Future<int> softDelete(int id) async {
    final db = await open();
    return db.update(
      tableItems,
      <String, Object?>{
        columnIsDeleted: 1,
        columnUpdatedAt: DateTime.now().millisecondsSinceEpoch,
      },
      where: '$columnId = ?',
      whereArgs: <Object?>[id],
    );
  }
}

/// [InventoryDatabase.upsert] 的结果。
class UpsertResult {
  const UpsertResult({required this.id, required this.created});

  /// 命中已有记录时为原记录 id，新建时为新记录 id。
  final int id;

  /// true 表示确实新增了一条；false 表示命中已有记录，只刷新了时间戳。
  final bool created;
}

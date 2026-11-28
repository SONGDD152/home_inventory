import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'domain.dart';
import '../domain/domain_instance.dart';
import '../domain/reminder_editor.dart';
import '../domain/repeat_rule.dart';
import '../domain/todo_state_writer.dart';
import 'item.dart';
import 'inventory_repository.dart';
import 'normalize.dart';
import 'reminder.dart';
import 'reminder_repository.dart';
import 'todo_state.dart';

/// 小本本数据访问层（三张表：物品 / 位置 / 关联）。
///
/// 关系模型：
///  * 一件物品可以放在多个位置；一个位置可以放多件物品（多对多）；
///  * [tableItemLocations] 是关联表，用 (item_id, location_id) 唯一约束防重复。
///
/// 依赖可注入：[databaseFactory]（生产用 sqflite 默认工厂，测试注入 ffi）、
/// [databasePath]（测试指向临时文件库，验证重开仍有数据）。
///
/// 这里不解析自然语言；「梯子在哪」的拆分由上层完成，本层只接收精确字段值。
class InventoryDatabase implements InventoryRepository, ReminderRepository,
    ReminderEditor, TodoStateWriter, TodoStateReader, DomainInstance {
  /// V4.1：当前库文件的 schema 版本。
  ///
  /// v10 = V3.13（仓储六表）；v11 = V4.0（加 reminders / daily_reports 两表）；
  /// **v12 = V4.1 批次 1（加 todo_states 第 9 表）**；
  /// **v13 = V4.1 批次 2（reminders 加 priority 列，元宝裁定①）**。
  /// 两域各自独立升级到 v13：生活库走 v10→v11→v12→v13 迁移，
  /// 工作库新建直接建到 v13。
  ///
  /// v12 迁移只做 `CREATE TABLE IF NOT EXISTS`——**不动任何旧表旧列**，
  /// 所以旧备份兼容零风险、老代码读路径不变、迁移幂等天然满足。
  /// v13 迁移用幂等加列（`_addColumnIfMissing`），同样不碰任何旧列。
  static const int currentSchemaVersion = 13;

  /// 生产构造：不暴露任何测试钩子，生产入口 main.dart 用此构造。
  ///
  /// V4.0：[domain] 决定这个实例管哪本账——生活域用 `home_inventory.db`
  /// （路径不变，用户既有数据天然保留），工作域用 `work_inventory.db`（新建）。
  InventoryDatabase({
    DatabaseFactory? databaseFactory,
    String? databasePath,
    this.version = currentSchemaVersion,
    this.domain = InventoryDomain.life,
  })  : _injectedFactory = databaseFactory,
        _injectedPath = databasePath,
        _migrationFailureHook = null,
        _migrationV5FailureHook = null,
        _migrationV6FailureHook = null,
        _migrationV7FailureHook = null,
        _migrationV8FailureHook = null,
        _migrationV9FailureHook = null,
        _migrationV10FailureHook = null;

  /// 测试专用构造：注入迁移失败钩子，验证 onUpgrade 事务整体回滚。
  /// 仅供测试使用，生产代码路径不调用（见 V1_ACCEPTANCE.md R2）。
  /// 四个钩子分别覆盖 v4 名称清洗、v5 加列与 v6 加列阶段的失败回滚。
  InventoryDatabase.forTesting({
    DatabaseFactory? databaseFactory,
    String? databasePath,
    this.version = currentSchemaVersion,
    this.domain = InventoryDomain.life,
    void Function()? migrationFailureHook,
    void Function()? migrationV5FailureHook,
    void Function()? migrationV6FailureHook,
    void Function()? migrationV7FailureHook,
    void Function()? migrationV8FailureHook,
    void Function()? migrationV9FailureHook,
    void Function()? migrationV10FailureHook,
  })  : _injectedFactory = databaseFactory,
        _injectedPath = databasePath,
        _migrationFailureHook = migrationFailureHook,
        _migrationV5FailureHook = migrationV5FailureHook,
        _migrationV6FailureHook = migrationV6FailureHook,
        _migrationV7FailureHook = migrationV7FailureHook,
        _migrationV8FailureHook = migrationV8FailureHook,
        _migrationV9FailureHook = migrationV9FailureHook,
        _migrationV10FailureHook = migrationV10FailureHook;

  static const String tableItems = 'items';
  static const String tableLocations = 'locations';
  static const String tableItemLocations = 'item_locations';
  // V3.7 借阅管理：借阅人表 + 借出记录表。
  static const String tableBorrowers = 'borrowers';
  static const String tableLoans = 'loans';
  // V3.12 部分废弃：废弃流水表（一次"废了几个"一行）。
  static const String tableItemDiscards = 'item_discards';
  // V4.0 日程/日报：提醒条目表 + 日报存档表。
  static const String tableReminders = 'reminders';
  static const String tableDailyReports = 'daily_reports';

  /// V4.1：催办条目状态表（第 9 张）。
  ///
  /// **所有催办条目状态的唯一权威源**——日程类（reminders）与系统类
  /// （借出到期，loans 派生）共用同一套完成/延期状态机。
  /// reminders 表与 loans 表**只读不写状态**。
  static const String tableTodoStates = 'todo_states';

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
  // V3.11：按位置记数量——item_locations.quantity（每个位置几个）。
  static const String columnLocationQuantity = 'quantity';
  // V3.12：废弃流水字段。
  static const String columnDiscardQuantity = 'quantity';
  static const String columnDiscardLocationId = 'location_id';
  static const String columnDiscardLocationName = 'location_name';
  static const String columnDiscardedAt = 'discarded_at';
  static const String columnSourceType = 'source_type';
  static const String columnRestoredQuantity = 'restored_quantity';
  // V4.0 提醒/日报字段。
  static const String columnTitle = 'title';
  static const String columnDetail = 'detail';
  static const String columnReminderDueAt = 'due_at';
  static const String columnStatus = 'status';
  static const String columnDoneAt = 'done_at';
  static const String columnRepeatRule = 'repeat_rule';
  // V4.1 批次 2：提醒优先级（元宝裁定①：0低 / 1中 / 2高，默认 1）。
  static const String columnPriority = 'priority';
  static const String columnReportDate = 'report_date';
  static const String columnContentMd = 'content_md';
  static const String columnGeneratedAt = 'generated_at';
  static const String columnSourceSnapshot = 'source_snapshot';

  // ── V4.1：todo_states 表列常量 ──
  // 说明：columnSourceType 复用上方已有的 'source_type'（item_discards 在用，
  // 同名不同表，sqflite 允许）；这里只补 todo_states 独有的几列。
  static const String columnSourceId = 'source_id';
  static const String columnDeferCount = 'defer_count';
  static const String columnHandleNote = 'handle_note';
  static const String columnNextDueAt = 'next_due_at';

  /// 提醒状态：待办 / 已完成（两态，不硬删——已完成也要留着，日报要看）。
  static const String reminderStatusPending = 'pending';
  static const String reminderStatusDone = 'done';

  /// 未删除记录的唯一约束：物品名唯一、位置名唯一、同一(物品,位置)关联唯一。
  static const String itemsUniqueIndex = 'idx_items_name_unique';
  static const String locationsUniqueIndex = 'idx_locations_name_unique';
  static const String associationUniqueIndex = 'idx_assoc_item_location_unique';

  /// 名称长度上限，超出抛 ArgumentError（超长位置是明确的验收点）。
  static const int maxNameLength = 100;

  final DatabaseFactory? _injectedFactory;
  final String? _injectedPath;
  final int version;

  /// V4.0：本实例管哪本账。
  ///
  /// 决定两件事：① 库文件路径（[InventoryDomain.fileName]）② 备份里的域标识。
  /// 两域各自持有独立实例，**共用同一套引擎代码**——借出/废弃/数量/位置/校准
  /// 逻辑不写第二遍，只是连的库不同。
  final InventoryDomain domain;

  /// V4.0：在飞操作计数（切库守卫用）。
  ///
  /// 切域时必须等旧实例在飞查询收尾，否则旧结果可能盖掉新域界面。
  /// 只统计**重查询**（见 [_tracked] 的调用点）与显式挂起的操作。
  int _activeOperations = 0;

  /// 当前在飞操作数（切库守卫读它判断能否安全切换）。
  @override
  int get activeOperations => _activeOperations;

  /// V4.0：切换期间写操作闸门。
  ///
  /// 切域过程中正在落库的操作如果继续跑，可能写进"马上要作废的那本账"。
  /// 因此切换期间**直接拒绝写入**（抛 [DomainSwitchInProgress]），
  /// **不静默重试**——静默重试正是写错库的来源。
  bool _writesBlocked = false;

  /// 切换期间禁止本实例写入（由切库守卫调用）。
  @override
  void setWritesBlocked(bool blocked) {
    _writesBlocked = blocked;
  }

  /// 写操作前的闸门检查。
  void _guardWrite() {
    if (_writesBlocked) {
      throw const DomainSwitchInProgress();
    }
  }

  /// 把一次可能较慢的操作计入在飞计数。
  Future<T> _tracked<T>(Future<T> Function() action) async {
    _activeOperations++;
    try {
      return await action();
    } finally {
      _activeOperations--;
    }
  }

  /// 挂起一次"在飞操作"（切库守卫的测试用它制造超时场景）。
  ///
  /// 生产上用于切域前把长查询纳入守卫视野；测试里用来模拟
  /// 「旧实例查询迟迟不收尾 → 切域超时」。
  Future<T> trackOperation<T>(Future<T> Function() action) => _tracked(action);

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

  /// V3.11：v9 迁移失败注入点（item_locations 加数量列/分配前调用），
  /// 验证整体回滚、版本退回 8。私有字段，仅 forTesting 可注入。
  final void Function()? _migrationV9FailureHook;

  /// V3.12：v10 迁移失败注入点（建废弃流水表前调用），
  /// 验证整体回滚、版本退回 9。私有字段，仅 forTesting 可注入。
  final void Function()? _migrationV10FailureHook;

  Database? _db;

  DatabaseFactory get _factory => _injectedFactory ?? databaseFactory;

  Future<String> _resolvePath() async {
    final injected = _injectedPath;
    if (injected != null) return injected;
    // V4.0：库文件按域分家——生活域沿用旧路径（用户数据天然保留），
    // 工作域是独立新文件。物理隔离是 PM 拍板的方案 B。
    return p.join(await getDatabasesPath(), domain.fileName);
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

  // ---------- V4.0 DomainInstance 实现 ----------

  @override
  InventoryRepository get repository => this;

  @override
  String get domainId => domain.id;

  /// 重建连接（脏连接自愈）：关掉再打开，schema 版本不变、数据不动。
  @override
  Future<void> reopen() async {
    await close();
    await open();
  }

  @override
  @override
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
        $columnTags TEXT,
        $columnLocationQuantity INTEGER NOT NULL DEFAULT 1
      )
    ''');
    await _createBorrowTables(db);
    await _createDiscardTables(db);
    await _createReminderTables(db);
    await _createTodoStateTable(db);
    await _createIndexes(db);
  }

  /// V4.0：提醒条目表 + 日报存档表。
  ///
  /// 两域**结构完全一致**（各 8 张表，逐表逐列核对）——工作域虽然本轮
  /// 不开放提醒功能，但表照样建齐，这样两本账的 schema 可以直接对比。
  ///
  /// 「工作区暂不支持提醒」是**能力开关**（见 [domain.dart] 的
  /// [domainCapabilities]），不是「表不存在」——技术口吻不给用户看。
  Future<void> _createReminderTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableReminders (
        $columnId INTEGER PRIMARY KEY AUTOINCREMENT,
        $columnTitle TEXT NOT NULL,
        $columnDetail TEXT,
        $columnDueAt INTEGER,
        $columnStatus TEXT NOT NULL DEFAULT '$reminderStatusPending',
        $columnDoneAt INTEGER,
        $columnRepeatRule TEXT,
        $columnPriority INTEGER NOT NULL DEFAULT 1,
        $columnIsDeleted INTEGER NOT NULL DEFAULT 0,
        $columnCreatedAt INTEGER NOT NULL,
        $columnUpdatedAt INTEGER NOT NULL,
        $columnDeletedAt INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableDailyReports (
        $columnId INTEGER PRIMARY KEY AUTOINCREMENT,
        $columnReportDate TEXT NOT NULL,
        $columnContentMd TEXT NOT NULL,
        $columnGeneratedAt INTEGER NOT NULL,
        $columnSourceSnapshot TEXT
      )
    ''');
    // 一日一条：日报按日期唯一，避免并发补生成写重复。
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_daily_reports_date '
      'ON $tableDailyReports($columnReportDate)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_reminders_due '
      'ON $tableReminders($columnDueAt)',
    );
  }

  /// V4.1：催办条目状态表（`todo_states`）——**第 9 张表**。
  ///
  /// 字段口径（元宝 2026-11-26 裁定）：
  /// - `id`：自增主键；
  /// - `source_type`：`schedule_reminder`（日程类）/ `loan_due`（借出到期类）；
  /// - `source_id`：原表主键（`reminders.id` / `loans.id`）；
  /// - `status`：`pending` / `done` / `deferred`；
  /// - `done_at`：处理时间；
  /// - `defer_count`：延期次数，**按「次」累计，跨天不重置**；
  /// - `handle_note`：处理备注 / 延期原因；
  /// - `next_due_at`：延期后的下一次提示时间。
  ///
  /// **关于 `next_due_at`（对元宝字段清单的唯一一处增补）**：
  /// 元宝 B4 要求「到期当天未处理 → 自动延期 → 到期当天再次提示」。
  /// 「再次提示」的时间点必须有地方存，否则只有两条路——
  /// ① 去推 `reminders.due_at`：那等于让概览越界写日程表，
  ///    破了 PM 拍板的「概览只写待办状态」边界；
  /// ② 用 `defer_count` 反推天数：那「按次累计」就退化成「按天累计」，
  ///    与 B4「按次累计，非按天」**直接冲突**。
  /// 所以它是延期机制的必要存储位，**不是**「新催办源」的表结构扩展，
  /// 不违反「后续加新源只加枚举值、不加表不加列」。
  ///
  /// 迁移只用 `CREATE TABLE IF NOT EXISTS`——**不动任何旧表旧列**，
  /// 幂等天然满足（连跑两次结果一致），旧备份兼容零风险。
  Future<void> _createTodoStateTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableTodoStates (
        $columnId INTEGER PRIMARY KEY AUTOINCREMENT,
        $columnSourceType TEXT NOT NULL,
        $columnSourceId INTEGER NOT NULL,
        $columnStatus TEXT NOT NULL DEFAULT '${TodoStatus.pending}',
        $columnDoneAt INTEGER,
        $columnDeferCount INTEGER NOT NULL DEFAULT 0,
        $columnHandleNote TEXT,
        $columnNextDueAt INTEGER,
        $columnCreatedAt INTEGER NOT NULL,
        $columnUpdatedAt INTEGER NOT NULL
      )
    ''');
    // 一个源条目只允许有一条状态记录。
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_todo_states_source '
      'ON $tableTodoStates($columnSourceType, $columnSourceId)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_todo_states_status '
      'ON $tableTodoStates($columnStatus)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_todo_states_next_due '
      'ON $tableTodoStates($columnNextDueAt)',
    );
  }

  /// V3.12：废弃流水表。
  ///
  /// 一行 = 一次"废了几个"。与"整件废弃"（items 行软删）是两种语义，
  /// 彻底分开：整件废弃走老链路（恢复时各位置原样还原），部分废弃走
  /// 流水（恢复时按 PM 口径重新问位置）。
  ///
  /// [columnRestoredQuantity] 取代 is_deleted/flag，支持"恢复 1 个、
  /// 另 1 个还在回收站"（元宝批复第 1 条）。
  Future<void> _createDiscardTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableItemDiscards (
        $columnId INTEGER PRIMARY KEY AUTOINCREMENT,
        $columnItemId INTEGER NOT NULL,
        $columnItemName TEXT NOT NULL,
        $columnDiscardQuantity INTEGER NOT NULL,
        $columnDiscardLocationId INTEGER,
        $columnDiscardLocationName TEXT,
        $columnDiscardedAt INTEGER NOT NULL,
        $columnSourceType TEXT NOT NULL DEFAULT 'in_stock',
        $columnRestoredQuantity INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_discards_item '
      'ON $tableItemDiscards($columnItemId)',
    );
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
    // V3.11：位置数量列必须在**所有历史迁移路径**开始前就存在。
    // v3→v4 / v5→v6 的迁移会重写 item_locations 行（ItemLocation.toMap
    // 现在会写 quantity），而加列原本排在最后的 v8→v9，导致旧库升级
    // 中途报「table item_locations has no column named quantity」。
    // 提前幂等加列，v8→v9 再负责把老总数分配进各位置（两步职责不混）。
    final locationTables = await db.query(
      'sqlite_master',
      columns: <String>['name'],
      where: "type = 'table' AND name = ?",
      whereArgs: <Object?>[tableItemLocations],
    );
    if (locationTables.isNotEmpty) {
      await _addColumnIfMissing(db, tableItemLocations,
          columnLocationQuantity,
          type: 'INTEGER NOT NULL DEFAULT 1');
    }

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

    // v8 → v9：V3.11 按位置记数量——item_locations 加 quantity 列，
    // 并把每件物品的 in 库总数（items.quantity）分配到它的活跃位置关联上。
    //
    // 分配口径（元宝批复）：按位置数平均分配，余数给「主位置」（活跃关联
    // id 最小者）。核心不变式：迁移前后 items.quantity 一分不差，且
    // SUM(活跃关联 quantity) == items.quantity。
    // 全程在 sqflite 升级事务内，失败整体回滚、版本退回 8。
    if (oldVersion < 9 && newVersion >= 9) {
      final v9Hook = _migrationV9FailureHook;
      if (v9Hook != null) v9Hook();
      await _addColumnIfMissing(db, tableItemLocations, columnLocationQuantity,
          type: 'INTEGER NOT NULL DEFAULT 1');

      // 逐件物品重新分配，保证总数守恒。
      final itemRows = await db.query(
        tableItems,
        columns: <String>[columnId, columnQuantity],
        where: '$columnIsDeleted = 0',
        orderBy: '$columnId ASC',
      );
      for (final itemRow in itemRows) {
        final itemId = itemRow[columnId] as int;
        final total = (itemRow[columnQuantity] as num?)?.toInt() ?? 1;
        final links = await db.query(
          tableItemLocations,
          columns: <String>[columnId],
          where: '$columnItemId = ? AND $columnIsDeleted = 0',
          whereArgs: <Object?>[itemId],
          orderBy: '$columnId ASC', // id 最小 = 主位置，拿余数。
        );
        if (links.isEmpty) continue;
        final n = links.length;
        final base = total ~/ n;
        final remainder = total % n;
        for (var i = 0; i < links.length; i++) {
          // 数量允许为 0（物品少于位置数时，多余位置记 0）——
          // 这样才能严格保证 SUM(位置数量) == 迁移前 items.quantity。
          // 把 0 抬成 1 会让总数凭空变多，违反双向对账。
          final qty = base + (i == 0 ? remainder : 0);
          await db.update(
            tableItemLocations,
            <String, Object?>{columnLocationQuantity: qty},
            where: '$columnId = ?',
            whereArgs: <Object?>[links[i][columnId] as int],
          );
        }
      }
    }

    // v9 → v10：V3.12 部分废弃——新建「废弃流水」表。
    //
    // 老库（v9 及更早）没有部分废弃这个概念，物品只有"在/不在明细"
    // 两态，所以**不需要任何数据搬迁**：新表建出来是空的，老数据语义
    // 天然对齐（老库的整件废弃仍是 items 软删行，恢复时原样还原）。
    // 全程在 sqflite 升级事务内，失败整体回滚、版本退回 9。
    if (oldVersion < 10 && newVersion >= 10) {
      final v10Hook = _migrationV10FailureHook;
      if (v10Hook != null) v10Hook();
      await _createDiscardTables(db);
    }

    // v10 → v11：V4.0 日程/日报——新建 reminders / daily_reports 两张表。
    // 两域结构一致：工作库走 onCreate 直接建到 v11，生活库从这里补齐，
    // 元宝验收要求「工作库八表与生活库 v11 逐表逐列核对」。
    // 老库没有日程概念 → **不需要任何数据搬迁**，新表建出来是空的。
    if (oldVersion < 11 && newVersion >= 11) {
      await _createReminderTables(db);
    }

    // v11 → v12：V4.1 催办状态——新建 todo_states 第 9 张表。
    //
    // 关键性质：**只 CREATE，不 ALTER**——旧表旧列一个字都不动。
    // 所以（a）迁移幂等天然满足（连跑两次结果一致）；
    //     （b）旧备份文件（v11 结构）恢复进 v12 库后读路径不变；
    //     （c）回滚到 v11 只需把版本号改回去，v11 不认识这张表但也不碰它。
    // 元宝验收口径同步升级：「工作库八表与 v11 逐表核对」→ **「九表与 v12 逐表核对」**。
    if (oldVersion < 12 && newVersion >= 12) {
      await _createTodoStateTable(db);
    }

    // v12 → v13：V4.1 批次 2 提醒优先级——reminders 加 priority 列。
    //
    // 用幂等加列（`_addColumnIfMissing`）：列已存在就跳过，
    // 所以连跑两次结果一致、迁移可重入。
    //
    // 旧数据默认 1（中）：元宝裁定①「默认1」——
    // 老提醒不该因为升级就被判成低优先级。
    if (oldVersion < 13 && newVersion >= 13) {
      await _addColumnIfMissing(db, tableReminders, columnPriority,
          type: 'INTEGER NOT NULL DEFAULT 1');
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
  /// 单人库存数据量小，采用"读出有效数据 → 归一化 → 重建"：归一化后同名
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
    var normalized = normalizeName(value);
    // V3.10 复验打回（元宝补充①）：数据层双保险——解析器若漏剥后置数量
    // （语音语序变异），落库前再剥一次，防止「梯子3个」这种脏名入库。
    // 只处理物品名；位置名（如「3单元」）不能被剥。
    if (field == '物品名称') normalized = stripTrailingQuantity(normalized);
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
      {String? rawText, int quantity = 1}) async {
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
        quantity: quantity,
      ).toMap(),
    );
  }

  /// V3.11 全局不变式的单一入口：重算某物品全部**活跃**关联的数量之和，
  /// 写回 items.quantity 作为总数缓存。元宝批复要求所有改动位置的路径
  /// （录入/累加/挪位/借出/归还/校准/备份恢复收口）都走这里，禁止另写一套。
  ///
  /// 返回写回后的总数。调用方必须在同一个事务的 executor 上调用。
  Future<int> _syncItemTotal(
    DatabaseExecutor txn,
    int itemId, {
    int? now,
  }) async {
    final rows = await txn.rawQuery(
      'SELECT COALESCE(SUM($columnLocationQuantity), 0) AS total '
      'FROM $tableItemLocations '
      'WHERE $columnItemId = ? AND $columnIsDeleted = 0',
      <Object?>[itemId],
    );
    final total = (rows.first['total'] as num?)?.toInt() ?? 0;
    await txn.update(
      tableItems,
      <String, Object?>{
        columnQuantity: total,
        if (now != null) columnUpdatedAt: now,
      },
      where: '$columnId = ?',
      whereArgs: <Object?>[itemId],
    );
    return total;
  }

  /// V3.11：读某物品在指定位置的数量（活跃关联）。无关联返回 0。
  Future<int> _readLocationQty(
    DatabaseExecutor txn,
    int itemId,
    int locationId,
  ) async {
    final rows = await txn.query(
      tableItemLocations,
      columns: <String>[columnLocationQuantity],
      where: '$columnItemId = ? AND $columnLocationId = ? AND $columnIsDeleted = 0',
      whereArgs: <Object?>[itemId, locationId],
      limit: 1,
    );
    if (rows.isEmpty) return 0;
    return (rows.first[columnLocationQuantity] as num?)?.toInt() ?? 0;
  }

  /// V3.11：写某物品在指定位置的数量（活跃关联）。关联不存在则新建。
  Future<void> _writeLocationQty(
    DatabaseExecutor txn,
    int itemId,
    int locationId,
    int qty,
    int now, {
    String? rawText,
  }) async {
    final rows = await txn.query(
      tableItemLocations,
      columns: <String>[columnId],
      where: '$columnItemId = ? AND $columnLocationId = ? AND $columnIsDeleted = 0',
      whereArgs: <Object?>[itemId, locationId],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      await txn.update(
        tableItemLocations,
        <String, Object?>{
          columnLocationQuantity: qty,
          columnUpdatedAt: now,
        },
        where: '$columnId = ?',
        whereArgs: <Object?>[rows.first[columnId] as int],
      );
      return;
    }
    await txn.insert(
      tableItemLocations,
      ItemLocation(
        itemId: itemId,
        locationId: locationId,
        createdAt: now,
        updatedAt: now,
        rawText: rawText,
        quantity: qty,
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
    _guardWrite();
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
    _guardWrite();
    final db = await open();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction<void>((txn) async {
      await _softDeleteWholeItem(txn, id, now);
    });
  }

  /// V3.12：软删整件物品（物品行 + 全部活跃位置关联）。
  ///
  /// 整件废弃（[deleteItem]）与「部分废弃废完整个物品」共用这一段，
  /// 保证两条路径的软删语义**完全一致**（同一时间戳、同一留底口径）。
  ///
  /// V3.13（PM 2026-11-26 真机截图暴露）：**级联软删该物品的在借记录**。
  /// 之前只删 items + item_locations，loans 原封不动 → 物品进了回收站，
  /// 借出管理页却照常显示「梯子 ×1 借出中」，留下一笔**孤儿借出**：
  /// 账平不了，而且从回收站恢复梯子后会凭空多出 2 个在借。
  /// 现在一并软删进回收站（与 [deleteLoan] 同一留底口径，可追溯可恢复）。
  Future<void> _softDeleteWholeItem(
    DatabaseExecutor txn,
    int itemId,
    int now,
  ) async {
    final updated = await txn.update(
      tableItems,
      <String, Object?>{
        columnIsDeleted: 1,
        columnDeletedAt: now,
        columnUpdatedAt: now,
      },
      where: '$columnId = ? AND $columnIsDeleted = 0',
      whereArgs: <Object?>[itemId],
    );
    if (updated == 0) return; // 不存在或已删除，幂等返回。
    await txn.update(
      tableItemLocations,
      <String, Object?>{columnIsDeleted: 1, columnUpdatedAt: now},
      where: '$columnItemId = ? AND $columnIsDeleted = 0',
      whereArgs: <Object?>[itemId],
    );
    // V3.13：级联软删在借记录 —— 绝不留孤儿借出。
    //
    // ⚠ 老库升级路径的坑：loans 表是 V3.7 才引入的，v5→v6 升级过程中
    // loans 表**还不存在**，直接 UPDATE 会报 "no such table: loans" 把
    // 升级打挂（inventory_database_test 的 v5 旧库升级用例守住了这个）。
    // 所以先确认表在不在。
    if (await _tableExists(txn, tableLoans)) {
      await txn.update(
        tableLoans,
        <String, Object?>{
          columnIsDeleted: 1,
          columnDeletedAt: now,
          columnUpdatedAt: now,
        },
        where: '$columnItemId = ? AND $columnIsDeleted = 0',
        whereArgs: <Object?>[itemId],
      );
    }
  }

  /// 某张表在当前库里存在吗？（老库升级时后加的表可能还没有）
  Future<bool> _tableExists(DatabaseExecutor txn, String table) async {
    final rows = await txn.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      <Object?>[table],
    );
    return rows.isNotEmpty;
  }

  // ==================== V3.12 部分废弃（废弃流水） ====================

  /// V3.12：部分废弃——把某位置的 N 个移出明细，其余留在明细里。
  ///
  /// 口径（PM 2026-11-25 拍板）：
  ///  * 从**哪个位置**扣 → 由 UI 弹窗问好后传 [locationId]；
  ///  * 数量 == 在库总数 → **自动转整件废弃**（物品整条进回收站），
  ///    不留 0 数量的僵尸记录；
  ///  * 数量 < 在库总数 → 该位置数量减 N，写一条废弃流水，
  ///    物品记录保留，明细里还剩其余的；
  ///  * 位置上的数量不够 → 抛中文错误，**不改任何数量**。
  ///
  /// [sourceType] 标记废弃来源（在库 / 在借），供未来统计维度用
  /// （元宝批复第 2 条）。
  @override
  Future<DiscardOutcome> discardQuantity(
    String itemName,
    int quantity, {
    required int locationId,
    DiscardSource sourceType = DiscardSource.inStock,
  }) async {
    _guardWrite();
    if (quantity < 1) {
      throw ArgumentError.value(quantity, 'quantity', '废弃数量至少 1 个');
    }
    final valid = normalizeName(itemName);
    final db = await open();
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.transaction<DiscardOutcome>((txn) async {
      final itemId = await _requireItemId(txn, valid);
      final locName = await _locationName(txn, locationId);
      if (locName == null) {
        throw ArgumentError.value(locationId, 'locationId', '位置不存在或已删除');
      }
      final locQty = await _readLocationQty(txn, itemId, locationId);
      if (locQty < quantity) {
        throw ArgumentError.value(quantity, 'quantity',
            '$locName 只有 $locQty 个，不够废弃 $quantity 个');
      }
      final stock = await _readStock(txn, itemId);
      if (stock < quantity) {
        throw ArgumentError.value(quantity, 'quantity',
            '「$valid」一共只有 $stock 个，不够废弃 $quantity 个');
      }
      // 废完 → 自动转整件废弃（物品进回收站，不产生流水）。
      if (stock == quantity) {
        await _softDeleteWholeItem(txn, itemId, now);
        await _assertConservation(txn);
        return DiscardOutcome(
          itemName: valid,
          quantity: quantity,
          wholeItem: true,
          locationName: locName,
        );
      }
      await _writeLocationQty(txn, itemId, locationId, locQty - quantity, now);
      await txn.insert(tableItemDiscards, <String, Object?>{
        columnItemId: itemId,
        columnItemName: valid,
        columnDiscardQuantity: quantity,
        columnDiscardLocationId: locationId,
        columnDiscardLocationName: locName,
        columnDiscardedAt: now,
        columnSourceType: sourceType.code,
        columnRestoredQuantity: 0,
      });
      final remaining = await _syncItemTotal(txn, itemId, now: now);
      await _assertConservation(txn);
      return DiscardOutcome(
        itemName: valid,
        quantity: quantity,
        wholeItem: false,
        locationName: locName,
        remainingInStock: remaining,
      );
    });
  }

  /// V3.12：恢复一条废弃流水（PM 口径：**恢复时问位置**，不依赖废弃时
  /// 的原位置）。
  ///
  /// [quantity] 为 null 时恢复全部未恢复的数量；支持只恢复一部分
  /// （元宝批复第 1 条：restored_quantity 字段先留着，不等改口径时再加列）。
  /// 物品若已整件废弃（行软删）则拒绝——那属于「恢复物品」那条路。
  @override
  Future<ItemDiscard> restoreDiscard(
    int discardId,
    int toLocationId, {
    int? quantity,
  }) async {
    _guardWrite();
    final db = await open();
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.transaction<ItemDiscard>((txn) async {
      final rows = await txn.query(
        tableItemDiscards,
        where: '$columnId = ?',
        whereArgs: <Object?>[discardId],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw ArgumentError.value(discardId, 'discardId', '找不到这条废弃记录');
      }
      final row = rows.first;
      final itemId = (row[columnItemId] as num).toInt();
      final name = row[columnItemName] as String;
      final total = (row[columnDiscardQuantity] as num?)?.toInt() ?? 0;
      final restored = (row[columnRestoredQuantity] as num?)?.toInt() ?? 0;
      final pending = total - restored;
      if (pending <= 0) {
        throw ArgumentError.value(
            discardId, 'discardId', '这条废弃记录已经全部恢复过了');
      }
      final want = quantity ?? pending;
      if (want < 1 || want > pending) {
        throw ArgumentError.value(quantity, 'quantity',
            '要恢复的数量必须在 1 ~ $pending 之间');
      }
      final itemRows = await txn.query(
        tableItems,
        columns: <String>[columnId, columnIsDeleted],
        where: '$columnId = ?',
        whereArgs: <Object?>[itemId],
        limit: 1,
      );
      if (itemRows.isEmpty ||
          (itemRows.first[columnIsDeleted] as num).toInt() == 1) {
        throw ArgumentError.value(discardId, 'discardId',
            '「$name」已整体进回收站，请先恢复物品再恢复这几个');
      }
      final locName = await _locationName(txn, toLocationId);
      if (locName == null) {
        throw ArgumentError.value(toLocationId, 'toLocationId', '位置不存在或已删除');
      }
      final cur = await _readLocationQty(txn, itemId, toLocationId);
      await _writeLocationQty(txn, itemId, toLocationId, cur + want, now);
      await txn.update(
        tableItemDiscards,
        <String, Object?>{columnRestoredQuantity: restored + want},
        where: '$columnId = ?',
        whereArgs: <Object?>[discardId],
      );
      await _syncItemTotal(txn, itemId, now: now);
      await _assertConservation(txn);
      final updated = await txn.query(
        tableItemDiscards,
        where: '$columnId = ?',
        whereArgs: <Object?>[discardId],
        limit: 1,
      );
      return _discardFromRow(updated.first);
    });
  }

  /// V3.12：读废弃流水（默认只返回还有待恢复数量的）。
  @override
  Future<List<ItemDiscard>> getDiscards({bool includeRestored = false}) async {
    final db = await open();
    final rows = await db.query(tableItemDiscards, orderBy: '$columnId DESC');
    final list = rows.map(_discardFromRow).toList(growable: false);
    if (includeRestored) return list;
    return list.where((d) => d.pendingQuantity > 0).toList(growable: false);
  }

  /// V3.12：彻底删除一条废弃流水（物理清除，不可恢复）。
  @override
  Future<void> purgeDiscard(int discardId) async {
    _guardWrite();
    final db = await open();
    await db.delete(
      tableItemDiscards,
      where: '$columnId = ?',
      whereArgs: <Object?>[discardId],
    );
  }

  ItemDiscard _discardFromRow(Map<String, Object?> row) {
    return ItemDiscard(
      id: (row[columnId] as num).toInt(),
      itemId: (row[columnItemId] as num).toInt(),
      itemName: row[columnItemName] as String,
      quantity: (row[columnDiscardQuantity] as num?)?.toInt() ?? 0,
      locationId: (row[columnDiscardLocationId] as num?)?.toInt(),
      locationName: row[columnDiscardLocationName] as String?,
      discardedAt: (row[columnDiscardedAt] as num?)?.toInt() ?? 0,
      sourceType: DiscardSource.fromCode(row[columnSourceType] as String?),
      restoredQuantity: (row[columnRestoredQuantity] as num?)?.toInt() ?? 0,
    );
  }

  /// V3.12：写一条废弃流水（部分废弃 / 校准差额共用）。
  Future<void> _insertDiscard(
    DatabaseExecutor txn, {
    required int itemId,
    required String itemName,
    required int quantity,
    int? locationId,
    String? locationName,
    required int now,
    DiscardSource sourceType = DiscardSource.inStock,
  }) async {
    if (quantity <= 0) return;
    await txn.insert(tableItemDiscards, <String, Object?>{
      columnItemId: itemId,
      columnItemName: itemName,
      columnDiscardQuantity: quantity,
      columnDiscardLocationId: locationId,
      columnDiscardLocationName: locationName,
      columnDiscardedAt: now,
      columnSourceType: sourceType.code,
      columnRestoredQuantity: 0,
    });
  }

  /// V3.12（元宝批复第 4 条）：数量守恒自检。
  ///
  /// 逐件校验 `items.quantity == SUM(活跃位置数量)`；
  /// 全局口径：总拥有数 = 在库 + 在借 + 整件废弃未恢复 + 部分废弃未恢复。
  ///
  /// **每次写操作后**都要过一次（不是只在测试场景跑）——写路径漏调
  /// [_syncItemTotal] 时这里会当场炸，而不是等到用户发现账不对。
  /// 仅在 debug 模式执行，release 下立即返回、无运行时开销。
  Future<void> _assertConservation(DatabaseExecutor txn) async {
    if (!kDebugMode) return;
    final broken = await _findConservationBreak(txn);
    if (broken.isNotEmpty) {
      throw StateError('V3.12 数量守恒被破坏：$broken');
    }
  }

  /// 返回守恒被破坏的说明；空列表表示账是平的。测试与诊断共用。
  Future<List<String>> _findConservationBreak(DatabaseExecutor txn) async {
    final rows = await txn.rawQuery(
      'SELECT i.id AS id, i.name AS name, i.quantity AS qty, '
      'COALESCE((SELECT SUM(l.quantity) FROM $tableItemLocations l '
      'WHERE l.item_id = i.id AND l.is_deleted = 0), 0) AS loc_total '
      'FROM $tableItems i WHERE i.is_deleted = 0',
    );
    final problems = <String>[];
    for (final row in rows) {
      final qty = (row['qty'] as num?)?.toInt() ?? 0;
      final locTotal = (row['loc_total'] as num?)?.toInt() ?? 0;
      if (qty != locTotal) {
        problems.add('「${row['name']}」物品数 $qty ≠ 位置数之和 $locTotal');
      }
    }
    // V3.13：补上「在借 ↔ 物品」这一维——之前只看物品↔位置，
    // 物品整件被删后恒等式反而成立，**孤儿借出查不出来**。
    final orphans = await txn.rawQuery(
      'SELECT l.id AS id, l.item_name AS name, l.borrower_name AS borrower, '
      'l.quantity AS qty, l.returned_qty AS returned '
      'FROM $tableLoans l '
      'LEFT JOIN $tableItems i ON i.id = l.item_id '
      'WHERE l.is_deleted = 0 AND l.returned_qty < l.quantity '
      'AND (i.id IS NULL OR i.is_deleted = 1)',
    );
    for (final row in orphans) {
      final qty = (row['qty'] as num?)?.toInt() ?? 0;
      final returned = (row['returned'] as num?)?.toInt() ?? 0;
      problems.add('「${row['name']}」有 ${row['borrower']} 借走 '
          '${qty - returned} 个，但物品已被删除（孤儿借出）');
    }
    return problems;
  }

  /// V3.12：对外的守恒校验（测试与诊断用；返回是否守恒）。
  @override
  Future<bool> checkConservation() async {
    final db = await open();
    return db.transaction<bool>((txn) async {
      final problems = await _findConservationBreak(txn);
      return problems.isEmpty;
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
    _guardWrite();
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
        // V3.11：合并数量以「位置数量之和」为准——先并关联（同位置数量相加），
        // 再 sync 重算总数，不再用旧的 items.quantity 简单相加（会与位置脱节）。
        await _mergeItemAssociations(
          txn,
          fromItemId: id,
          toItemId: conflictId,
          deletedAt: deletedAt,
          now: now,
        );
        // V3.13：随物品级联软删的借出记录也要跟着合并到存活物品名下，
        // 否则 loans.item_id 仍指向已物理删除的行 → 变成孤儿借出。
        await _reviveLoans(
          txn,
          fromItemId: id,
          toItemId: conflictId,
          deletedAt: deletedAt,
          now: now,
        );
        final total = await _syncItemTotal(txn, conflictId, now: now);
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
      // V3.13：复活随本次删除级联软删的借出记录。
      // 只认「删除时活跃」的那批——用 `updated_at == 物品 deleted_at` 精确匹配，
      // 与 item_locations 的复活口径完全一致：用户单独删过的那笔借出记录
      // （deleted_at 与本次删除不同）不该被顺带复活。
      await _reviveLoans(
        txn,
        fromItemId: id,
        toItemId: id,
        deletedAt: deletedAt,
        now: now,
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
      // V3.11：复活后逐位置数量已原样保留（quantity 列未动），
      // sync 让 items.quantity = SUM(位置数量)，保证「废弃再恢复原样还原」。
      await _syncItemTotal(txn, id, now: now);
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

      final dup = await txn.query(
        tableItemLocations,
        columns: <String>[columnId, columnLocationQuantity],
        where: '$columnItemId = ? AND $columnLocationId = ? '
            'AND $columnIsDeleted = 0',
        whereArgs: <Object?>[toItemId, locationId],
        limit: 1,
      );
      if (dup.isNotEmpty) {
        // V3.11（元宝批复第 5 条）：同名合并且撞位置——把来源位置的
        // 数量**加到**目标同位置，而不是丢弃（丢了就等于那批东西凭空消失）。
        final dupId = dup.first[columnId] as int;
        final dupQty =
            (dup.first[columnLocationQuantity] as num?)?.toInt() ?? 0;
        final srcQty = (row[columnLocationQuantity] as num?)?.toInt() ?? 0;
        await txn.update(
          tableItemLocations,
          <String, Object?>{
            columnLocationQuantity: dupQty + srcQty,
            columnUpdatedAt: now,
          },
          where: '$columnId = ?',
          whereArgs: <Object?>[dupId],
        );
        await txn.delete(
          tableItemLocations,
          where: '$columnId = ?',
          whereArgs: <Object?>[assocId],
        );
        continue;
      }

      // 废弃时关联行被软删留底；恢复（含撞名合并）必须把它们复活，
      // 否则「阳台2客厅1」废弃再恢复只剩位置空壳（元宝第 5 条）。
      final revive = true;
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

  /// V3.13：复活随物品一起被级联软删的借出记录。
  ///
  /// 为什么要复活：借出是从**位置**扣减的（阳台 3 个 → 借给王 1 个 → 阳台剩 2 个）。
  /// 整件删除时位置关联被软删，借出记录也被级联软删；此时总拥有数 = 0。
  /// 若只恢复物品、不恢复借出记录，位置数量会回到 1（在库），在借却是 0 ——
  /// 总拥有数从 3 掉到 1，**账凭空少两个**。所以两边必须一起复活。
  ///
  /// 只复活「本次删除时活跃」的那批：用 `updated_at == deletedAt` 精确匹配
  /// （级联软删时写入的同一时间戳），与 [item_locations] 的复活口径一致。
  /// 用户在别处单独删过的那笔借出记录（deleted_at 不同）不会被顺带复活。
  ///
  /// [toItemId] 与 [fromItemId] 不同 = 撞名合并场景：借出记录的 item_id 要
  /// 改指到存活的物品行，否则它会指向已物理删除的行，变成孤儿借出。
  Future<void> _reviveLoans(
    DatabaseExecutor txn, {
    required int fromItemId,
    required int toItemId,
    required int? deletedAt,
    required int now,
  }) async {
    if (!await _tableExists(txn, tableLoans)) return;
    // 老库（v3.2 时代）软删数据没有 deleted_at 锚点，无法精确匹配，
    // 只能按 item_id 全量复活——与 item_locations 的历史兜底同口径。
    final where = deletedAt == null
        ? '$columnItemId = ? AND $columnIsDeleted = 1'
        : '$columnItemId = ? AND $columnIsDeleted = 1 '
            'AND $columnUpdatedAt = ?';
    final args = deletedAt == null
        ? <Object?>[fromItemId]
        : <Object?>[fromItemId, deletedAt];
    await txn.update(
      tableLoans,
      <String, Object?>{
        columnItemId: toItemId,
        columnIsDeleted: 0,
        columnDeletedAt: null,
        columnUpdatedAt: now,
      },
      where: where,
      whereArgs: args,
    );
  }

  /// V3.6：彻底删除回收站物品（物理 DELETE，不可恢复）。
  ///
  /// 物品行与其**全部**关联行（活跃/软删历史一并）物理清除。
  /// 幂等：物品不存在时无操作。
  @override
  Future<void> purgeItem(int id) async {
    _guardWrite();
    final db = await open();
    await db.transaction<void>((txn) async {
      final rows = await txn.query(
        tableItems,
        columns: <String>[columnName],
        where: '$columnId = ? AND $columnIsDeleted = 1',
        whereArgs: <Object?>[id],
        limit: 1,
      );
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
      // V3.13：连带物理清除这件物品的借出记录。
      // 之前完全没碰 loans → 彻底删除梯子后，回收站里还挂着两笔
      //「梯子借给王/李」，而梯子已经不存在了 = 永久孤儿借出，账再也平不了。
      // 按 item_id 删（活跃与已软删都清），因为这一行物品马上就没了。
      if (await _tableExists(txn, tableLoans)) {
        await txn.delete(
          tableLoans,
          where: '$columnItemId = ?',
          whereArgs: <Object?>[id],
        );
      }
      // V3.12：彻底删除这件物品 = 它的一切痕迹都没了——
      // 同名/同 id 的部分废弃流水一并清掉（否则回收站里还留着
      // "梯子 1 个"，恢复它会凭空多出一个梯子）。
      if (rows.isNotEmpty) {
        await txn.delete(
          tableItemDiscards,
          where: '$columnItemId = ? OR $columnItemName = ?',
          whereArgs: <Object?>[id, rows.first[columnName] as String],
        );
      }
    });
  }

  /// V3.6：清空回收站（物理 DELETE 全部 is_deleted=1 物品行
  /// 及其全部关联行，不可恢复）。
  @override
  Future<void> purgeAll() async {
    _guardWrite();
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
      // V3.12（元宝批复第 6 条，方案 A）：清空回收站 = 彻底不要了，
      // 部分废弃流水一并清掉（不选灰显——级联才符合直觉）。
      await txn.delete(tableItemDiscards);
    });
  }

  /// 新增一个可选位置（trim、非空、超长校验）。同名未删除位置幂等返回原 id。
  /// V3：可选 [remark] 备注随新位置写入；命中已有位置时备注不变（幂等语义不变）。
  @override
  Future<int> addLocation(String name, {String? remark}) async {
    _guardWrite();
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
    _guardWrite();
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
    _guardWrite();
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
  /// V3.11 按位置记数量：数量写到**目标位置的关联行**上，其他位置不动。
  ///  * [quantity] 为 null = 本次不带数量：新建关联默认 1、已有关联保持原值；
  ///  * [quantity] 有值 + additive=false = **覆盖该位置数量**为 N；
  ///  * [quantity] 有值 + additive=true = **该位置 += N**。
  /// 三种情况最后都走 [_syncItemTotal] 重算 items.quantity（全局不变式）。
  @override
  Future<UpsertResult> upsertItemLocation(String itemName, int locationId,
      {String? rawText, int? quantity, bool additive = false}) async {
    _guardWrite();
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
      final linkRows = await txn.query(
        tableItemLocations,
        columns: <String>[columnId, columnLocationQuantity],
        where: '$columnItemId = ? AND $columnLocationId = ? AND $columnIsDeleted = 0',
        whereArgs: <Object?>[itemId, locationId],
        limit: 1,
      );
      final existed = linkRows.isNotEmpty;
      if (existed) {
        if (quantity != null) {
          final cur =
              (linkRows.first[columnLocationQuantity] as num?)?.toInt() ?? 0;
          final next = additive ? cur + quantity : quantity;
          if (next < 0) {
            throw ArgumentError.value(next, 'quantity', '位置数量不能为负');
          }
          await txn.update(
            tableItemLocations,
            <String, Object?>{
              columnLocationQuantity: next,
              columnUpdatedAt: now,
            },
            where: '$columnId = ?',
            whereArgs: <Object?>[linkRows.first[columnId] as int],
          );
        } else {
          await txn.update(
            tableItemLocations,
            <String, Object?>{columnUpdatedAt: now},
            where: '$columnId = ?',
            whereArgs: <Object?>[linkRows.first[columnId] as int],
          );
        }
      } else {
        // 新关联：不带数量默认 1；带数量按覆盖（新位置无旧值可加）。
        await _link(txn, itemId, locationId, now,
            rawText: rawText, quantity: quantity ?? 1);
      }
      await _syncItemTotal(txn, itemId, now: now);
      return UpsertResult(
        itemId: itemId,
        locationId: locationId,
        created: !existed,
      );
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

  /// V3.11 元宝批复第 1 条：挪位拆成两个**独立方法**，
  /// 禁止靠 `quantity` 是否为 null 分流——参数分流是 bug 温床。
  ///  * [moveItemWhole]：不带数量的「把梯子挪到客厅」——整体挪，旧位置软删，
  ///    目标位置拿走全部数量，总数不变。
  ///  * [moveItemPartial]：带数量的「把1个梯子挪到客厅」——只挪若干个，
  ///    源位置减、目标位置加，总数不变；源位不够要拦截。
  ///
  /// 两者都只处理"已记录过"的物品（不凭空造账），最后都走 [_syncItemTotal]。

  /// 整体挪（兼容旧名）：与 [moveItemWhole] 完全等价。
  /// 保留旧签名不含 quantity——元宝批复的要点就是**不再靠 quantity 分流**：
  /// 带数量的挪位一律显式走 [moveItemPartial]，这里永远只做整体挪。
  @override
  Future<MoveResult> moveItem(String itemName, int toLocationId,
      {String? rawText}) => moveItemWhole(itemName, toLocationId, rawText: rawText);

  @override
  Future<MoveResult> moveItemWhole(String itemName, int toLocationId,
      {String? rawText}) async {
    _guardWrite();
    final valid = _normalizeName(itemName, '物品名称');
    final db = await open();
    await _activeLocationRow(db, toLocationId);
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.transaction<MoveResult>((txn) async {
      // 无数量的「放/搁/塞…」既是首次录入也是整体挪：物品不存在时要建，
      // 否则「梯子放阳台」这句最基础的录入在生产上会被 _requireItemId 拒绝。
      // 部分挪才要求物品已存在（见 moveItemPartial）。
      final itemId = await _findOrCreateItem(txn, valid, now);
      final before = await _readStock(txn, itemId);
      final links = await txn.query(
        tableItemLocations,
        columns: <String>[columnId, columnLocationId],
        where: '$columnItemId = ? AND $columnIsDeleted = 0',
        whereArgs: <Object?>[itemId],
        orderBy: '$columnId ASC',
      );

      final previousLocations = <String>[];
      var targetLinked = false;
      for (final link in links) {
        final lid = link[columnLocationId] as int;
        if (lid == toLocationId) {
          targetLinked = true;
          continue;
        }
        final name = await _locationName(txn, lid);
        if (name != null) previousLocations.add(name);
        await txn.update(
          tableItemLocations,
          <String, Object?>{columnIsDeleted: 1, columnUpdatedAt: now},
          where: '$columnId = ?',
          whereArgs: <Object?>[link[columnId] as int],
        );
      }

      // 目标位置拿到全部数量（整体挪，总数守恒）。
      await _writeLocationQty(txn, itemId, toLocationId, before, now,
          rawText: rawText);
      final total = await _syncItemTotal(txn, itemId, now: now);
      return MoveResult(
        itemId: itemId,
        locationId: toLocationId,
        created: !targetLinked,
        previousLocations: previousLocations,
        quantity: total,
        quantityChanged: total != before,
      );
    });
  }

  @override
  Future<MoveResult> moveItemPartial(
    String itemName,
    int fromLocationId,
    int toLocationId, {
    required int quantity,
    String? rawText,
  }) async {
    _guardWrite();
    final valid = _normalizeName(itemName, '物品名称');
    if (quantity < 1) {
      throw ArgumentError.value(quantity, 'quantity', '挪动数量至少为 1');
    }
    final db = await open();
    await _activeLocationRow(db, fromLocationId);
    await _activeLocationRow(db, toLocationId);
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.transaction<MoveResult>((txn) async {
      final itemId = await _requireItemId(txn, valid);
      final fromQty = await _readLocationQty(txn, itemId, fromLocationId);
      // 元宝批复第 4 条：源位不足必须提示，不许静默挪走能挪的部分。
      if (fromQty < quantity) {
        final fromName = await _locationName(txn, fromLocationId) ?? '这个位置';
        throw ArgumentError.value(
          quantity,
          'quantity',
          '$fromName只有 $fromQty 个，不够挪 $quantity 个。'
          '请说个更小的数，或先补货再挪。',
        );
      }
      final before = await _readStock(txn, itemId);
      await _writeLocationQty(
          txn, itemId, fromLocationId, fromQty - quantity, now);
      final toQty = await _readLocationQty(txn, itemId, toLocationId);
      await _writeLocationQty(txn, itemId, toLocationId, toQty + quantity, now,
          rawText: rawText);
      final total = await _syncItemTotal(txn, itemId, now: now);
      final fromName = await _locationName(txn, fromLocationId) ?? '原位置';
      return MoveResult(
        itemId: itemId,
        locationId: toLocationId,
        created: toQty == 0,
        previousLocations: <String>[fromName],
        quantity: total,
        quantityChanged: total != before,
      );
    });
  }

  /// 取一条活跃位置行，不存在抛 ArgumentError。
  Future<Map<String, Object?>> _activeLocationRow(
      DatabaseExecutor db, int locationId) async {
    final rows = await db.query(
      tableLocations,
      where: '$columnId = ? AND $columnIsDeleted = 0',
      whereArgs: <Object?>[locationId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw ArgumentError.value(locationId, 'locationId', '位置不存在或已删除');
    }
    return rows.first;
  }

  /// 按 id 取位置名（活跃）；找不到返回 null。
  Future<String?> _locationName(DatabaseExecutor db, int locationId) async {
    final rows = await db.query(
      tableLocations,
      columns: <String>[columnName],
      where: '$columnId = ? AND $columnIsDeleted = 0',
      whereArgs: <Object?>[locationId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first[columnName] as String;
  }

  /// 按名取活跃物品 id；不存在抛 ArgumentError（不能凭空造账）。
  Future<int> _requireItemId(DatabaseExecutor db, String name) async {
    final rows = await db.query(
      tableItems,
      columns: <String>[columnId],
      where: '$columnName = ? AND $columnIsDeleted = 0',
      whereArgs: <Object?>[name],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw ArgumentError.value(
        name, 'itemName', '还没记录过「$name」，先说一句「$name放阳台」再操作');
    }
    return rows.first[columnId] as int;
  }

  /// V3.11：只改**总数**——用户在弹窗里明确选了「家里一共 N 个」时用。
  ///
  /// 差额落到主位置（活跃关联 id 最小者），再走 [_syncItemTotal] 保证不变式。
  /// 注意：本方法只在用户明确选择「改总数」后调用；多位置下静默改总数是
  /// 元宝批复第 3 条明令禁止的（会偷改用户没提的位置），UI 必须先弹窗。
  /// [quantity] ≥ 1；additive=true 累加、否则覆盖。物品没记录过抛 ArgumentError。
  @override
  Future<int> setItemQuantity(
    String itemName,
    int quantity, {
    bool additive = false,
  }) async {
    _guardWrite();
    final valid = _normalizeName(itemName, '物品名称');
    if (quantity < 1) {
      throw ArgumentError.value(quantity, 'quantity', '数量至少为 1');
    }
    final db = await open();
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.transaction<int>((txn) async {
      final itemId = await _requireItemId(txn, valid);
      final cur = await _readStock(txn, itemId);
      final target = additive ? cur + quantity : quantity;
      final delta = target - cur;

      // 差额落到主位置（id 最小的活跃关联）。
      final links = await txn.query(
        tableItemLocations,
        columns: <String>[columnId, columnLocationQuantity],
        where: '$columnItemId = ? AND $columnIsDeleted = 0',
        whereArgs: <Object?>[itemId],
        orderBy: '$columnId ASC',
        limit: 1,
      );
      if (links.isNotEmpty) {
        final link = links.first;
        final linkId = link[columnId] as int;
        final linkQty = (link[columnLocationQuantity] as num?)?.toInt() ?? 0;
        final nextQty = linkQty + delta;
        if (nextQty < 0) {
          throw ArgumentError.value(
            quantity, 'quantity', '主位置数量不够减，请用「校准数量」逐位置清点');
        }
        await txn.update(
          tableItemLocations,
          <String, Object?>{
            columnLocationQuantity: nextQty,
            columnUpdatedAt: now,
          },
          where: '$columnId = ?',
          whereArgs: <Object?>[linkId],
        );
      }
      return _syncItemTotal(txn, itemId, now: now);
    });
  }

  /// V3.11：只改**某个位置**的数量——用户在弹窗里选了「某个位置 N 个」时用。
  /// 不动其他位置，走 [_syncItemTotal] 保证不变式（元宝批复第 3 条的另一分支）。
  @override
  Future<int> setLocationQuantity(
    String itemName,
    int locationId,
    int quantity, {
    bool additive = false,
  }) async {
    _guardWrite();
    final valid = _normalizeName(itemName, '物品名称');
    if (quantity < 1) {
      throw ArgumentError.value(quantity, 'quantity', '数量至少为 1');
    }
    final db = await open();
    await _activeLocationRow(db, locationId);
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.transaction<int>((txn) async {
      final itemId = await _requireItemId(txn, valid);
      final cur = await _readLocationQty(txn, itemId, locationId);
      final next = additive ? cur + quantity : quantity;
      await _writeLocationQty(txn, itemId, locationId, next, now);
      return _syncItemTotal(txn, itemId, now: now);
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
      'loc.$columnUpdatedAt AS loc_updated, '
      'assoc.$columnLocationQuantity AS assoc_qty '
      'FROM $tableItemLocations AS assoc '
      'INNER JOIN $tableLocations AS loc ON assoc.$columnLocationId = loc.$columnId '
      'WHERE assoc.$columnItemId = ? AND assoc.$columnIsDeleted = 0 '
      'AND loc.$columnIsDeleted = 0 '
      'ORDER BY loc.$columnName ASC',
      <Object?>[item.id],
    );
    final locations = <Location>[];
    final locationQuantities = <int, int>{};
    for (final row in rows) {
      final id = row['loc_id'] as int;
      locations.add(Location(
        id: id,
        name: row['loc_name'] as String,
        isDeleted: (row['loc_deleted'] as int) == 1,
        createdAt: (row['loc_created'] as num).toInt(),
        updatedAt: (row['loc_updated'] as num).toInt(),
      ));
      // V3.11：多位置弹窗要显示「这里有 N 个」，必须把位置数量一起查出来。
      locationQuantities[id] = (row['assoc_qty'] as num?)?.toInt() ?? 1;
    }
    return ItemWithLocations(
      item: item,
      locations: locations,
      locationQuantities: locationQuantities,
    );
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
      'assoc.$columnLocationQuantity AS assoc_qty, '
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
    final qtyByItem = <int, Map<int, int>>{};
    final rawTextsByItem = <int, Set<String>>{};
    final tagsByItem = <int, Set<String>>{};
    for (final row in assocRows) {
      final itemId = row['assoc_item_id'] as int;
      final locId = row['loc_id'] as int;
      (qtyByItem[itemId] ??= <int, int>{})[locId] =
          (row['assoc_qty'] as num?)?.toInt() ?? 1;
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
            locationQuantities: qtyByItem[item.id] ?? const <int, int>{},
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

  /// V3.11「校准数量」工具（元宝批复第 5 条：按位置分别清点，不降级）。
  ///
  /// [locationTotals] = 物品 id → (位置 id → 用户清点的「这里有几个」)。
  ///   逐位置写数量；在借数**只展示、不重复扣减**（沿用 V3.10 定案：
  ///   逐位置清点就是家里实物、即在库数）。支持新增位置行——位置 id 是新
  ///   建的活跃关联，这里直接写入。每件最后走 [_syncItemTotal]。
  ///
  /// [totals]（旧口径兼容）= 物品 id → 清点的「一共几个」（总拥有数）；
  ///   写入在库数 = 总拥有数 − 未归还借出数，差额落到主位置后 sync。
  ///   保留给旧测试/旧调用；新 UI 走 [locationTotals]。
  ///
  /// 幂等：同样的清点值反复校准，结果不变。只处理活跃物品。
  @override
  Future<CalibrationReport> calibrateQuantities({
    Map<int, int> totals = const <int, int>{},
    Map<int, Map<int, int>> locationTotals = const <int, Map<int, int>>{},
  }) async {
    final db = await open();
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.transaction<CalibrationReport>((txn) async {
      final itemRows = await txn.query(
        tableItems,
        columns: <String>[columnId, columnName, columnQuantity],
        where: '$columnIsDeleted = 0',
      );
      final activeIds = itemRows.map((r) => r[columnId] as int).toSet();
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

      // ---- 新口径：逐位置清点 ----
      for (final entry in locationTotals.entries) {
        final id = entry.key;
        if (!activeIds.contains(id)) continue;
        final name =
            itemRows.where((r) => r[columnId] as int == id).first[columnName]
                as String;
        final before = await _readStock(txn, id);
        for (final posEntry in entry.value.entries) {
          final locId = posEntry.key;
          final qty = posEntry.value;
          if (qty < 0) {
            details.add('$name：某位置数量不能是负数，已跳过');
            continue;
          }
          final beforeQty = await _readLocationQty(txn, id, locId);
          await _writeLocationQty(txn, id, locId, qty, now);
          // V3.12（元宝批复第 7 条）：校准把某个位置的数量调少 → 自动生成
          // 一条废弃流水。否则守恒公式会断裂（活跃数减了，但"已废弃未恢复"
          // 没加，总拥有数凭空少一截）。
          if (qty < beforeQty) {
            await _insertDiscard(
              txn,
              itemId: id,
              itemName: name,
              quantity: beforeQty - qty,
              locationId: locId,
              locationName: await _locationName(txn, locId),
              now: now,
            );
            details.add('$name：${await _locationName(txn, locId) ?? '某位置'}'
                ' 清点后少 ${beforeQty - qty} 个，已记入回收站（可恢复）');
          }
        }
        final after = await _syncItemTotal(txn, id, now: now);
        await _assertConservation(txn);
        if (after != before) {
          changed++;
          details.add('$name：逐位置清点后在库 $after 个（原 $before 个）');
        }
      }

      // ---- 旧口径兼容：总拥有数 → 减在借 → 落主位置 ----
      for (final row in itemRows) {
        final id = row[columnId] as int;
        if (locationTotals.containsKey(id)) continue; // 新口径已处理这件。
        final name = row[columnName] as String;
        final curQty = (row[columnQuantity] as num?)?.toInt() ?? 1;
        final lent = lentByItem[id] ?? 0;
        final counted = totals[id];
        if (counted == null) continue;
        if (counted < lent) {
          details.add('$name：清点 $counted 个，比在借的 $lent 个还少，'
              '已跳过（请核对后重试）');
          continue;
        }
        final newQty = counted - lent;
        if (newQty != curQty) {
          final links = await txn.query(
            tableItemLocations,
            columns: <String>[columnId, columnLocationId, columnLocationQuantity],
            where: '$columnItemId = ? AND $columnIsDeleted = 0',
            whereArgs: <Object?>[id],
            orderBy: '$columnId ASC',
            limit: 1,
          );
          if (links.isNotEmpty) {
            final locId = links.first[columnLocationId] as int;
            await _writeLocationQty(txn, id, locId, newQty, now);
            // V3.12（元宝批复第 7 条）：旧口径校准把总数调少 → 同样生成
            // 废弃流水，保证守恒公式不裂。
            if (newQty < curQty) {
              await _insertDiscard(
                txn,
                itemId: id,
                itemName: name,
                quantity: curQty - newQty,
                locationId: locId,
                locationName: await _locationName(txn, locId),
                now: now,
              );
            }
            await _syncItemTotal(txn, id, now: now);
            await _assertConservation(txn);
          }
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
      // V4.0：备份带域标识——分库后一份备份就是一个域，
      // 恢复时强制校验（生活备份恢复进工作库 = 覆盖工作账，必须拦住）。
      'domain': domain.id,
      'schemaVersion': version,
      'exportedAt': DateTime.now().millisecondsSinceEpoch,
      tableItems: await db.query(tableItems, orderBy: '$columnId ASC'),
      tableLocations: await db.query(tableLocations, orderBy: '$columnId ASC'),
      tableItemLocations:
          await db.query(tableItemLocations, orderBy: '$columnId ASC'),
      tableBorrowers: await db.query(tableBorrowers, orderBy: '$columnId ASC'),
      tableLoans: await db.query(tableLoans, orderBy: '$columnId ASC'),
      // V3.12：废弃流水一并导出（否则恢复后"废掉的那几个"就找不回来了）。
      tableItemDiscards:
          await db.query(tableItemDiscards, orderBy: '$columnId ASC'),
      // V4.0：提醒与日报一并导出。
      tableReminders: await db.query(tableReminders, orderBy: '$columnId ASC'),
      tableDailyReports:
          await db.query(tableDailyReports, orderBy: '$columnId ASC'),
      // V4.1：催办状态一并导出——否则恢复后「已完成/已延期/延期 N 次/备注」全丢，
      // 日报签与日程签会回到"什么都没处理过"的状态。
      tableTodoStates:
          await db.query(tableTodoStates, orderBy: '$columnId ASC'),
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
    // V4.2.1（+34）：全系统文件误入分区恢复入口 → 明确指路，不让
    // 「备份缺少 items 数据」这种底层报错糊用户一脸。
    if (data['kind'] == 'full_system') {
      throw ArgumentError.value(
        data['kind'],
        'kind',
        '这是全系统备份（生活+工作一份文件），'
            '请在备份页用「全系统恢复」入口恢复',
      );
    }
    // V4.0：跨域误恢复必须拦住（分库后这是"覆盖另一本账"级别的事故）。
    // ① 备份带域标识且与本库不一致 → 拒绝，文案直说哪本账。
    // ② 备份无域标识（旧版备份）→ 归生活库；工作库拒绝接收。
    final backupDomainId = data['domain'] as String?;
    final backupDomain = InventoryDomain.fromId(backupDomainId);
    if (backupDomainId != null && backupDomain == null) {
      throw ArgumentError.value(
        backupDomainId,
        'domain',
        '备份文件的区域标识无法识别，可能不是本应用导出的文件',
      );
    }
    if (backupDomain != null && backupDomain != domain) {
      throw ArgumentError.value(
        backupDomainId,
        'domain',
        '这是${backupDomain.label}的备份，不能恢复到${domain.label}',
      );
    }
    if (backupDomain == null && domain != InventoryDomain.life) {
      throw ArgumentError.value(
        backupDomainId,
        'domain',
        '这是旧版备份（没有区域标识），只能恢复到${InventoryDomain.life.label}',
      );
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
    // V3.12：v9 及更早的备份没有废弃流水表 → 按空表处理（老数据本就没有
    // "部分废弃"这个概念，语义天然对齐）。
    final discardMaps = data.containsKey(tableItemDiscards)
        ? _rowsOf(data, tableItemDiscards)
        : <Map<String, Object?>>[];
    // V4.0：提醒与日报一并恢复（旧备份没有这两张表 → 按空表处理）。
    final reminderMaps = data.containsKey(tableReminders)
        ? _rowsOf(data, tableReminders)
        : <Map<String, Object?>>[];
    final reportMaps = data.containsKey(tableDailyReports)
        ? _rowsOf(data, tableDailyReports)
        : <Map<String, Object?>>[];
    // V4.1：催办状态一并恢复（v11 及更早的备份没有这张表 → 按空表处理，
    // 语义天然对齐：老版本本来就没有「催办条目状态」这个概念）。
    final todoStateMaps = data.containsKey(tableTodoStates)
        ? _rowsOf(data, tableTodoStates)
        : <Map<String, Object?>>[];

    final db = await open();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction<void>((txn) async {
      // 清空顺序：先子表后主表，避免外键/索引干扰。
      // V4.1：todo_states 表是 v12 才加的，老库（未升级）可能还不存在
      // → 操作前先守卫，不能让「no such table」打挂整个恢复流程。
      final hasTodoStates = await _tableExists(txn, tableTodoStates);
      if (hasTodoStates) {
        await txn.delete(tableTodoStates);
      }
      await txn.delete(tableDailyReports);
      await txn.delete(tableReminders);
      await txn.delete(tableItemDiscards);
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
      for (final row in discardMaps) {
        await txn.insert(tableItemDiscards, _discardMapForInsert(row));
      }
      for (final row in reminderMaps) {
        await txn.insert(tableReminders, Reminder.fromMap(row).toMap());
      }
      for (final row in reportMaps) {
        await txn.insert(tableDailyReports, DailyReport.fromMap(row).toMap());
      }
      if (hasTodoStates) {
        for (final row in todoStateMaps) {
          await txn.insert(tableTodoStates, TodoState.fromMap(row).toMap());
        }
      }
      // V3.11（元宝批复第 8 条）：恢复收口统一走 _syncItemTotal，
      // 禁止另写一套重算逻辑（两套迟早漂移）。
      //  * v9 备份：位置 quantity 原样恢复，sync 幂等（不重新分配，
      //    否则会破坏用户已分的布局，如「阳台1客厅2」被平均成「阳台2客厅1」）。
      //  * v8 及更早备份：位置无 quantity（补默认 1），需把 items.quantity
      //    按迁移同款口径分配到位置，再 sync，才不丢校准则。
      //  * V4.1.7（演练打回）：**软删行跳过 sync**——软删物品的关联也全是
      //    软删，SUM(活跃位置)=0 会把备份里保真的 quantity 抹成 0，
      //    回收站恢复后就剩 0 个。软删行的 quantity 是「删除那一刻的快照」，
      //    按备份原样落地；回收站恢复物品时另有收口重算。
      final legacy = backupVersion < 9;
      final restoredItems = await txn.query(
        tableItems,
        columns: <String>[columnId, columnQuantity, columnIsDeleted],
      );
      for (final row in restoredItems) {
        if ((row[columnIsDeleted] as num?)?.toInt() == 1) continue;
        final itemId = row[columnId] as int;
        if (legacy) {
          final total = (row[columnQuantity] as num?)?.toInt() ?? 1;
          await _distributeTotalToLocations(txn, itemId, total, now);
        }
        await _syncItemTotal(txn, itemId, now: now);
      }
    });
  }

  /// 把物品总数按「平均分配 + 余数给主位置」分配到各活跃位置（允许 0）。
  /// v9 迁移与 v8 备份恢复收口共用同一口径，避免两套逻辑漂移。
  Future<void> _distributeTotalToLocations(
    DatabaseExecutor txn,
    int itemId,
    int total,
    int now,
  ) async {
    final links = await txn.query(
      tableItemLocations,
      columns: <String>[columnId],
      where: '$columnItemId = ? AND $columnIsDeleted = 0',
      whereArgs: <Object?>[itemId],
      orderBy: '$columnId ASC',
    );
    if (links.isEmpty) return;
    final n = links.length;
    final base = total ~/ n;
    final remainder = total % n;
    for (var i = 0; i < links.length; i++) {
      final qty = base + (i == 0 ? remainder : 0);
      await txn.update(
        tableItemLocations,
        <String, Object?>{
          columnLocationQuantity: qty,
          columnUpdatedAt: now,
        },
        where: '$columnId = ?',
        whereArgs: <Object?>[links[i][columnId] as int],
      );
    }
  }

  /// V3.12：备份里的废弃流水行 → 可插入的 map（缺列补默认值）。
  Map<String, Object?> _discardMapForInsert(Map<String, Object?> row) {
    return <String, Object?>{
      columnItemId: (row[columnItemId] as num?)?.toInt() ?? 0,
      columnItemName: row[columnItemName] as String? ?? '',
      columnDiscardQuantity: (row[columnDiscardQuantity] as num?)?.toInt() ?? 0,
      columnDiscardLocationId: (row[columnDiscardLocationId] as num?)?.toInt(),
      columnDiscardLocationName: row[columnDiscardLocationName] as String?,
      columnDiscardedAt: (row[columnDiscardedAt] as num?)?.toInt() ?? 0,
      columnSourceType: row[columnSourceType] as String? ?? 'in_stock',
      columnRestoredQuantity:
          (row[columnRestoredQuantity] as num?)?.toInt() ?? 0,
    };
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
    int? fromLocationId,
  }) async {
    _guardWrite();
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
      // V3.11 按位置记数量：从指定位置扣（UI 多位置时弹窗问），
      // 未指定则从主位置（活跃关联 id 最小）扣，源位不够要提示。
      final links = await txn.query(
        tableItemLocations,
        columns: <String>[columnId, columnLocationId, columnLocationQuantity],
        where: '$columnItemId = ? AND $columnIsDeleted = 0',
        whereArgs: <Object?>[itemId],
        orderBy: '$columnId ASC',
      );
      if (links.isEmpty) {
        throw ArgumentError.value(
          storeItem, 'itemName', '「$storeItem」还没登记放在哪儿，先说一句放哪再借');
      }
      final sourceLink = fromLocationId == null
          ? links.first
          : links.firstWhere(
              (l) => l[columnLocationId] as int == fromLocationId,
              orElse: () => links.first,
            );
      final sourceId = sourceLink[columnLocationId] as int;
      final sourceQty =
          (sourceLink[columnLocationQuantity] as num?)?.toInt() ?? 0;
      if (sourceQty < quantity) {
        final sourceName = await _locationName(txn, sourceId) ?? '这个位置';
        throw ArgumentError.value(
          quantity,
          'quantity',
          '$sourceName只有 $sourceQty 个「$storeItem」，不够借 $quantity 个。'
          '换个位置借，或先补货。',
        );
      }
      await _writeLocationQty(
          txn, itemId, sourceId, sourceQty - quantity, now);
      await _syncItemTotal(txn, itemId, now: now);
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
  Future<void> returnLoan(int loanId,
      {int? quantity, int? toLocationId}) async {
    _guardWrite();
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
        final itemId = itemRows.first[columnId] as int;
        // V3.11：归还加到指定位置（UI 弹窗问），未指定则加到主位置。
        // 目标位置可能已被删除（物品进回收站/位置不存在）——此时无处加，
        // 只更新 loans 即可，不报错（V3.9.2 口径）。
        final links = await txn.query(
          tableItemLocations,
          columns: <String>[columnId, columnLocationId],
          where: '$columnItemId = ? AND $columnIsDeleted = 0',
          whereArgs: <Object?>[itemId],
          orderBy: '$columnId ASC',
        );
        int targetId;
        if (toLocationId != null &&
            links.any((l) => l[columnLocationId] as int == toLocationId)) {
          targetId = toLocationId;
        } else if (links.isNotEmpty) {
          targetId = links.first[columnLocationId] as int;
        } else {
          return; // 无活跃关联，无处加回。
        }
        final curQty = await _readLocationQty(txn, itemId, targetId);
        await _writeLocationQty(txn, itemId, targetId, curQty + amount, now);
        await _syncItemTotal(txn, itemId, now: now);
      }
    });
  }

  /// 单笔改借期（天数从借出时刻起算，UTC）。
  @override
  Future<void> updateLoanDue(int loanId, int days) async {
    _guardWrite();
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
    _guardWrite();
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
    _guardWrite();
    final db = await open();
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final rows = await db.query(
      tableLoans,
      columns: <String>[columnId, columnItemId, columnItemName],
      where: '$columnId = ? AND $columnIsDeleted = 1',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw ArgumentError.value(id, 'id', '没有已删除的借出记录');
    }
    // V3.13：借出记录挂在物品上——**物品必须已恢复（存活）才能恢复这笔借出**。
    // 否则会造出孤儿借出：物品还在回收站里，这笔借出却活了，
    // 借出管理页显示「梯子借出中」而梯子根本不在明细里。
    // （同一个坑换了个入口重现——整件删除时级联软删借出记录，
    //   PM 却在回收站里单独点「恢复」这一笔。）
    final itemId = rows.first[columnItemId] as int;
    final itemRows = await db.query(
      tableItems,
      columns: <String>[columnName, columnIsDeleted],
      where: '$columnId = ?',
      whereArgs: <Object?>[itemId],
      limit: 1,
    );
    if (itemRows.isEmpty) {
      throw ArgumentError.value(
        id,
        'id',
        '「${rows.first[columnItemName]}」这件物品已经不在了，'
            '没法恢复它的借出记录',
      );
    }
    if ((itemRows.first[columnIsDeleted] as num?)?.toInt() == 1) {
      throw ArgumentError.value(
        id,
        'id',
        '「${rows.first[columnItemName]}」还在回收站里，'
            '先把这件物品恢复出来，再恢复它的借出记录',
      );
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
    _guardWrite();
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
    _guardWrite();
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

  // ---------- V4.0 日程 / 日报 ----------

  @override
  Future<List<Reminder>> getReminders({bool includeDone = true}) async {
    final db = await open();
    final rows = await db.query(
      tableReminders,
      where: includeDone
          ? '$columnIsDeleted = 0'
          : '$columnIsDeleted = 0 AND $columnStatus = ?',
      whereArgs: includeDone ? null : <Object?>[reminderStatusPending],
      orderBy: 'COALESCE($columnReminderDueAt, 9223372036854775807) ASC, '
          '$columnId ASC',
    );
    return rows.map(Reminder.fromMap).toList();
  }

  @override
  Future<int> addReminder(String title,
      {String? detail,
      DateTime? dueAt,
      String? repeatRule,
      int priority = ReminderPriority.normal}) async {
    _guardWrite();
    final clean = title.trim();
    if (clean.isEmpty) {
      throw ArgumentError.value(title, 'title', '提醒标题不能为空');
    }
    if (clean.length > maxNameLength) {
      throw ArgumentError.value(
          title, 'title', '提醒标题不能超过 $maxNameLength 个字符');
    }
    final db = await open();
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.insert(tableReminders, <String, Object?>{
      columnTitle: clean,
      if (detail != null) columnDetail: detail,
      if (dueAt != null) columnReminderDueAt: dueAt.millisecondsSinceEpoch,
      columnStatus: reminderStatusPending,
      if (repeatRule != null) columnRepeatRule: repeatRule,
      // V4.1 批次 2（元宝裁定①）：优先级，越界归为中。
      columnPriority: ReminderPriority.normalize(priority),
      columnIsDeleted: 0,
      columnCreatedAt: now,
      columnUpdatedAt: now,
    });
  }

  @override
  Future<void> updateReminder(int id,
      {String? title, String? detail, DateTime? dueAt, int? priority}) async {
    _guardWrite();
    final values = <String, Object?>{};
    if (title != null) {
      final clean = title.trim();
      if (clean.isEmpty) {
        throw ArgumentError.value(title, 'title', '提醒标题不能为空');
      }
      values[columnTitle] = clean;
    }
    if (detail != null) values[columnDetail] = detail;
    if (dueAt != null) values[columnReminderDueAt] = dueAt.millisecondsSinceEpoch;
    // V4.1 批次 2（元宝裁定①）：日程签编辑时可改优先级。
    if (priority != null) {
      values[columnPriority] = ReminderPriority.normalize(priority);
    }
    if (values.isEmpty) return;
    values[columnUpdatedAt] = DateTime.now().millisecondsSinceEpoch;
    final db = await open();
    await db.update(
      tableReminders,
      values,
      where: '$columnId = ? AND $columnIsDeleted = 0',
      whereArgs: <Object?>[id],
    );
  }

  @override
  Future<void> setReminderDone(int id, {bool done = true}) async {
    _guardWrite();
    final db = await open();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      tableReminders,
      <String, Object?>{
        columnStatus: done ? reminderStatusDone : reminderStatusPending,
        columnDoneAt: done ? now : null,
        columnUpdatedAt: now,
      },
      where: '$columnId = ? AND $columnIsDeleted = 0',
      whereArgs: <Object?>[id],
    );
    // V4.1 批次 4（元宝裁定② · 甲方案）：这里也展开下一实例。
    //
    // 理由：「完成一条带重复规则的日程 → 产生下一期」是**数据层不变量**，
    // 不能取决于调用方走的是哪个入口（`markDone` 走 `todo_states`，
    // `setReminderDone` 走 `reminders.status`）。
    // 两条路径都展开，展开逻辑只有一份（幂等查重保证不会建出两条）。
    if (done) {
      await _expandRepeatingReminder(db, id);
    }
  }

  @override
  Future<void> deleteReminder(int id) async {
    _guardWrite();
    final db = await open();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      tableReminders,
      <String, Object?>{
        columnIsDeleted: 1,
        columnDeletedAt: now,
        columnUpdatedAt: now,
      },
      where: '$columnId = ? AND $columnIsDeleted = 0',
      whereArgs: <Object?>[id],
    );
  }

  // ─────────── V4.1.3：提醒回收站（不新增列/表，schema 仍 v13） ───────────

  @override
  Future<List<Reminder>> getDeletedReminders() async {
    final db = await open();
    final rows = await db.query(
      tableReminders,
      where: '$columnIsDeleted = 1',
      orderBy: '$columnDeletedAt DESC, $columnId DESC',
    );
    return rows.map(Reminder.fromMap).toList();
  }

  @override
  Future<void> restoreReminder(int id) async {
    _guardWrite();
    final db = await open();
    await db.update(
      tableReminders,
      <String, Object?>{
        columnIsDeleted: 0,
        columnDeletedAt: null,
        columnUpdatedAt: DateTime.now().millisecondsSinceEpoch,
      },
      where: '$columnId = ? AND $columnIsDeleted = 1',
      whereArgs: <Object?>[id],
    );
  }

  @override
  Future<void> purgeReminder(int id) async {
    _guardWrite();
    final db = await open();
    // 硬删 = 痕迹全无：提醒行 + 它对应的 todo_states 一起物理清掉，
    // 否则日程硬删后状态行变永久孤儿（项目守恒铁律）。
    await db.transaction((txn) async {
      await txn.delete(
        tableTodoStates,
        where: '$columnSourceType = ? AND $columnSourceId = ?',
        whereArgs: <Object?>[TodoSourceType.scheduleReminder, id],
      );
      await txn.delete(
        tableReminders,
        where: '$columnId = ?',
        whereArgs: <Object?>[id],
      );
    });
  }

  // ─────────────────── V4.1 批次 3：ReminderEditor 实现 ───────────────────
  //
  // 只写 `reminders` 表（提醒条目本身），**不碰** items / loans / locations。
  // 概览页拿到这个写口，改不了仓储账——「概览改不了账」依然成立。

  @override
  Future<int> createReminder(String title,
      {String? detail,
      DateTime? dueAt,
      String? repeatRule,
      int priority = ReminderPriority.normal}) =>
      addReminder(title,
          detail: detail,
          dueAt: dueAt,
          repeatRule: repeatRule,
          priority: priority);

  @override
  Future<void> editReminder(int id,
      {String? title,
      String? detail,
      DateTime? dueAt,
      String? repeatRule,
      bool clearRepeatRule = false,
      int? priority}) async {
    _guardWrite();
    final values = <String, Object?>{};
    if (title != null) {
      final clean = title.trim();
      if (clean.isEmpty) {
        throw ArgumentError.value(title, 'title', '提醒标题不能为空');
      }
      values[columnTitle] = clean;
    }
    if (detail != null) values[columnDetail] = detail;
    if (dueAt != null) values[columnReminderDueAt] = dueAt.millisecondsSinceEpoch;
    if (repeatRule != null) values[columnRepeatRule] = repeatRule;
    // 显式清空重复规则——`updateReminder` 做不到（那里 null = 不改）。
    if (clearRepeatRule) values[columnRepeatRule] = null;
    if (priority != null) {
      values[columnPriority] = ReminderPriority.normalize(priority);
    }
    if (values.isEmpty) return;
    values[columnUpdatedAt] = DateTime.now().millisecondsSinceEpoch;
    final db = await open();
    await db.update(
      tableReminders,
      values,
      where: '$columnId = ? AND $columnIsDeleted = 0',
      whereArgs: <Object?>[id],
    );
  }

  @override
  Future<void> removeReminder(int id) => deleteReminder(id);

  @override
  Future<DailyReport?> getDailyReport(String reportDate) async {    final db = await open();
    final rows = await db.query(
      tableDailyReports,
      where: '$columnReportDate = ?',
      whereArgs: <Object?>[reportDate],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return DailyReport.fromMap(rows.first);
  }

  @override
  Future<List<DailyReport>> getDailyReports({int limit = 30}) async {
    final db = await open();
    final rows = await db.query(
      tableDailyReports,
      orderBy: '$columnReportDate DESC',
      limit: limit,
    );
    return rows.map(DailyReport.fromMap).toList();
  }

  @override
  Future<void> saveDailyReport(String reportDate, String contentMd,
      {String? sourceSnapshot}) async {
    _guardWrite();
    final db = await open();
    final now = DateTime.now().millisecondsSinceEpoch;
    // 一日一条：先删同日的旧行再插，避免主键冲突（唯一索引兜底）。
    await db.delete(
      tableDailyReports,
      where: '$columnReportDate = ?',
      whereArgs: <Object?>[reportDate],
    );
    await db.insert(tableDailyReports, <String, Object?>{
      columnReportDate: reportDate,
      columnContentMd: contentMd,
      columnGeneratedAt: now,
      if (sourceSnapshot != null) columnSourceSnapshot: sourceSnapshot,
    });
  }

  // ─────────────────────────────────────────────────────────────
  // V4.1：TodoStateWriter 实现（只写待办条目状态，不碰任何账目）
  // ─────────────────────────────────────────────────────────────

  /// 自然日对齐：把毫秒时间戳折算到当天 00:00。
  ///
  /// 「过期」判定必须按**日期**比，不能按时刻比——
  /// 若按时刻比，「今天 10:00 到期」在今天 20:00 就会被判为过期，
  /// 而元宝 B4 的语义是「**到期当天**未处理才自动延期」，
  /// 当天没过期就不该推进。
  static int _dateOnly(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
  }

  /// 取催办源条目的原始到期时间；源条目不存在 / 已删 / 已还清 → null。
  Future<int?> _sourceDueAt(
      DatabaseExecutor db, String sourceType, int sourceId) async {
    if (sourceType == TodoSourceType.scheduleReminder) {
      final rows = await db.query(
        tableReminders,
        columns: <String>[columnReminderDueAt],
        where: '$columnId = ? AND $columnIsDeleted = 0',
        whereArgs: <Object?>[sourceId],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return (rows.first[columnReminderDueAt] as num?)?.toInt();
    }
    if (sourceType == TodoSourceType.loanDue) {
      final rows = await db.query(
        tableLoans,
        columns: <String>[columnDueAt],
        where: '$columnId = ? AND $columnIsDeleted = 0 '
            'AND $columnReturnedQty < $columnQuantity',
        whereArgs: <Object?>[sourceId],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return (rows.first[columnDueAt] as num?)?.toInt();
    }
    return null;
  }

  /// 读某条催办条目的状态行（null = 还没有状态记录）。
  Future<Map<String, Object?>?> _readTodoStateRow(DatabaseExecutor db,
      String sourceType, int sourceId) async {
    final rows = await db.query(
      tableTodoStates,
      where: '$columnSourceType = ? AND $columnSourceId = ?',
      whereArgs: <Object?>[sourceType, sourceId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first;
  }

  @override
  Future<TodoState?> readState(String sourceType, int sourceId) async {
    final db = await open();
    final row = await _readTodoStateRow(db, sourceType, sourceId);
    if (row == null) return null;
    return TodoState.fromMap(row);
  }

  @override
  Future<List<TodoState>> loadStates() async {
    final db = await open();
    final rows = await db.query(tableTodoStates, orderBy: '$columnId ASC');
    return rows.map(TodoState.fromMap).toList();
  }

  @override
  Future<void> markDone(String sourceType, int sourceId,
      {bool done = true}) async {
    _guardWrite();
    final db = await open();
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = await _readTodoStateRow(db, sourceType, sourceId);
    if (existing == null) {
      await db.insert(tableTodoStates, <String, Object?>{
        columnSourceType: sourceType,
        columnSourceId: sourceId,
        columnStatus: done ? TodoStatus.done : TodoStatus.pending,
        columnDoneAt: done ? now : null,
        columnDeferCount: 0,
        columnCreatedAt: now,
        columnUpdatedAt: now,
      });
    } else {
      // 撤销时清 done_at，但**保留** defer_count 与 handle_note——
      // 那两条是历史，不是完成态。
      await db.update(
        tableTodoStates,
        <String, Object?>{
          columnStatus: done ? TodoStatus.done : TodoStatus.pending,
          columnDoneAt: done ? now : null,
          columnUpdatedAt: now,
        },
        where: '$columnId = ?',
        whereArgs: <Object?>[existing[columnId]],
      );
    }
    // V4.1 批次 4（元宝裁定② · **甲方案**：完成后自动新建下一实例，保留历史）。
    //
    // 只在「**完成**日程类条目」时展开；撤销完成**不回收**下一实例
    // （排期不回滚——用户已经看到过这一期）。
    if (done && sourceType == TodoSourceType.scheduleReminder) {
      await _expandRepeatingReminder(db, sourceId);
    }
  }

  @override
  Future<void> setTodoStatus(
      String sourceType, int sourceId, String status) async {
    // 只认三态；非法值（含 deferred）直接忽略——deferred 只走系统延期路径。
    if (!TodoStatus.toggleCycle.contains(status)) return;
    // 完成态委托 markDone：重复规则展开逻辑唯一实现，两签同源。
    if (status == TodoStatus.done) {
      await markDone(sourceType, sourceId, done: true);
      return;
    }
    // 非完成态（pending / in_progress）：写状态 + 清 done_at，
    // 保留 defer_count / handle_note / next_due_at（那是历史）。
    _guardWrite();
    final db = await open();
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = await _readTodoStateRow(db, sourceType, sourceId);
    if (existing == null) {
      await db.insert(tableTodoStates, <String, Object?>{
        columnSourceType: sourceType,
        columnSourceId: sourceId,
        columnStatus: status,
        columnDoneAt: null,
        columnDeferCount: 0,
        columnCreatedAt: now,
        columnUpdatedAt: now,
      });
    } else {
      await db.update(
        tableTodoStates,
        <String, Object?>{
          columnStatus: status,
          columnDoneAt: null,
          columnUpdatedAt: now,
        },
        where: '$columnId = ?',
        whereArgs: <Object?>[existing[columnId]],
      );
    }
  }

  /// V4.1 批次 4（元宝裁定② · 甲方案）：完成一条带重复规则的日程后，
  /// 自动新建**下一实例**；旧实例**保留为历史**（日报看得到「今天做完了什么」）。
  ///
  /// ## 为什么挂在数据层而不是 UI 层
  ///
  /// 概览的「日报签」与「日程签」两处勾选**都走 `TodoStateWriter.markDone`**
  /// ——展开逻辑挂在数据层，两签天然同源；挂 UI 层要改两处、必然漂移
  /// （违反元宝「口径唯一实现」铁律）。
  ///
  /// ## 幂等
  ///
  /// 同一条提醒重复完成、或「完成 → 撤销 → 再完成」，都**只建一次**下一实例——
  /// 靠「同标题 + 同周期 + 同到期日 + 未软删 + 待办」查重。
  ///
  /// ## 写边界
  ///
  /// **只写 `reminders` 表**（日程系统自己的表），
  /// 仓储账（items / loans / locations）**一个字不动**——
  /// 「概览改不了账」这条地基不受影响。
  Future<void> _expandRepeatingReminder(Database db, int reminderId) async {
    final rows = await db.query(
      tableReminders,
      where: '$columnId = ? AND $columnIsDeleted = 0',
      whereArgs: <Object?>[reminderId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final source = Reminder.fromMap(rows.first);
    final rule = RepeatRule.normalize(source.repeatRule);
    // 不重复 = 没有下一期。
    if (rule == null) return;
    // 无期限提醒没有「下一期」的基准。
    final dueAt = source.dueAt;
    if (dueAt == null) return;
    final next = RepeatRule.advance(
        DateTime.fromMillisecondsSinceEpoch(dueAt), rule);
    if (next == null) return;
    final nextDueAt = next.millisecondsSinceEpoch;
    // 幂等查重：同标题 + 同周期 + 同到期日 + 未软删 → 已有就不重复建。
    //
    // **不查 `status`**：完成态的权威源是 `todo_states`，
    // `reminders.status` 这一列目前不由勾选流程维护（勾选写 todo_states），
    // 拿它当查重条件会漏判。
    final dup = await db.query(
      tableReminders,
      where: '$columnTitle = ? AND $columnRepeatRule = ? AND '
          '$columnReminderDueAt = ? AND $columnIsDeleted = 0',
      whereArgs: <Object?>[
        source.title,
        rule,
        nextDueAt,
      ],
      limit: 1,
    );
    if (dup.isNotEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert(tableReminders, <String, Object?>{
      columnTitle: source.title,
      if (source.detail != null) columnDetail: source.detail,
      columnReminderDueAt: nextDueAt,
      columnStatus: reminderStatusPending,
      columnRepeatRule: rule,
      // 优先级 / 重复规则 / 标题 / 备注全部继承——下一期是同一件事。
      columnPriority: source.priority,
      columnIsDeleted: 0,
      columnCreatedAt: now,
      columnUpdatedAt: now,
    });
  }

  @override
  Future<void> defer(String sourceType, int sourceId,
      {String? reason, int days = 1, DateTime? dueOn}) async {
    _guardWrite();
    final db = await open();
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = await _readTodoStateRow(db, sourceType, sourceId);
    // 两种口径（元宝裁定③）：
    // - dueOn 给了 → **绝对日期**，直接写 next_due_at（延到明天 / 具体日期）。
    // - 没给 → **相对推进**：从现有 next_due_at（没有就从源条目原到期日）往后推 N 天。
    final int newNext;
    if (dueOn != null) {
      // V4.1 批次 3（元宝裁定④修订）：**只往后推，不许回拉**。
      //
      // 判据 = 「当前下一次提示时间」：
      // - 已有 next_due_at → 以它为基准；
      // - 没有 → 回落到源条目的原到期日（这是它现在的到期日）；
      // - 都没有（无期限提醒）→ 以「现在」为基准。
      //
      // 选了**早于**基准的日子 → **忽略这次延期**并报错提示，
      // 状态行一个字不动（连 defer_count 都不加——这次延期没发生）。
      //
      // 为什么校验放数据层而不是只放 UI：UI 只是入口，
      // 数据层才是**唯一能保证这条规矩成立的地方**。
      // 只在 UI 拦的话，任何绕过 UI 的调用都能把提示时间往回拉。
      final anchor = (existing?[columnNextDueAt] as num?)?.toInt() ??
          await _sourceDueAt(db, sourceType, sourceId) ??
          now;
      if (dueOn.millisecondsSinceEpoch < anchor) {
        throw ArgumentError.value(
          dueOn,
          'dueOn',
          '延期只能往后推，不能早于当前提示日期',
        );
      }
      newNext = dueOn.millisecondsSinceEpoch;
    } else {
      final anchor = (existing?[columnNextDueAt] as num?)?.toInt() ??
          await _sourceDueAt(db, sourceType, sourceId) ??
          now;
      newNext = DateTime.fromMillisecondsSinceEpoch(anchor)
          .add(Duration(days: days))
          .millisecondsSinceEpoch;
    }
    final count = ((existing?[columnDeferCount] as num?)?.toInt() ?? 0) + 1;
    if (existing == null) {
      await db.insert(tableTodoStates, <String, Object?>{
        columnSourceType: sourceType,
        columnSourceId: sourceId,
        columnStatus: TodoStatus.deferred,
        columnDeferCount: count,
        columnHandleNote: reason,
        columnNextDueAt: newNext,
        columnCreatedAt: now,
        columnUpdatedAt: now,
      });
      return;
    }
    await db.update(
      tableTodoStates,
      <String, Object?>{
        columnStatus: TodoStatus.deferred,
        columnDeferCount: count,
        if (reason != null) columnHandleNote: reason,
        columnNextDueAt: newNext,
        columnUpdatedAt: now,
      },
      where: '$columnId = ?',
      whereArgs: <Object?>[existing[columnId]],
    );
  }

  @override
  Future<void> setNote(String sourceType, int sourceId, String note) async {
    _guardWrite();
    final db = await open();
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = await _readTodoStateRow(db, sourceType, sourceId);
    if (existing == null) {
      await db.insert(tableTodoStates, <String, Object?>{
        columnSourceType: sourceType,
        columnSourceId: sourceId,
        columnStatus: TodoStatus.pending,
        columnDeferCount: 0,
        columnHandleNote: note,
        columnCreatedAt: now,
        columnUpdatedAt: now,
      });
      return;
    }
    await db.update(
      tableTodoStates,
      <String, Object?>{
        columnHandleNote: note,
        columnUpdatedAt: now,
      },
      where: '$columnId = ?',
      whereArgs: <Object?>[existing[columnId]],
    );
  }

  @override
  Future<int> syncOverdue(DateTime now) async {
    _guardWrite();
    final db = await open();
    final nowMs = now.millisecondsSinceEpoch;
    final todayMs = _dateOnly(nowMs);
    final tomorrowMs = todayMs + const Duration(days: 1).inMilliseconds;
    // 只处理「未完成」的条目：done 的不再提醒；deferred 的还要继续自动推进
    // （否则「到期当天再次提示」就断了）。
    final rows = await db.query(
      tableTodoStates,
      where: '$columnStatus != ?',
      whereArgs: <Object?>[TodoStatus.done],
    );
    var moved = 0;
    for (final row in rows) {
      final sourceType = row[columnSourceType] as String? ?? '';
      final sourceId = (row[columnSourceId] as num?)?.toInt() ?? 0;
      final nextDue = (row[columnNextDueAt] as num?)?.toInt();
      final baseDue = nextDue ?? await _sourceDueAt(db, sourceType, sourceId);
      if (baseDue == null) continue; // 源条目已不存在 / 已还清 / 已删
      // 过期判定按**日期**：到期日严格早于今天才算「到期当天未处理」。
      if (_dateOnly(baseDue) >= todayMs) continue;
      // 推进到 max(原到期 + 1 天, 明天) → **每天最多自动 +1 次**。
      final pushed = DateTime.fromMillisecondsSinceEpoch(baseDue)
          .add(const Duration(days: 1))
          .millisecondsSinceEpoch;
      final newNext = pushed < tomorrowMs ? tomorrowMs : pushed;
      await db.update(
        tableTodoStates,
        <String, Object?>{
          columnStatus: TodoStatus.deferred,
          columnDeferCount:
              ((row[columnDeferCount] as num?)?.toInt() ?? 0) + 1,
          columnNextDueAt: newNext,
          columnUpdatedAt: nowMs,
        },
        where: '$columnId = ?',
        whereArgs: <Object?>[row[columnId]],
      );
      moved++;
    }
    return moved;
  }
}

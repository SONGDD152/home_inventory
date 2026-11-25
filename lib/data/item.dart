/// [InventoryDatabase.upsertItemLocation] 的结果。
class UpsertResult {
  const UpsertResult({
    required this.itemId,
    required this.locationId,
    required this.created,
  });

  final int itemId;
  final int locationId;

  /// true 表示新建了关联；false 表示命中已有，只刷新了时间戳。
  final bool created;
}

/// [InventoryDatabase.moveItem]（挪位语义）的结果。
///
/// V3.2 起，UI 主链路的「<物品>放<位置>」即挪位：物品此前所在的
/// 其他位置关联被软删（历史留底），只保留新位置。
class MoveResult {
  const MoveResult({
    required this.itemId,
    required this.locationId,
    required this.created,
    required this.previousLocations,
    this.quantity = 1,
    this.quantityChanged = false,
  });

  final int itemId;
  final int locationId;

  /// true 表示物品与目标位置的关联是新建立的；
  /// false 表示物品原本就在目标位置。
  final bool created;

  /// 挪位前物品所在的其他位置名（不含目标位置本身，已软删）。
  /// 空列表表示物品此前没有其他位置（等价于首次记录）。
  final List<String> previousLocations;

  /// V3.10：本条指令生效后的在库数量（覆盖或累加之后）。
  final int quantity;

  /// V3.10：本次是否真的改动了数量（false=未带数量或值未变）。
  final bool quantityChanged;
}

/// 物品记录（三张表结构）。
///
/// 物品与位置是多对多关系：一件物品可以放在多个位置，一个位置可以放多件物品。
/// 关联由 [ItemLocation] 表达，本类只描述物品本身。
///
/// V3.6：新增 [deletedAt]（软删进回收站的时间戳，可空）。已删物品 isDeleted=true
/// 且 deletedAt 非空；正常物品两者均为"未删"。历史数据（v5 旧库）deleted_at 为
/// NULL，[fromMap] 按 null 读取兼容。
/// V3.7：新增 [quantity]（物品数量，默认 1）。旧备份/旧库无此字段时按 1 读取，
/// 保证 V3.6 及以前导出的 .json 能恢复到新版（元宝迁移兼容硬约束）。
class Item {
  const Item({
    this.id,
    required this.name,
    this.isDeleted = false,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
    this.quantity = 1,
  });

  final int? id;
  final String name;
  final bool isDeleted;
  final int createdAt;
  final int updatedAt;

  /// 软删（进回收站）时间戳；正常物品/历史软删行为 null。
  final int? deletedAt;

  /// 物品数量（V3.7，借出/部分归还的数量基础）。默认 1，最少 1。
  final int quantity;

  /// [includeQuantity] 默认 true；旧库迁移中途（quantity 列尚未 ALTER 时）
  /// 传 false 省略该列，避免 "no column named quantity"。
  Map<String, Object?> toMap({bool includeQuantity = true}) =>
      <String, Object?>{
        if (id != null) 'id': id,
        'name': name,
        'is_deleted': isDeleted ? 1 : 0,
        'created_at': createdAt,
        'updated_at': updatedAt,
        // null 时省略列：兼容尚未 ALTER 加列的 v5 旧库直接插入。
        if (deletedAt != null) 'deleted_at': deletedAt,
        if (includeQuantity) 'quantity': quantity,
      };

  factory Item.fromMap(Map<String, Object?> map) => Item(
        id: map['id'] as int?,
        name: map['name'] as String,
        isDeleted: (map['is_deleted'] as int?) == 1,
        createdAt: (map['created_at'] as num).toInt(),
        updatedAt: (map['updated_at'] as num).toInt(),
        deletedAt: (map['deleted_at'] as num?)?.toInt(),
        // 旧备份无 quantity 列 → 补 1（元宝迁移兼容硬约束）。
        quantity: (map['quantity'] as num?)?.toInt() ?? 1,
      );
}

/// 借阅人（V3.7，元宝决策②A：独立 borrowers 表 + 软删）。
///
/// loans 表冗余存 borrower_name 快照，软删借阅人后历史借出记录仍显示当时名字。
class Borrower {
  const Borrower({
    this.id,
    required this.name,
    this.isDeleted = false,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });

  final int? id;
  final String name;
  final bool isDeleted;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'name': name,
        'is_deleted': isDeleted ? 1 : 0,
        'created_at': createdAt,
        'updated_at': updatedAt,
        if (deletedAt != null) 'deleted_at': deletedAt,
      };

  factory Borrower.fromMap(Map<String, Object?> map) => Borrower(
        id: map['id'] as int?,
        name: map['name'] as String,
        isDeleted: (map['is_deleted'] as int?) == 1,
        createdAt: (map['created_at'] as num).toInt(),
        updatedAt: (map['updated_at'] as num).toInt(),
        deletedAt: (map['deleted_at'] as num?)?.toInt(),
      );
}

/// 借出记录（V3.7，元宝决策①A/②A）。
///
/// 一条 loan = 一次借出。部分归还采用「原记录 returnedQty 累加 + isPartial=true」，
/// 与元宝闭环简报"标 is_partial + 剩余数量"口径等价，且正好对应导出列头
/// 「借出数量/已还数量」的 quantity/returnedQty 两列，不额外拆行。
/// [dueAt] 用 UTC 毫秒存、本地显示（与现有时间戳口径一致）。
/// 状态由 returnedQty 与 quantity 推导：已归还=全部归还；逾期=未还清且 dueAt < now。
///
/// V3.8：新增 [isDeleted] / [deletedAt]（借出记录软删，进回收站，可恢复）。
/// 旧备份/旧库无这两列时 [fromMap] 按未删读取，V3.7 及以前导出的备份可正常恢复。
class Loan {
  const Loan({
    this.id,
    required this.itemId,
    this.updatedAt,
    required this.itemName,
    required this.borrowerName,
    required this.quantity,
    this.returnedQty = 0,
    required this.borrowedAt,
    required this.dueAt,
    this.returnedAt,
    this.isPartial = false,
    this.isDeleted = false,
    this.deletedAt,
  });

  final int? id;
  final int itemId;

  /// 最近变更时间（UTC 毫秒）；构造新记录时可为 null，落库时写入。
  final int? updatedAt;

  /// 物品名快照（借出时的名字，改名后历史仍可读）。
  final String itemName;

  /// 借阅人名字快照（软删借阅人后历史仍可读）。
  final String borrowerName;

  /// 借出数量。
  final int quantity;

  /// 已归还数量（0..quantity）。
  final int returnedQty;

  /// 借出时间（UTC 毫秒）。
  final int borrowedAt;

  /// 到期时间（UTC 毫秒，默认借出日 +3 天，单笔可改）。
  final int dueAt;

  /// 全部归还时间（null 表示尚未还清）。
  final int? returnedAt;

  /// 是否发生过部分归还（只要归还过一部分且未一次还清即 true）。
  final bool isPartial;

  /// V3.8：是否已软删（进回收站）。正常借出记录为 false。
  final bool isDeleted;

  /// V3.8：软删时间戳（UTC 毫秒）；未删记录为 null。
  final int? deletedAt;

  /// 是否全部归还。
  bool get isReturned => returnedQty >= quantity;

  /// 是否逾期（未还清且已过到期日）。[nowMs] 注入便于测试。
  bool isOverdue(int nowMs) => !isReturned && dueAt < nowMs;

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'item_id': itemId,
        'item_name': itemName,
        'borrower_name': borrowerName,
        'quantity': quantity,
        'returned_qty': returnedQty,
        'borrowed_at': borrowedAt,
        'due_at': dueAt,
        if (returnedAt != null) 'returned_at': returnedAt,
        'is_partial': isPartial ? 1 : 0,
        if (updatedAt != null) 'updated_at': updatedAt,
        // V3.8：软删两列。旧备份恢复时 [fromMap] 按未删读入，这里写回 0/NULL。
        'is_deleted': isDeleted ? 1 : 0,
        if (deletedAt != null) 'deleted_at': deletedAt,
      };

  factory Loan.fromMap(Map<String, Object?> map) => Loan(
        id: map['id'] as int?,
        itemId: (map['item_id'] as num).toInt(),
        itemName: map['item_name'] as String,
        borrowerName: map['borrower_name'] as String,
        quantity: (map['quantity'] as num?)?.toInt() ?? 1,
        returnedQty: (map['returned_qty'] as num?)?.toInt() ?? 0,
        borrowedAt: (map['borrowed_at'] as num).toInt(),
        dueAt: (map['due_at'] as num).toInt(),
        returnedAt: (map['returned_at'] as num?)?.toInt(),
        isPartial: (map['is_partial'] as int?) == 1,
        updatedAt: (map['updated_at'] as num?)?.toInt(),
        // 旧备份无这两列 → 按未删读入（元宝迁移兼容硬约束）。
        isDeleted: (map['is_deleted'] as int?) == 1,
        deletedAt: (map['deleted_at'] as num?)?.toInt(),
      );
}

/// 位置记录。
///
/// V3 交互说明新增 [remark]（位置备注，可选）。列可空以兼容 v4 旧库：
/// 旧行无 remark 列时按 null 读取，不阻断历史数据。
class Location {
  const Location({
    this.id,
    required this.name,
    this.isDeleted = false,
    required this.createdAt,
    required this.updatedAt,
    this.remark,
  });

  final int? id;
  final String name;
  final bool isDeleted;
  final int createdAt;
  final int updatedAt;
  final String? remark;

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'name': name,
        'is_deleted': isDeleted ? 1 : 0,
        'created_at': createdAt,
        'updated_at': updatedAt,
        // null 时省略列：兼容尚未 ALTER 加列的 v3/v4 旧库直接插入。
        if (remark != null) 'remark': remark,
      };

  factory Location.fromMap(Map<String, Object?> map) => Location(
        id: map['id'] as int?,
        name: map['name'] as String,
        isDeleted: (map['is_deleted'] as int?) == 1,
        createdAt: (map['created_at'] as num).toInt(),
        updatedAt: (map['updated_at'] as num).toInt(),
        remark: map['remark'] as String?,
      );
}

/// 物品—位置关联行（多对多的中间表）。
///
/// V3 交互说明把它对应为 ItemRecord：一条关联即一次「物品放在位置」的记录。
/// [rawText] 保存触发该记录的原始语句（语音转文字原文），[tags] 为可选标签
/// （JSON 数组字符串，数据层不解析标签语义）。两列可空以兼容 v4 旧库。
class ItemLocation {
  const ItemLocation({
    this.id,
    required this.itemId,
    required this.locationId,
    this.isDeleted = false,
    required this.createdAt,
    required this.updatedAt,
    this.rawText,
    this.tags,
  });

  final int? id;
  final int itemId;
  final int locationId;
  final bool isDeleted;
  final int createdAt;
  final int updatedAt;
  final String? rawText;
  final String? tags;

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'item_id': itemId,
        'location_id': locationId,
        'is_deleted': isDeleted ? 1 : 0,
        'created_at': createdAt,
        'updated_at': updatedAt,
        // null 时省略列：兼容尚未 ALTER 加列的 v3/v4 旧库直接插入。
        if (rawText != null) 'raw_text': rawText,
        if (tags != null) 'tags': tags,
      };

  factory ItemLocation.fromMap(Map<String, Object?> map) => ItemLocation(
        id: map['id'] as int?,
        itemId: (map['item_id'] as num).toInt(),
        locationId: (map['location_id'] as num).toInt(),
        isDeleted: (map['is_deleted'] as int?) == 1,
        createdAt: (map['created_at'] as num).toInt(),
        updatedAt: (map['updated_at'] as num).toInt(),
        rawText: map['raw_text'] as String?,
        tags: map['tags'] as String?,
      );
}

/// 查询视图：一件物品及其全部位置（同名多位置全量展示）。
///
/// V3.6：新增 [rawTexts]（该物品各关联行的记账原文聚合，如「梯子放阳台」）
/// 与 [tags]（关联行标签聚合），供明细展示与 Excel 导出；两列表为可空列，
/// 无值时为空列表。
class ItemWithLocations {
  const ItemWithLocations({
    required this.item,
    required this.locations,
    this.rawTexts = const <String>[],
    this.tags = const <String>[],
  });

  final Item item;
  final List<Location> locations;

  /// 该物品全部关联行的记账原文（raw_text 非空去重）。
  final List<String> rawTexts;

  /// 该物品全部关联行的标签（tags 非空去重）。
  final List<String> tags;
}

/// 恢复回收站物品的结果（V3.9）。
///
/// PM 拍板口径：明细里已有同名物品时，恢复采取**合并数量**——
/// 把回收站里这件的数量累加到明细里已有的同名物品上，并把它的位置
/// 关联一并并过去，而不是报错拒绝（V3.6 旧口径是撞名即失败）。
class RestoreOutcome {
  const RestoreOutcome({
    required this.itemName,
    required this.merged,
    this.totalQuantity,
  });

  /// 被恢复的物品名。
  final String itemName;

  /// 是否并入了明细里已有的同名物品（true=合并，false=原样恢复）。
  final bool merged;

  /// 合并后的总数量；仅 [merged] 为 true 时有意义。
  final int? totalQuantity;
}

/// V3.10 数量打通：一件物品的三个数量口径。
///
/// PM 2026-11-24 拍板采用**在库口径**（方案 A）：
///  * [stock] = 家里现在有几个（借出即扣减、归还即加回）——权威值就是
///    `items.quantity`
///  * [lent] = 借出去还没还回来的有几个（从借出记录汇总，只作展示）
///  * [available] = 现在还能借几个 = [stock]
///
/// **在借数不再从在库数里减一次**：在库数已经是扣过借出的净值，
/// 再减一遍等于把同一批东西减两遍（V3.10 修掉的真 bug：
/// 「录 3 个 → 借出 2 个」会被算成「可借 0 个」，明明还剩 1 个却借不出去）。
///
/// 存量兼容（不迁移、不改 schema，PM 拍板）：老库的 `items.quantity` 恒为 1
/// （V3.7 引入后录入数量一直被丢弃），与真实家底对不上。这是已知取舍，
/// 由「校准数量」工具按实物清点人工修正。
class QuantityInfo {
  const QuantityInfo({
    required this.stock,
    required this.lent,
    required this.available,
  });

  /// 在库数（家里现在有几个）。
  final int stock;

  /// 未归还的借出总数。
  final int lent;

  /// 可借数（在库数），恒 ≥ 0。东西都在家，当然都能借。
  final int available;

  /// 总拥有数（家里一共几个）= 在库数 + 在借数。
  /// 「校准数量」工具让用户清点这个数，再减去在借数得到在库数。
  int get total => stock + lent;

  /// 是否处于「借空」状态（在库数为 0）——明细页默认折叠这类物品。
  bool get isLentOut => stock <= 0;
}

/// V3.10「校准数量」工具的执行结果（PM 2026-11-24 补充要求 2）。
///
/// 供 UI 如实回显：改了几件、每件从多少改成多少。
class CalibrationReport {
  const CalibrationReport({required this.changedCount, this.details = const []});

  /// 被校正的物品件数。
  final int changedCount;

  /// 每件的校正明细，形如「梯子：1 → 3」。
  final List<String> details;

  /// 是否没有任何改动（已是账实对齐状态）。
  bool get isNoop => changedCount == 0;
}


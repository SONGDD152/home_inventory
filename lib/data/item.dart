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
  });

  final int itemId;
  final int locationId;

  /// true 表示物品与目标位置的关联是新建立的；
  /// false 表示物品原本就在目标位置。
  final bool created;

  /// 挪位前物品所在的其他位置名（不含目标位置本身，已软删）。
  /// 空列表表示物品此前没有其他位置（等价于首次记录）。
  final List<String> previousLocations;
}

/// 物品记录（三张表结构）。
///
/// 物品与位置是多对多关系：一件物品可以放在多个位置，一个位置可以放多件物品。
/// 关联由 [ItemLocation] 表达，本类只描述物品本身。
class Item {
  const Item({
    this.id,
    required this.name,
    this.isDeleted = false,
    required this.createdAt,
    required this.updatedAt,
  });

  final int? id;
  final String name;
  final bool isDeleted;
  final int createdAt;
  final int updatedAt;

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'name': name,
        'is_deleted': isDeleted ? 1 : 0,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory Item.fromMap(Map<String, Object?> map) => Item(
        id: map['id'] as int?,
        name: map['name'] as String,
        isDeleted: (map['is_deleted'] as int?) == 1,
        createdAt: (map['created_at'] as num).toInt(),
        updatedAt: (map['updated_at'] as num).toInt(),
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
class ItemWithLocations {
  const ItemWithLocations({required this.item, required this.locations});

  final Item item;
  final List<Location> locations;
}

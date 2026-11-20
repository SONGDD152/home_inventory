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
class Location {
  const Location({
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

  factory Location.fromMap(Map<String, Object?> map) => Location(
        id: map['id'] as int?,
        name: map['name'] as String,
        isDeleted: (map['is_deleted'] as int?) == 1,
        createdAt: (map['created_at'] as num).toInt(),
        updatedAt: (map['updated_at'] as num).toInt(),
      );
}

/// 物品—位置关联行（多对多的中间表）。
class ItemLocation {
  const ItemLocation({
    this.id,
    required this.itemId,
    required this.locationId,
    this.isDeleted = false,
    required this.createdAt,
    required this.updatedAt,
  });

  final int? id;
  final int itemId;
  final int locationId;
  final bool isDeleted;
  final int createdAt;
  final int updatedAt;

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'item_id': itemId,
        'location_id': locationId,
        'is_deleted': isDeleted ? 1 : 0,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory ItemLocation.fromMap(Map<String, Object?> map) => ItemLocation(
        id: map['id'] as int?,
        itemId: (map['item_id'] as num).toInt(),
        locationId: (map['location_id'] as num).toInt(),
        isDeleted: (map['is_deleted'] as int?) == 1,
        createdAt: (map['created_at'] as num).toInt(),
        updatedAt: (map['updated_at'] as num).toInt(),
      );
}

/// 查询视图：一件物品及其全部位置（同名多位置全量展示）。
class ItemWithLocations {
  const ItemWithLocations({required this.item, required this.locations});

  final Item item;
  final List<Location> locations;
}

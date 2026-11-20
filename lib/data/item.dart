/// 物品记录。
///
/// 数据层只负责持久化；诸如「梯子在哪」的中文语义解析属于上层职责，
/// 这里只接收已经解析好的精确字段值。
class Item {
  const Item({
    this.id,
    required this.name,
    required this.location,
    this.isDeleted = false,
    required this.createdAt,
    required this.updatedAt,
  });

  final int? id;
  final String name;
  final String location;
  final bool isDeleted;
  final int createdAt;
  final int updatedAt;

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'name': name,
        'location': location,
        'is_deleted': isDeleted ? 1 : 0,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory Item.fromMap(Map<String, Object?> map) => Item(
        id: map['id'] as int?,
        name: map['name'] as String,
        location: map['location'] as String,
        isDeleted: (map['is_deleted'] as int?) == 1,
        createdAt: (map['created_at'] as num).toInt(),
        updatedAt: (map['updated_at'] as num).toInt(),
      );

  Item copyWith({
    int? id,
    String? name,
    String? location,
    bool? isDeleted,
    int? createdAt,
    int? updatedAt,
  }) =>
      Item(
        id: id ?? this.id,
        name: name ?? this.name,
        location: location ?? this.location,
        isDeleted: isDeleted ?? this.isDeleted,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  @override
  String toString() =>
      'Item(id: $id, name: $name, location: $location, isDeleted: $isDeleted, '
      'createdAt: $createdAt, updatedAt: $updatedAt)';
}

import 'item.dart';

/// 界面依赖的仓储接口。
///
/// 生产由 [InventoryDatabase] 实现（真实 sqflite 数据库）；
/// 测试可注入内存实现，从而在 headless widget test 里避免 ffi 数据库 I/O
/// 与测试事件循环的死锁（数据层本身由独立测试用真实数据库覆盖）。
abstract class InventoryRepository {
  Future<List<Location>> getAllLocations();

  /// V3：新增位置，可选备注。
  Future<int> addLocation(String name, {String? remark});

  /// V3：编辑位置名称/备注。
  Future<void> updateLocation(int id, {String? name, String? remark});

  /// V3：软删除位置。
  Future<void> deleteLocation(int id);

  /// V3：新增/命中一条物品-位置记录，可选保存原文 rawText。
  Future<UpsertResult> upsertItemLocation(String itemName, int locationId,
      {String? rawText});

  Future<ItemWithLocations?> findByName(String name);
}

import 'item.dart';

/// 界面依赖的仓储接口。
///
/// 生产由 [InventoryDatabase] 实现（真实 sqflite 数据库）；
/// 测试可注入内存实现，从而在 headless widget test 里避免 ffi 数据库 I/O
/// 与测试事件循环的死锁（数据层本身由独立测试用真实数据库覆盖）。
abstract class InventoryRepository {
  Future<List<Location>> getAllLocations();

  Future<int> addLocation(String name);

  Future<UpsertResult> upsertItemLocation(String itemName, int locationId);

  Future<ItemWithLocations?> findByName(String name);
}

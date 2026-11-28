import '../data/inventory_repository.dart';

/// V4.0：一个域实例的抽象（域中枢只依赖这个接口）。
///
/// 生产由 [InventoryDatabase] 实现（真实 sqflite 库）；
/// 测试可注入内存实现——**widget 测试里不该做真实 I/O**
///（sqflite ffi 在 widget 测试的 fake async 环境里会把 pumpAndSettle 卡死）。
abstract class DomainInstance {
  /// 本域的仓储（读写都走它）。
  InventoryRepository get repository;

  /// 本域标识。
  String get domainId;

  /// 在飞操作数（切库守卫等它归零）。
  int get activeOperations;

  /// 切换期间禁止写入。
  void setWritesBlocked(bool blocked);

  /// 关闭连接（重建连接的第一步）。
  Future<void> close();

  /// 重建连接（脏连接自愈）。
  Future<void> reopen();
}


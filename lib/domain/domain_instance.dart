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

/// V4.2.0 三域骨架：知识域的**壳实例**（PM 2026-11-28 拍板③⑤：壳形态、
/// 骨架版不建库）。
///
/// 没有任何库连接、没有仓储句柄——[repository] 访问即抛
/// [ArgumentError]（Error 非 Exception，UI 层有单独 catch 展示友好中文），
/// 这是「知识域不开放仓储」在运行期的最后一道闸（第一道是能力开关
/// `domainCapabilities` 全空，编译/路由期就拦掉了）。
///
/// 切库守卫对它天然安全：在飞操作恒 0（守卫等待立即通过）、
/// 禁写/关闭/重连都是空操作（无连接可管）。
class ShellDomainInstance implements DomainInstance {
  @override
  String get domainId => 'knowledge';

  @override
  InventoryRepository get repository => throw ArgumentError(
        '知识系统建设中，暂未开放任何账目功能',
      );

  @override
  int get activeOperations => 0;

  @override
  void setWritesBlocked(bool blocked) {
    // 壳实例无连接，禁写是空操作。
  }

  @override
  Future<void> close() async {
    // 壳实例无连接，无需关闭。
  }

  @override
  Future<void> reopen() async {
    // 壳实例无连接，无需重连。
  }
}

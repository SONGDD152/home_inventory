import '../data/inventory_repository.dart';
import '../data/knowledge_database.dart';
import 'domain_instance.dart';

/// V4.3（+37 知识库功能）：知识域实例——**建库版**（取代 +33 的壳形态）。
///
/// 仍不开放仓储：[repository] 访问照旧抛 [ArgumentError]
///（「知识域不开放仓储」的运行期闸，第一道仍是能力开关——
/// `domainSupports(knowledge, storage/reminders)` 为 false，
/// 语音路径编译/路由期就拦掉了）。
///
/// 知识库读写走 [store]（`KnowledgeDatabase`，独立接口）——
/// UI 与全系统备份都从这拿，**不塞 InventoryRepository**
///（铁律「新能力拆独立接口」：Dart implements 不继承默认实现）。
///
/// 切库守卫五步照常适用：在飞操作计数真实递增（知识写路径包一层）、
/// 禁写/关闭/重连都管真实连接。
class KnowledgeDomainInstance implements DomainInstance {
  KnowledgeDomainInstance({required this.store});

  /// 知识库读写口（数据层唯一实现）。
  final KnowledgeDatabase store;

  @override
  String get domainId => 'knowledge';

  @override
  int get activeOperations => store.activeOperations;

  @override
  void setWritesBlocked(bool blocked) => store.setWritesBlocked(blocked);

  @override
  Future<void> close() => store.close();

  @override
  Future<void> reopen() => store.reopen();

  @override
  InventoryRepository get repository => throw ArgumentError(
        '知识系统不开放仓储账目功能',
      );
}

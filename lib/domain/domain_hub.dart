import 'package:flutter/foundation.dart';

import '../data/domain.dart';
import '../data/inventory_repository.dart';
import 'domain_instance.dart';

/// V4.0：域中枢——管各域的账本（注册表制）+ 切库守卫。
///
/// PM 2026-11-26 拍板**物理分库**（方案 B）：各域各持独立 `.db`，
/// 互不相通。本类是各域实例的持有者，也是**切域时唯一的把关人**：
///
/// 切换流程（顺序不可乱）：
///  ① 置「切换中」→ **写操作直接拒绝**（不静默重试，静默重试可能写进错库）；
///  ② 若上次切库超时留下 dirty 标记 → **强制重建两库连接**（不留半个旧连接）；
///  ③ 等旧实例在飞查询收尾，**超时上限 3 秒**（超时则放行并记日志，
///     宁可瞬时显示旧数据也不冻界面）；
///  ④ 换当前域指针；
///  ⑤ 解除写闸门 → 通知界面全量刷新。
///
/// **超时不是静默降级**：超时计数 [switchTimeoutCount] 累加并在概览页对用户可见。
class DomainHub {
  /// V4.2.0 三域骨架：**注册表制**——域实例进 `_instances` 查表，
  /// `instanceOf` / 三元判断全改查表；**加第五域 = 构造时往
  /// [additionalInstances] 加一项**，守卫流程与界面零改动。
  ///
  /// `life` / `work` 具名参数保留（V4.0 起的组合根与测试口径不变），
  /// 知识域等新增域经 [additionalInstances] 注册。
  DomainHub({
    required DomainInstance life,
    required DomainInstance work,
    Map<InventoryDomain, DomainInstance> additionalInstances =
        const <InventoryDomain, DomainInstance>{},
    this.switchTimeout = const Duration(seconds: 3),
  }) : _instances = <InventoryDomain, DomainInstance>{
         InventoryDomain.life: life,
         InventoryDomain.work: work,
         ...additionalInstances,
       };

  /// 域实例注册表（域 → 实例；切库守卫与实例查找的唯一事实来源）。
  final Map<InventoryDomain, DomainInstance> _instances;

  /// 生活域实例（兼容 getter，V4.0 起 OverviewReader 组合根口径）。
  DomainInstance get life => _instances[InventoryDomain.life]!;

  /// 工作域实例（兼容 getter）。
  DomainInstance get work => _instances[InventoryDomain.work]!;

  /// 切库等待旧查询收尾的超时上限（元宝批注：3 秒）。
  final Duration switchTimeout;

  InventoryDomain _current = InventoryDomain.life;

  /// 是否正在切域（期间写操作被拒）。
  bool _switching = false;

  /// 连接状态是否已脏（超时后置脏；下次切域前强制重建连接）。
  bool _dirty = false;

  /// 切库超时次数（**用户可见**：概览页展示）。
  int _switchTimeoutCount = 0;

  final List<VoidCallback> _listeners = <VoidCallback>[];

  /// 当前激活的域。
  InventoryDomain get currentDomain => _current;

  /// 当前域的仓储实例（界面所有读写都走它）。
  InventoryRepository get repository => current.repository;

  /// 当前域的实例（需要访问域特有能力时用）。
  DomainInstance get current =>
      _instances[_current] ??
      (throw ArgumentError('域未注册实例：${_current.id}'));

  /// 是否正在切域。
  bool get isSwitching => _switching;

  /// 连接状态是否已脏。
  bool get isDirty => _dirty;

  /// 切库超时次数（概览页对用户可见）。
  int get switchTimeoutCount => _switchTimeoutCount;

  /// 指定域的仓储实例。
  InventoryRepository repositoryOf(InventoryDomain domain) =>
      instanceOf(domain).repository;

  /// 指定域的实例（注册表查表；未注册抛 ArgumentError）。
  DomainInstance instanceOf(InventoryDomain domain) =>
      _instances[domain] ??
      (throw ArgumentError('域未注册实例：${domain.id}'));

  /// 订阅域变化（切换完成 / 超时计数变化时回调，界面据此全量刷新）。
  void addListener(VoidCallback listener) {
    _listeners.add(listener);
  }

  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  void _notify() {
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }

  /// 切换到目标域。
  ///
  /// 同域且连接不脏时是空操作（幂等）。
  Future<void> switchTo(InventoryDomain target) async {
    if (target == _current && !_dirty) return;

    _switching = true;
    // 切换期间所有库都禁写：旧域的写要拒（它马上就不是当前账了），
    // 新域的写也要拒（切换没完成，落点还不确定）。
    for (final instance in _instances.values) {
      instance.setWritesBlocked(true);
    }
    _notify();

    try {
      // ② 上次超时留下的脏连接 → 先重建，不带着半个旧连接切。
      if (_dirty) {
        await _rebuildConnections();
        _dirty = false;
      }

      // ③ 等旧实例在飞查询收尾（超时上限 3 秒）。
      final previous = current;
      final deadline = DateTime.now().add(switchTimeout);
      while (previous.activeOperations > 0 &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (previous.activeOperations > 0) {
        // 超时：放行，但**置脏**（旧连接可能没收尾），
        // 并把超时次数记下来让用户看得见（不是静默降级）。
        _dirty = true;
        _switchTimeoutCount += 1;
        debugPrint(
          'V4.0 切库超时：${previous.domainId} 仍有 '
          '${previous.activeOperations} 个在飞操作，已置脏并放行。',
        );
      }

      // ④ 换指针。
      _current = target;
    } finally {
      // ⑤ 解除写闸门。
      for (final instance in _instances.values) {
        instance.setWritesBlocked(false);
      }
      _switching = false;
      _notify();
    }
  }

  /// 强制重建所有库连接（脏连接自愈；壳实例的 reopen 是空操作）。
  Future<void> _rebuildConnections() async {
    debugPrint('V4.0 切库守卫：重建库连接（脏连接自愈）。');
    for (final instance in _instances.values) {
      await instance.reopen();
    }
  }
}

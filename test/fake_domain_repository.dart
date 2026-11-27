// ignore_for_file: deprecated_member_use
import 'package:home_inventory/data/domain.dart';
import 'package:home_inventory/data/inventory_repository.dart';
import 'package:home_inventory/data/item.dart';
import 'package:home_inventory/data/normalize.dart';
import 'package:home_inventory/data/reminder.dart';
import 'package:home_inventory/data/reminder_repository.dart';
import 'package:home_inventory/data/todo_state.dart';
import 'package:home_inventory/domain/domain_instance.dart';
import 'package:home_inventory/domain/todo_state_writer.dart';

/// V4.0 测试用：内存域实例。
///
/// 为什么不用真库做 widget 测试：sqflite ffi 在 widget 测试的 fake async
/// 环境里做真实 I/O 会把 `pumpAndSettle` 卡死（无限等待）。
/// 数据层的真实 sqlite 行为由 inventory_database_test.dart 与
/// v40_multidomain_test.dart 的数据层用例覆盖；widget 测试只验界面结构。
class FakeDomainInstance implements DomainInstance {
  FakeDomainInstance(this._repository, {this.domainId = 'life'});

  final InventoryRepository _repository;

  @override
  final String domainId;

  @override
  InventoryRepository get repository => _repository;

  int _active = 0;

  @override
  int get activeOperations => _active;

  @override
  void setWritesBlocked(bool blocked) {}

  @override
  Future<void> close() async {}

  @override
  Future<void> reopen() async {}

  /// 挂起一次"在飞操作"（模拟旧查询迟迟不收尾）。
  Future<T> track<T>(Future<T> Function() action) async {
    _active++;
    try {
      return await action();
    } finally {
      _active--;
    }
  }
}

/// V4.0 测试用：内存仓储（只实现 widget 测试真正用到的方法）。
///
/// V4.1 批次 2：加实现 [TodoStateWriter]（内存版 `todo_states`），
/// 让概览页的 widget 测试能真正点延期 / 点备注——
/// 之前概览页 widget 测试完全没做过，因为假仓储拿不到待办写口，
/// 界面上那些按钮全是 disabled 的（等于没测）。
class FakeDomainRepository
    implements InventoryRepository, ReminderRepository, TodoStateWriter {
  final List<Location> _locations = <Location>[];
  final List<Item> _items = <Item>[];
  final List<ItemLocation> _links = <ItemLocation>[];
  final List<Reminder> _reminders = <Reminder>[];
  final List<DailyReport> _reports = <DailyReport>[];
  int _nextId = 0;

  int get locationCount => _locations.length;
  int get itemCount => _items.length;

  @override
  Future<List<Location>> getAllLocations() async =>
      _locations.where((l) => !l.isDeleted).toList();

  @override
  Future<int> addLocation(String name, {String? remark}) async {
    final key = normalizeName(name);
    final existing = _locations.where((l) => l.name == key).firstOrNull;
    if (existing != null) return existing.id!;
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = ++_nextId;
    _locations.add(Location(
        id: id, name: key, createdAt: now, updatedAt: now, remark: remark));
    return id;
  }

  @override
  Future<void> updateItem(int id, String name) async {}

  @override
  Future<void> deleteItem(int id) async {}

  @override
  Future<List<ItemWithLocations>> getDeletedItems() async =>
      const <ItemWithLocations>[];

  @override
  Future<RestoreOutcome> restoreItem(int id) async =>
      const RestoreOutcome(itemName: '', merged: false);

  @override
  Future<void> purgeItem(int id) async {}

  @override
  Future<void> purgeAll() async {}

  @override
  Future<void> updateLocation(int id, {String? name, String? remark}) async {}

  @override
  Future<void> deleteLocation(int id) async {}

  @override
  Future<UpsertResult> upsertItemLocation(String itemName, int locationId,
      {String? rawText, int? quantity, bool additive = false}) async {
    final key = normalizeName(itemName);
    final now = DateTime.now().millisecondsSinceEpoch;
    var item = _items.where((i) => i.name == key && !i.isDeleted).firstOrNull;
    if (item == null) {
      final id = ++_nextId;
      item = Item(id: id, name: key, createdAt: now, updatedAt: now);
      _items.add(item);
    }
    final link = _links
        .where((l) => l.itemId == item!.id && l.locationId == locationId)
        .firstOrNull;
    if (link == null) {
      _links.add(ItemLocation(
        id: ++_nextId,
        itemId: item.id!,
        locationId: locationId,
        createdAt: now,
        updatedAt: now,
        rawText: rawText,
        quantity: quantity ?? 1,
      ));
    }
    return UpsertResult(
        itemId: item.id!, locationId: locationId, created: true);
  }

  @override
  Future<ItemWithLocations?> findByName(String name) async {
    final key = normalizeName(name);
    final item = _items.where((i) => i.name == key && !i.isDeleted).firstOrNull;
    if (item == null) return null;
    return _withLocations(item);
  }

  @override
  Future<List<ItemWithLocations>> getAllItemsWithLocations() async =>
      _items.where((i) => !i.isDeleted).map(_withLocations).toList();

  ItemWithLocations _withLocations(Item item) {
    final links = _links
        .where((l) => l.itemId == item.id && !l.isDeleted)
        .map((l) => _locations.firstWhere((loc) => loc.id == l.locationId))
        .toList();
    return ItemWithLocations(item: item, locations: links);
  }

  @override
  Future<Map<String, Object?>> exportBackup() async =>
      <String, Object?>{'app': 'home_inventory', 'items': _items.length};

  @override
  Future<void> restoreBackup(Map<String, Object?> data) async {}

  @override
  Future<List<Loan>> getAllLoans() async => const <Loan>[];

  // ---------- 以下为 widget 测试用不到的最小实现 ----------
  // Dart 的 `implements` 不继承默认实现，必须逐个补齐（这里给最小行为）。

  @override
  Future<MoveResult> moveItem(String itemName, int locationId,
          {String? rawText}) =>
      moveItemWhole(itemName, locationId, rawText: rawText);

  @override
  Future<MoveResult> moveItemWhole(String itemName, int toLocationId,
          {String? rawText}) async {
    final key = normalizeName(itemName);
    final now = DateTime.now().millisecondsSinceEpoch;
    var item = _items.where((i) => i.name == key && !i.isDeleted).firstOrNull;
    var created = false;
    if (item == null) {
      final id = ++_nextId;
      item = Item(id: id, name: key, createdAt: now, updatedAt: now);
      _items.add(item);
      created = true;
    }
    // 挪位 = 软删其他位置关联，目标位置建关联（V3 语义：总数不变）。
    final previous = <String>[];
    for (var i = 0; i < _links.length; i++) {
      final link = _links[i];
      if (link.itemId != item.id || link.isDeleted) continue;
      if (link.locationId == toLocationId) continue;
      previous.add(_locations
          .firstWhere((loc) => loc.id == link.locationId)
          .name);
      _links[i] = ItemLocation(
        id: link.id,
        itemId: link.itemId,
        locationId: link.locationId,
        isDeleted: true,
        createdAt: link.createdAt,
        updatedAt: now,
        rawText: link.rawText,
        tags: link.tags,
        quantity: link.quantity,
      );
    }
    final exists = _links
        .where((l) =>
            l.itemId == item!.id &&
            l.locationId == toLocationId &&
            !l.isDeleted)
        .isNotEmpty;
    if (!exists) {
      _links.add(ItemLocation(
        id: ++_nextId,
        itemId: item.id!,
        locationId: toLocationId,
        createdAt: now,
        updatedAt: now,
        rawText: rawText,
        quantity: 1,
      ));
    }
    return MoveResult(
      itemId: item.id!,
      locationId: toLocationId,
      created: created || !exists,
      previousLocations: previous,
      quantity: 1,
    );
  }

  @override
  Future<MoveResult> moveItemPartial(
    String itemName,
    int fromLocationId,
    int toLocationId, {
    required int quantity,
    String? rawText,
  }) async =>
      throw UnimplementedError('内存仓储不实现部分挪');

  @override
  Future<Loan> lendItem(String itemName, String borrowerName,
          {int quantity = 1, int? days, int? fromLocationId}) async =>
      throw UnimplementedError('内存仓储不实现借出');

  @override
  Future<void> returnLoan(int loanId, {int? quantity, int? toLocationId}) async {}

  @override
  Future<void> updateLoanDue(int loanId, int days) async {}

  @override
  Future<List<Loan>> getDeletedLoans() async => const <Loan>[];

  @override
  Future<void> deleteLoan(int id) async {}

  @override
  Future<void> restoreLoan(int id) async {}

  @override
  Future<void> purgeLoan(int id) async {}

  @override
  Future<List<Borrower>> getActiveBorrowers() async => const <Borrower>[];

  @override
  Future<void> softDeleteBorrower(int id) async {}

  @override
  Future<QuantityInfo> getQuantityInfo(String itemName) async {
    final all = await getAllQuantityInfo();
    for (final info in all.values) {
      return info;
    }
    return const QuantityInfo(stock: 0, lent: 0, available: 0);
  }

  @override
  Future<CalibrationReport> calibrateQuantities({
    Map<int, int> totals = const <int, int>{},
    Map<int, Map<int, int>> locationTotals = const <int, Map<int, int>>{},
  }) async =>
      const CalibrationReport(changedCount: 0);

  @override
  Future<int> setItemQuantity(String itemName, int quantity,
          {bool additive = false}) async =>
      0;

  @override
  Future<int> setLocationQuantity(
    String itemName,
    int locationId,
    int quantity, {
    bool additive = false,
  }) async =>
      0;

  @override
  Future<DiscardOutcome> discardQuantity(
    String itemName,
    int quantity, {
    required int locationId,
    DiscardSource sourceType = DiscardSource.inStock,
  }) async =>
      throw UnimplementedError('内存仓储不实现部分废弃');

  @override
  Future<ItemDiscard> restoreDiscard(int discardId, int toLocationId,
          {int? quantity}) async =>
      throw UnimplementedError('内存仓储不实现恢复废弃');

  @override
  Future<List<ItemDiscard>> getDiscards({bool includeRestored = false}) async =>
      const <ItemDiscard>[];

  @override
  Future<void> purgeDiscard(int discardId) async {}

  @override
  Future<bool> checkConservation() async => true;

  @override
  Future<Map<int, QuantityInfo>> getAllQuantityInfo() async {
    final result = <int, QuantityInfo>{};
    for (final item in _items.where((i) => !i.isDeleted)) {
      final qty = _links
          .where((l) => l.itemId == item.id && !l.isDeleted)
          .fold<int>(0, (sum, l) => sum + l.quantity);
      result[item.id!] = QuantityInfo(stock: qty, lent: 0, available: qty);
    }
    return result;
  }

  // ---------- ReminderRepository ----------

  @override
  Future<List<Reminder>> getReminders({bool includeDone = true}) async =>
      _reminders
          .where((r) => !r.isDeleted && (includeDone || r.isPending))
          .toList();

  @override
  Future<int> addReminder(String title,
      {String? detail,
      DateTime? dueAt,
      String? repeatRule,
      int priority = ReminderPriority.normal}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = ++_nextId;
    _reminders.add(Reminder(
      id: id,
      title: title,
      detail: detail,
      dueAt: dueAt?.millisecondsSinceEpoch,
      repeatRule: repeatRule,
      // V4.1 批次 2（元宝裁定①）：优先级。
      priority: ReminderPriority.normalize(priority),
      createdAt: now,
      updatedAt: now,
    ));
    return id;
  }

  @override
  Future<void> updateReminder(int id,
      {String? title,
      String? detail,
      DateTime? dueAt,
      int? priority}) async {
    final index = _reminders.indexWhere((r) => r.id == id);
    if (index < 0) return;
    final old = _reminders[index];
    _reminders[index] = Reminder(
      id: old.id,
      title: title ?? old.title,
      detail: detail ?? old.detail,
      dueAt: dueAt?.millisecondsSinceEpoch ?? old.dueAt,
      status: old.status,
      doneAt: old.doneAt,
      repeatRule: old.repeatRule,
      priority: priority == null
          ? old.priority
          : ReminderPriority.normalize(priority),
      createdAt: old.createdAt,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  @override
  Future<void> setReminderDone(int id, {bool done = true}) async {
    final index = _reminders.indexWhere((r) => r.id == id);
    if (index < 0) return;
    final old = _reminders[index];
    _reminders[index] = Reminder(
      id: old.id,
      title: old.title,
      detail: old.detail,
      dueAt: old.dueAt,
      status: done ? 'done' : 'pending',
      doneAt: done ? DateTime.now().millisecondsSinceEpoch : null,
      repeatRule: old.repeatRule,
      createdAt: old.createdAt,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  @override
  Future<void> deleteReminder(int id) async {
    // V4.1.3：与生产库同口径——软删进回收站，不物理移除。
    final i = _reminders.indexWhere((r) => r.id == id && !r.isDeleted);
    if (i < 0) return;
    final old = _reminders[i];
    final now = DateTime.now().millisecondsSinceEpoch;
    _reminders[i] = Reminder(
      id: old.id,
      title: old.title,
      detail: old.detail,
      dueAt: old.dueAt,
      status: old.status,
      doneAt: old.doneAt,
      repeatRule: old.repeatRule,
      priority: old.priority,
      isDeleted: true,
      deletedAt: now,
      createdAt: old.createdAt,
      updatedAt: now,
    );
  }

  @override
  Future<List<Reminder>> getDeletedReminders() async => _reminders
      .where((r) => r.isDeleted)
      .toList()
    ..sort((a, b) => (b.deletedAt ?? 0).compareTo(a.deletedAt ?? 0));

  @override
  Future<void> restoreReminder(int id) async {
    final i = _reminders.indexWhere((r) => r.id == id && r.isDeleted);
    if (i < 0) return;
    final old = _reminders[i];
    _reminders[i] = Reminder(
      id: old.id,
      title: old.title,
      detail: old.detail,
      dueAt: old.dueAt,
      status: old.status,
      doneAt: old.doneAt,
      repeatRule: old.repeatRule,
      priority: old.priority,
      isDeleted: false,
      deletedAt: null,
      createdAt: old.createdAt,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  @override
  Future<void> purgeReminder(int id) async {
    // 硬删 = 痕迹全无：提醒行 + 对应 todo_states 一起清掉。
    _reminders.removeWhere((r) => r.id == id);
    _todoStates.remove(TodoState.entryKeyOf(TodoSourceType.scheduleReminder, id));
  }

  @override
  Future<DailyReport?> getDailyReport(String reportDate) async =>
      _reports.where((r) => r.reportDate == reportDate).firstOrNull;

  @override
  Future<List<DailyReport>> getDailyReports({int limit = 30}) async =>
      _reports.take(limit).toList();

  @override
  Future<void> saveDailyReport(String reportDate, String contentMd,
      {String? sourceSnapshot}) async {
    _reports.removeWhere((r) => r.reportDate == reportDate);
    _reports.add(DailyReport(
      id: ++_nextId,
      reportDate: reportDate,
      contentMd: contentMd,
      generatedAt: DateTime.now().millisecondsSinceEpoch,
      sourceSnapshot: sourceSnapshot,
    ));
  }

  // ---------- V4.1：待办状态（todo_states）内存实现 ----------

  /// 内存版 `todo_states`：key = `'{sourceType}_{sourceId}'`。
  final Map<String, TodoState> _todoStates = <String, TodoState>{};

  @override
  Future<TodoState?> readState(String sourceType, int sourceId) async =>
      _todoStates[TodoState.entryKeyOf(sourceType, sourceId)];

  @override
  Future<List<TodoState>> loadStates() async => _todoStates.values.toList();

  @override
  Future<void> markDone(String sourceType, int sourceId,
      {bool done = true}) async {
    final key = TodoState.entryKeyOf(sourceType, sourceId);
    final now = DateTime.now().millisecondsSinceEpoch;
    final old = _todoStates[key];
    _todoStates[key] = TodoState(
      id: old?.id,
      sourceType: sourceType,
      sourceId: sourceId,
      status: done ? TodoStatus.done : TodoStatus.pending,
      doneAt: done ? now : null,
      // 撤销完成态**不清**延期次数与备注——那是历史，不是完成态。
      deferCount: old?.deferCount ?? 0,
      handleNote: old?.handleNote,
      nextDueAt: old?.nextDueAt,
      createdAt: old?.createdAt ?? now,
      updatedAt: now,
    );
  }

  @override
  Future<void> setTodoStatus(
      String sourceType, int sourceId, String status) async {
    if (!TodoStatus.toggleCycle.contains(status)) return;
    if (status == TodoStatus.done) {
      await markDone(sourceType, sourceId, done: true);
      return;
    }
    final key = TodoState.entryKeyOf(sourceType, sourceId);
    final now = DateTime.now().millisecondsSinceEpoch;
    final old = _todoStates[key];
    _todoStates[key] = TodoState(
      id: old?.id,
      sourceType: sourceType,
      sourceId: sourceId,
      status: status,
      doneAt: null,
      deferCount: old?.deferCount ?? 0,
      handleNote: old?.handleNote,
      nextDueAt: old?.nextDueAt,
      createdAt: old?.createdAt ?? now,
      updatedAt: now,
    );
  }

  @override
  Future<void> defer(String sourceType, int sourceId,
      {String? reason, int days = 1, DateTime? dueOn}) async {
    final key = TodoState.entryKeyOf(sourceType, sourceId);
    final now = DateTime.now().millisecondsSinceEpoch;
    final old = _todoStates[key];
    final anchor = old?.nextDueAt ?? now;
    final next = dueOn != null
        ? dueOn.millisecondsSinceEpoch
        : DateTime.fromMillisecondsSinceEpoch(anchor)
            .add(Duration(days: days))
            .millisecondsSinceEpoch;
    _todoStates[key] = TodoState(
      id: old?.id,
      sourceType: sourceType,
      sourceId: sourceId,
      status: TodoStatus.deferred,
      doneAt: old?.doneAt,
      deferCount: (old?.deferCount ?? 0) + 1,
      handleNote: reason ?? old?.handleNote,
      nextDueAt: next,
      createdAt: old?.createdAt ?? now,
      updatedAt: now,
    );
  }

  @override
  Future<void> setNote(String sourceType, int sourceId, String note) async {
    final key = TodoState.entryKeyOf(sourceType, sourceId);
    final now = DateTime.now().millisecondsSinceEpoch;
    final old = _todoStates[key];
    _todoStates[key] = TodoState(
      id: old?.id,
      sourceType: sourceType,
      sourceId: sourceId,
      status: old?.status ?? TodoStatus.pending,
      doneAt: old?.doneAt,
      deferCount: old?.deferCount ?? 0,
      handleNote: note,
      nextDueAt: old?.nextDueAt,
      createdAt: old?.createdAt ?? now,
      updatedAt: now,
    );
  }

  @override
  Future<int> syncOverdue(DateTime now) async => 0;
}

/// 造一对内存域实例（生活 + 工作），供 widget 测试用。
({FakeDomainInstance life, FakeDomainInstance work}) fakeDomains() {
  final lifeRepo = FakeDomainRepository();
  final workRepo = FakeDomainRepository();
  return (
    life: FakeDomainInstance(lifeRepo, domainId: InventoryDomain.life.id),
    work: FakeDomainInstance(workRepo, domainId: InventoryDomain.work.id),
  );
}

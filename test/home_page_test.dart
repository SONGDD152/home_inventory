// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:home_inventory/home_inventory.dart';

import 'fake_loan_mixin.dart';

/// 纯内存仓储：用于 widget 测试，操作是内存级的，pump 一帧即可落地。
/// 数据层的真实数据库行为由 inventory_database_test.dart 用真实 sqlite 覆盖。
///
/// Step 0（第 4 块测试基建）：三处 key 生成已改用生产共用 normalizeName，
/// 与仓储边界同源；不再各自 trim()，杜绝两套归一化标准。
class InMemoryRepository with FakeLoanMixin implements InventoryRepository {
  final List<Location> _locations = <Location>[];
  final List<Item> _items = <Item>[];
  final List<ItemLocation> _links = <ItemLocation>[];
  int _locationId = 0;
  int _itemId = 0;

  // V3.7 缺陷修复回归：借出/归还内存实现，供首页「说一句」端到端断言。
  // 类自身方法优先于 FakeLoanMixin，不影响其他测试文件共用的 mixin。
  final List<Loan> _loans = <Loan>[];
  int _loanId = 0;

  // V3.12：部分废弃流水（内存实现与生产同语义）。
  final List<ItemDiscard> _discards = <ItemDiscard>[];
  int _discardId = 0;

  @override
  Future<Loan> lendItem(String itemName, String borrowerName,
      {int quantity = 1, int? days, int? fromLocationId}) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final key = normalizeName(itemName);
    // V3.10：与生产一致——物品必须已存在（PM 拍板④），借出扣减在库数。
    final hit = _items.where((i) => i.name == key && !i.isDeleted).firstOrNull;
    if (hit == null) {
      throw ArgumentError.value(
        itemName,
        'itemName',
        '还没记录过「$key」，先说一句「$key放阳台」再借',
      );
    }
    final itemId = hit.id!;
    final lent = _outstandingLent(itemId);
    // V3.10：在库数 = items.quantity（借出即扣、归还即加），可借数 = 在库数。
    final stock = hit.quantity;
    final available = stock;
    if (quantity > available) {
      throw ArgumentError.value(
        quantity,
        'quantity',
        stock <= 0
            ? '「$key」家里已经没有可借的了（$lent 个都借出去了），先记着家里还有几个再借'
            : '家里只有$stock个「$key」，可借$available个',
      );
    }
    // V3.11：从指定位置（未指定则从主位置）扣减，位置数量与总数同事务收口。
    final fromId = fromLocationId ?? _mainLocationId(itemId);
    final fromQty = _locationQty(itemId, fromId);
    if (fromQty < quantity) {
      final fromName = _locations
          .where((l) => l.id == fromId)
          .map((l) => l.name)
          .firstOrNull ?? '这个位置';
      throw ArgumentError.value(
        quantity,
        'quantity',
        '$fromName只有 $fromQty 个，不够借 $quantity 个',
      );
    }
    _writeLocationQty(itemId, fromId, fromQty - quantity);
    _syncTotal(itemId);
    final loan = Loan(
      id: ++_loanId,
      itemId: itemId,
      itemName: key,
      borrowerName: normalizeName(borrowerName),
      quantity: quantity,
      borrowedAt: now,
      dueAt: now + (days ?? InventoryDatabase.defaultLoanDays) * 86400000,
    );
    _loans.add(loan);
    return loan;
  }

  /// V3.10：设置物品在库数。
  void _setQuantity(int itemId, int qty) {
    final idx = _items.indexWhere((i) => i.id == itemId);
    if (idx < 0) return;
    _items[idx] = Item(
      id: _items[idx].id,
      name: _items[idx].name,
      createdAt: _items[idx].createdAt,
      updatedAt: _items[idx].updatedAt,
      quantity: qty,
    );
  }

  // ---------- V3.11 按位置记数量：内存仓储与生产同模型 ----------
  // 数量记在关联行上，items.quantity 只是 SUM 缓存；任何写位置数量的操作
  // 都必须经 _syncTotal 收口，否则 UI 测试会掩盖生产上的双写不一致。

  /// 读某物品在某活跃位置的数量；没有关联返回 0。
  int _locationQty(int itemId, int locationId) {
    for (final l in _links) {
      if (l.itemId == itemId && l.locationId == locationId && !l.isDeleted) {
        return l.quantity;
      }
    }
    return 0;
  }

  /// 写某物品在某位置的数量（关联不存在则新建）。
  void _writeLocationQty(int itemId, int locationId, int qty) {
    final idx = _links.indexWhere((l) =>
        l.itemId == itemId && l.locationId == locationId && !l.isDeleted);
    if (idx >= 0) {
      final old = _links[idx];
      _links[idx] = ItemLocation(
        id: old.id,
        itemId: old.itemId,
        locationId: old.locationId,
        isDeleted: false,
        createdAt: old.createdAt,
        updatedAt: old.updatedAt,
        rawText: old.rawText,
        tags: old.tags,
        quantity: qty,
      );
      return;
    }
    _links.add(ItemLocation(
      id: _links.length + 1,
      itemId: itemId,
      locationId: locationId,
      createdAt: 1,
      updatedAt: 1,
      quantity: qty,
    ));
  }

  /// 单一写入口：items.quantity = SUM(活跃关联数量)，同内存事务内完成。
  int _syncTotal(int itemId) {
    var total = 0;
    for (final l in _links) {
      if (l.itemId == itemId && !l.isDeleted) total += l.quantity;
    }
    final idx = _items.indexWhere((i) => i.id == itemId);
    if (idx >= 0) {
      final cur = _items[idx];
      _items[idx] = Item(
        id: cur.id,
        name: cur.name,
        quantity: total,
        isDeleted: cur.isDeleted,
        createdAt: cur.createdAt,
        updatedAt: cur.updatedAt,
        deletedAt: cur.deletedAt,
      );
    }
    return total;
  }

  /// 主位置 = 活跃关联 id 最小者（与迁移口径一致）。
  int _mainLocationId(int itemId) {
    final active = _links
        .where((l) => l.itemId == itemId && !l.isDeleted)
        .toList()
      ..sort((a, b) => a.id!.compareTo(b.id!));
    return active.firstOrNull?.locationId ?? 0;
  }

  int _findOrCreateItem(String key) {
    final hit = _items.where((i) => i.name == key && !i.isDeleted).firstOrNull;
    if (hit != null) return hit.id!;
    final id = ++_itemId;
    _items.add(Item(id: id, name: key, createdAt: 1, updatedAt: 1, quantity: 1));
    return id;
  }

  /// 软删一条关联（保留数量留底，恢复时原样复活）。
  void _softDeleteLink(ItemLocation l) {
    final idx = _links.indexOf(l);
    if (idx < 0) return;
    _links[idx] = ItemLocation(
      id: l.id,
      itemId: l.itemId,
      locationId: l.locationId,
      isDeleted: true,
      createdAt: l.createdAt,
      updatedAt: l.updatedAt,
      rawText: l.rawText,
      tags: l.tags,
      quantity: l.quantity,
    );
  }

  @override
  Future<List<Loan>> getAllLoans() async =>
      List<Loan>.unmodifiable(_loans.reversed);

  @override
  Future<void> returnLoan(int loanId, {int? quantity, int? toLocationId}) async {
    final idx = _loans.indexWhere((l) => l.id == loanId);
    if (idx < 0) return;
    final old = _loans[idx];
    final returned = quantity ?? (old.quantity - old.returnedQty);
    final total = old.returnedQty + returned;
    _loans[idx] = Loan(
      id: old.id,
      itemId: old.itemId,
      itemName: old.itemName,
      borrowerName: old.borrowerName,
      quantity: old.quantity,
      returnedQty: total,
      borrowedAt: old.borrowedAt,
      dueAt: old.dueAt,
      returnedAt: total >= old.quantity ? 1 : null,
      isPartial: total > 0 && total < old.quantity,
    );
    // V3.11：归还直接加到指定位置（未指定=主位置），不再由 UI 后续
    // moveItem 把别的位置一起搬走——这正是 PM 真机现象①的根因。
    if (old.itemId != 0) {
      final toId = toLocationId ?? _mainLocationId(old.itemId);
      if (toId != 0) {
        _writeLocationQty(
            old.itemId, toId, _locationQty(old.itemId, toId) + returned);
        _syncTotal(old.itemId);
      } else {
        final cur = _items.where((i) => i.id == old.itemId).firstOrNull;
        if (cur != null) _setQuantity(old.itemId, cur.quantity + returned);
      }
    }
  }

  @override
  Future<List<Location>> getAllLocations() async =>
      List<Location>.unmodifiable(_locations);

  /// V3.9：改借期内存实现（供首页「说一句改借期」端到端断言）。
  @override
  Future<void> updateLoanDue(int loanId, int days) async {
    final idx = _loans.indexWhere((l) => l.id == loanId);
    if (idx < 0) return;
    final old = _loans[idx];
    _loans[idx] = Loan(
      id: old.id,
      itemId: old.itemId,
      itemName: old.itemName,
      borrowerName: old.borrowerName,
      quantity: old.quantity,
      returnedQty: old.returnedQty,
      borrowedAt: old.borrowedAt,
      dueAt: old.borrowedAt + days * 86400000,
      returnedAt: old.returnedAt,
      isPartial: old.isPartial,
    );
  }

  @override
  Future<int> addLocation(String name, {String? remark}) async {
    final key = normalizeName(name);
    final existing = _locations.where((l) => l.name == key).toList();
    if (existing.isNotEmpty) return existing.first.id!;
    final id = ++_locationId;
    _locations.add(
      Location(id: id, name: key, createdAt: 1, updatedAt: 1, remark: remark),
    );
    return id;
  }

  @override
  Future<void> updateLocation(int id, {String? name, String? remark}) async {
    final idx = _locations.indexWhere((l) => l.id == id);
    if (idx < 0) return;
    final old = _locations[idx];
    _locations[idx] = Location(
      id: old.id,
      name: name == null ? old.name : normalizeName(name),
      isDeleted: old.isDeleted,
      createdAt: old.createdAt,
      updatedAt: old.updatedAt,
      remark: remark ?? old.remark,
    );
  }

  @override
  Future<void> deleteLocation(int id) async {
    final idx = _locations.indexWhere((l) => l.id == id);
    if (idx < 0) return;
    final old = _locations[idx];
    _locations[idx] = Location(
      id: old.id,
      name: old.name,
      isDeleted: true,
      createdAt: old.createdAt,
      updatedAt: old.updatedAt,
      remark: old.remark,
    );
  }

  @override
  Future<void> updateItem(int id, String name) async {
    final idx = _items.indexWhere((i) => i.id == id);
    if (idx < 0) return;
    final old = _items[idx];
    _items[idx] = Item(
      id: old.id,
      name: normalizeName(name),
      isDeleted: old.isDeleted,
      createdAt: old.createdAt,
      updatedAt: old.updatedAt,
    );
  }

  @override
  Future<void> deleteItem(int id) async {
    final idx = _items.indexWhere((i) => i.id == id);
    if (idx < 0) return;
    final old = _items[idx];
    final now = DateTime.now().millisecondsSinceEpoch;
    _items[idx] = Item(
      id: old.id,
      name: old.name,
      isDeleted: true,
      createdAt: old.createdAt,
      updatedAt: now,
      deletedAt: now,
    );
    // V3.6：活跃关联行同步软删留底（与真实库一致，恢复时可复活）。
    for (var i = 0; i < _links.length; i++) {
      final l = _links[i];
      if (l.itemId == id && !l.isDeleted) {
        _links[i] = ItemLocation(
          id: l.id,
          itemId: l.itemId,
          locationId: l.locationId,
          isDeleted: true,
          createdAt: l.createdAt,
          updatedAt: now,
          rawText: l.rawText,
          tags: l.tags,
          quantity: l.quantity,
        );
      }
    }
  }

  @override
  Future<List<ItemWithLocations>> getDeletedItems() async {
    final deleted = _items.where((i) => i.isDeleted).toList()
      ..sort((a, b) => (b.deletedAt ?? 0).compareTo(a.deletedAt ?? 0));
    return <ItemWithLocations>[
      for (final item in deleted)
        ItemWithLocations(
          item: item,
          locations: _locations
              .where((loc) =>
                  !loc.isDeleted &&
                  _links.any((link) =>
                      link.itemId == item.id && link.locationId == loc.id))
              .toList(growable: false),
        ),
    ];
  }

  @override
  Future<RestoreOutcome> restoreItem(int id) async {
    final idx = _items.indexWhere((i) => i.id == id);
    if (idx < 0) {
      return const RestoreOutcome(itemName: '', merged: false);
    }
    final item = _items[idx];
    final now = DateTime.now().millisecondsSinceEpoch;
    // V3.9（PM 拍板）：明细里已有同名物品 → 合并数量，不报错拒绝。
    final conflictIdx = _items.indexWhere(
        (i) => i.id != id && i.name == item.name && !i.isDeleted);
    if (conflictIdx >= 0) {
      final live = _items[conflictIdx];
      _items[conflictIdx] = Item(
        id: live.id,
        name: live.name,
        quantity: live.quantity,
        isDeleted: false,
        createdAt: live.createdAt,
        updatedAt: now,
      );
      // V3.11：位置关联并过去；同位置已有活跃行时数量相加，不丢弃。
      // 阳台2 + 阳台1 = 阳台3，客厅1 照旧保留——废弃再恢复要原样还原。
      final moved = _links.where((l) => l.itemId == id).toList();
      for (final l in moved) {
        final dupIdx = _links.indexWhere((x) =>
            x.itemId == live.id && x.locationId == l.locationId && !x.isDeleted);
        if (dupIdx >= 0) {
          final dup = _links[dupIdx];
          _links[dupIdx] = ItemLocation(
            id: dup.id,
            itemId: dup.itemId,
            locationId: dup.locationId,
            isDeleted: false,
            createdAt: dup.createdAt,
            updatedAt: now,
            rawText: dup.rawText,
            tags: dup.tags,
            quantity: dup.quantity + l.quantity,
          );
          _links.remove(l);
          continue;
        }
        final srcIdx = _links.indexOf(l);
        _links[srcIdx] = ItemLocation(
          id: l.id,
          itemId: live.id!,
          locationId: l.locationId,
          isDeleted: false,
          createdAt: l.createdAt,
          updatedAt: now,
          rawText: l.rawText,
          tags: l.tags,
          quantity: l.quantity,
        );
      }
      _items.removeAt(idx);
      final total = _syncTotal(live.id!);
      return RestoreOutcome(
        itemName: item.name,
        merged: true,
        totalQuantity: total,
      );
    }
    _items[idx] = Item(
      id: item.id,
      name: item.name,
      quantity: item.quantity,
      createdAt: item.createdAt,
      updatedAt: now,
    );
    // 软删关联行复活（内存版不做 updated_at 精确匹配，全量复活），
    // 每位置数量原样带回，再统一收口总数。
    for (var i = 0; i < _links.length; i++) {
      final l = _links[i];
      if (l.itemId == id && l.isDeleted) {
        _links[i] = ItemLocation(
          id: l.id,
          itemId: l.itemId,
          locationId: l.locationId,
          isDeleted: false,
          createdAt: l.createdAt,
          updatedAt: now,
          rawText: l.rawText,
          tags: l.tags,
          quantity: l.quantity,
        );
      }
    }
    _syncTotal(id);
    return RestoreOutcome(itemName: item.name, merged: false);
  }

  @override
  Future<void> purgeItem(int id) async {
    final name = _items.where((i) => i.id == id).map((i) => i.name).firstOrNull;
    _items.removeWhere((i) => i.id == id && i.isDeleted);
    _links.removeWhere((l) => l.itemId == id);
    // V3.12：彻底删除这件物品 = 它的一切痕迹都没了 → 同名流水一并清掉。
    _discards.removeWhere(
        (d) => d.itemId == id || (name != null && d.itemName == name));
  }

  @override
  Future<void> purgeAll() async {
    final ids = _items.where((i) => i.isDeleted).map((i) => i.id!).toList();
    _items.removeWhere((i) => i.isDeleted);
    _links.removeWhere((l) => ids.contains(l.itemId));
    // V3.12：清空回收站级联清流水（元宝批复第 6 条）。
    _discards.clear();
  }

  // ---------- V3.12 部分废弃：内存实现与生产同语义 ----------

  /// V3.12：部分废弃——只扣指定位置，写一条流水；废完则转整件废弃。
  @override
  Future<DiscardOutcome> discardQuantity(
    String itemName,
    int quantity, {
    required int locationId,
    DiscardSource sourceType = DiscardSource.inStock,
  }) async {
    final key = normalizeName(itemName);
    final hit = _items.where((i) => i.name == key && !i.isDeleted).firstOrNull;
    if (hit == null) {
      throw ArgumentError.value(itemName, 'itemName', '还没记录过「$key」');
    }
    final itemId = hit.id!;
    final locName = _locations
        .where((l) => l.id == locationId)
        .map((l) => l.name)
        .firstOrNull;
    if (locName == null) {
      throw ArgumentError.value(locationId, 'locationId', '位置不存在或已删除');
    }
    final locQty = _locationQty(itemId, locationId);
    if (locQty < quantity) {
      throw ArgumentError.value(quantity, 'quantity',
          '$locName 只有 $locQty 个，不够废弃 $quantity 个');
    }
    final stock = hit.quantity;
    if (stock < quantity) {
      throw ArgumentError.value(quantity, 'quantity',
          '「$key」一共只有 $stock 个，不够废弃 $quantity 个');
    }
    if (stock == quantity) {
      await deleteItem(itemId);
      return DiscardOutcome(
        itemName: key,
        quantity: quantity,
        wholeItem: true,
        locationName: locName,
      );
    }
    _writeLocationQty(itemId, locationId, locQty - quantity);
    _syncTotal(itemId);
    _discards.add(ItemDiscard(
      id: ++_discardId,
      itemId: itemId,
      itemName: key,
      quantity: quantity,
      locationId: locationId,
      locationName: locName,
      discardedAt: DateTime.now().millisecondsSinceEpoch,
      sourceType: sourceType,
      restoredQuantity: 0,
    ));
    final remaining = _items
        .where((i) => i.id == itemId)
        .map((i) => i.quantity)
        .firstOrNull ??
        0;
    return DiscardOutcome(
      itemName: key,
      quantity: quantity,
      wholeItem: false,
      locationName: locName,
      remainingInStock: remaining,
    );
  }

  @override
  Future<ItemDiscard> restoreDiscard(int discardId, int toLocationId,
      {int? quantity}) async {
    final idx = _discards.indexWhere((d) => d.id == discardId);
    if (idx < 0) {
      throw ArgumentError.value(discardId, 'discardId', '找不到这条废弃记录');
    }
    final old = _discards[idx];
    final pending = old.pendingQuantity;
    if (pending <= 0) {
      throw ArgumentError.value(
          discardId, 'discardId', '这条废弃记录已经全部恢复过了');
    }
    final want = quantity ?? pending;
    if (want < 1 || want > pending) {
      throw ArgumentError.value(quantity, 'quantity',
          '要恢复的数量必须在 1 ~ $pending 之间');
    }
    final item = _items.where((i) => i.id == old.itemId).firstOrNull;
    if (item == null || item.isDeleted) {
      throw ArgumentError.value(discardId, 'discardId',
          '「${old.itemName}」已整体进回收站，请先恢复物品再恢复这几个');
    }
    final locName = _locations
        .where((l) => l.id == toLocationId)
        .map((l) => l.name)
        .firstOrNull;
    if (locName == null) {
      throw ArgumentError.value(toLocationId, 'toLocationId', '位置不存在或已删除');
    }
    final cur = _locationQty(old.itemId, toLocationId);
    _writeLocationQty(old.itemId, toLocationId, cur + want);
    _syncTotal(old.itemId);
    _discards[idx] = ItemDiscard(
      id: old.id,
      itemId: old.itemId,
      itemName: old.itemName,
      quantity: old.quantity,
      locationId: old.locationId,
      locationName: old.locationName,
      discardedAt: old.discardedAt,
      sourceType: old.sourceType,
      restoredQuantity: old.restoredQuantity + want,
    );
    return _discards[idx];
  }

  @override
  Future<List<ItemDiscard>> getDiscards({bool includeRestored = false}) async {
    if (includeRestored) return List<ItemDiscard>.from(_discards);
    return _discards.where((d) => d.pendingQuantity > 0).toList();
  }

  @override
  Future<void> purgeDiscard(int discardId) async {
    _discards.removeWhere((d) => d.id == discardId);
  }

  @override
  Future<UpsertResult> upsertItemLocation(String itemName, int locationId,
      {String? rawText, int? quantity, bool additive = false}) async {
    final key = normalizeName(itemName);
    // 与生产一致（_findOrCreateItem 只查 is_deleted=0）：同名软删行不阻止新建，
    // 否则「删除后重建同名」在测试里会复活旧行，测不出 V3.9 的合并口径。
    final itemId = _findOrCreateItem(key);
    // V3.11：数量写在**位置关联**上，其他位置不动；items.quantity 只做
    // SUM 缓存，由 _syncTotal 统一收口。
    final exists = _links.any(
      (l) =>
          l.itemId == itemId && l.locationId == locationId && !l.isDeleted,
    );
    if (exists) {
      if (quantity != null) {
        final cur = _locationQty(itemId, locationId);
        final next = additive ? cur + quantity : quantity;
        if (next < 0) {
          throw ArgumentError.value(next, 'quantity', '位置数量不能为负');
        }
        _writeLocationQty(itemId, locationId, next);
      }
      _syncTotal(itemId);
      return UpsertResult(itemId: itemId, locationId: locationId, created: false);
    }
    _writeLocationQty(itemId, locationId, quantity ?? 1);
    _syncTotal(itemId);
    return UpsertResult(itemId: itemId, locationId: locationId, created: true);
  }

  /// V3.10：数量写入（覆盖 / 累加），语义与生产一致。
  void _applyQuantity(int itemId, int quantity, bool additive) {
    final idx = _items.indexWhere((i) => i.id == itemId);
    if (idx < 0) return;
    final cur = _items[idx].quantity;
    // V3.10：累加以当前在库数为基准，不再拿在借数兜底。
    final newQty = additive ? cur + quantity : quantity;
    _items[idx] = Item(
      id: _items[idx].id,
      name: _items[idx].name,
      createdAt: _items[idx].createdAt,
      updatedAt: _items[idx].updatedAt,
      quantity: newQty,
    );
  }

  /// V3.10：只改数量、不动位置（与生产一致）。
  @override
  Future<int> setItemQuantity(String itemName, int quantity,
      {bool additive = false}) async {
    final key = normalizeName(itemName);
    final hit = _items.where((i) => i.name == key && !i.isDeleted).firstOrNull;
    if (hit == null) {
      throw ArgumentError.value(
        key,
        'itemName',
        '还没记录过「$key」，先说一句「$key放阳台」再记数量',
      );
    }
    final itemId = hit.id!;
    final cur = hit.quantity;
    final target = additive ? cur + quantity : quantity;
    final delta = target - cur;
    final mainId = _mainLocationId(itemId);
    if (mainId != 0) {
      final mainQty = _locationQty(itemId, mainId);
      final nextQty = mainQty + delta;
      if (nextQty < 0) {
        throw ArgumentError.value(
            quantity, 'quantity', '主位置数量不够减，请用「校准数量」逐位置清点');
      }
      _writeLocationQty(itemId, mainId, nextQty);
    } else {
      _applyQuantity(itemId, quantity, additive);
    }
    return _syncTotal(itemId);
  }

  /// V3.11：只改某个位置的数量（弹窗里选了「某位置 N 个」）。
  @override
  Future<int> setLocationQuantity(
    String itemName,
    int locationId,
    int quantity, {
    bool additive = false,
  }) async {
    final key = normalizeName(itemName);
    final hit = _items.where((i) => i.name == key && !i.isDeleted).firstOrNull;
    if (hit == null) {
      throw ArgumentError.value(key, 'itemName', '还没记录过「$key」');
    }
    final cur = _locationQty(hit.id!, locationId);
    final next = additive ? cur + quantity : quantity;
    if (next < 0) {
      throw ArgumentError.value(next, 'quantity', '位置数量不能为负');
    }
    _writeLocationQty(hit.id!, locationId, next);
    return _syncTotal(hit.id!);
  }

  /// V3.10：该物品未归还的借出总数。
  int _outstandingLent(int itemId) {
    var total = 0;
    for (final loan in _loans) {
      if (loan.itemId != itemId) continue;
      if (loan.isDeleted) continue;
      if (loan.returnedQty >= loan.quantity) continue;
      total += loan.quantity - loan.returnedQty;
    }
    return total;
  }

  @override
  Future<QuantityInfo> getQuantityInfo(String itemName) async {
    final key = normalizeName(itemName);
    final hit = _items.where((i) => i.name == key && !i.isDeleted).firstOrNull;
    if (hit == null) {
      return const QuantityInfo(stock: 0, lent: 0, available: 0);
    }
    final lent = _outstandingLent(hit.id!);
    final stock = hit.quantity;
    return QuantityInfo(stock: stock, lent: lent, available: stock);
  }

  @override
  Future<Map<int, QuantityInfo>> getAllQuantityInfo() async {
    final result = <int, QuantityInfo>{};
    for (final item in _items.where((i) => !i.isDeleted)) {
      final lent = _outstandingLent(item.id!);
      final stock = item.quantity;
      result[item.id!] = QuantityInfo(
        stock: stock,
        lent: lent,
        available: stock,
      );
    }
    return result;
  }

  @override
  Future<CalibrationReport> calibrateQuantities({
    Map<int, int> totals = const <int, int>{},
    Map<int, Map<int, int>> locationTotals = const <int, Map<int, int>>{},
  }) async {
    // 与生产一致：输入「家里一共几个」，写入在库数 = 总数 − 在借数。
    var changed = 0;
    final details = <String>[];
    // V3.11：按位置分别清点——每个位置写自己的数量，统一 _syncTotal 收口。
    for (final entry in locationTotals.entries) {
      final itemId = entry.key;
      final item = _items
          .where((i) => i.id == itemId && !i.isDeleted)
          .firstOrNull;
      if (item == null) continue;
      for (final pos in entry.value.entries) {
        if (pos.value < 0) continue;
        _writeLocationQty(itemId, pos.key, pos.value);
      }
      final stockCounted = entry.value.values.fold<int>(0, (a, b) => a + b);
      final lent = _outstandingLent(itemId);
      changed++;
      details.add('${item.name}：加起来 $stockCounted 个 · 在借 $lent 个'
          ' · 一共 ${stockCounted + lent} 个');
    }
    if (locationTotals.isNotEmpty) {
      return CalibrationReport(changedCount: changed, details: details);
    }
    for (var idx = 0; idx < _items.length; idx++) {
      final item = _items[idx];
      if (item.isDeleted) continue;
      final counted = totals[item.id!];
      if (counted == null) continue;
      final lent = _outstandingLent(item.id!);
      if (counted < lent) {
        details.add('${item.name}：清点 $counted 个，比在借的 $lent 个还少，已跳过');
        continue;
      }
      final newStock = counted - lent;
      if (newStock != item.quantity) {
        _items[idx] = Item(
          id: item.id,
          name: item.name,
          createdAt: item.createdAt,
          updatedAt: item.updatedAt,
          quantity: newStock,
        );
        changed++;
        details.add('${item.name}：共 $counted 个 − 在借 $lent 个 → 在库 $newStock 个'
            '（原记录 ${item.quantity} 个）');
      }
    }
    return CalibrationReport(changedCount: changed, details: details);
  }

  /// V3.11：旧名只作整体挪兼容，不再接受 quantity/additive 分流。
  @override
  Future<MoveResult> moveItem(String itemName, int locationId,
      {String? rawText}) => moveItemWhole(itemName, locationId, rawText: rawText);

  /// 整体挪：旧位置软删留底，目标位置拿全部数量，总数不变。
  /// 物品不存在则新建——「梯子放阳台」首次录入走的就是这条路。
  @override
  Future<MoveResult> moveItemWhole(String itemName, int toLocationId,
      {String? rawText}) async {
    final key = normalizeName(itemName);
    final itemId = _findOrCreateItem(key);
    final before = _readStock(itemId);
    final previous = <String>[];
    for (final l in _links
        .where((l) =>
            l.itemId == itemId && l.locationId != toLocationId && !l.isDeleted)
        .toList()) {
      final name = _locations
          .where((loc) => loc.id == l.locationId && !loc.isDeleted)
          .map((loc) => loc.name)
          .firstOrNull;
      if (name != null) previous.add(name);
      _softDeleteLink(l);
    }
    final targetExists = _links.any((l) =>
        l.itemId == itemId && l.locationId == toLocationId && !l.isDeleted);
    _writeLocationQty(itemId, toLocationId, before);
    final total = _syncTotal(itemId);
    return MoveResult(
      itemId: itemId,
      locationId: toLocationId,
      created: !targetExists,
      previousLocations: previous,
      quantity: total,
      quantityChanged: total != before,
    );
  }

  /// 部分挪：源位减、目标位加，总数不变；源位不足如实报错。
  @override
  Future<MoveResult> moveItemPartial(
    String itemName,
    int fromLocationId,
    int toLocationId, {
    required int quantity,
    String? rawText,
  }) async {
    final key = normalizeName(itemName);
    final hit = _items.where((i) => i.name == key && !i.isDeleted).firstOrNull;
    if (hit == null) {
      throw ArgumentError.value(key, 'itemName', '还没记录过「$key」');
    }
    if (quantity < 1) {
      throw ArgumentError.value(quantity, 'quantity', '挪动数量至少为 1');
    }
    final itemId = hit.id!;
    final fromQty = _locationQty(itemId, fromLocationId);
    if (fromQty < quantity) {
      final fromName = _locations
          .where((l) => l.id == fromLocationId)
          .map((l) => l.name)
          .firstOrNull ?? '这个位置';
      throw ArgumentError.value(
        quantity,
        'quantity',
        '$fromName只有 $fromQty 个，不够挪 $quantity 个。'
        '请说个更小的数，或先补货再挪。',
      );
    }
    final before = _readStock(itemId);
    _writeLocationQty(itemId, fromLocationId, fromQty - quantity);
    _writeLocationQty(itemId, toLocationId,
        _locationQty(itemId, toLocationId) + quantity);
    final total = _syncTotal(itemId);
    final fromName = _locations
        .where((l) => l.id == fromLocationId)
        .map((l) => l.name)
        .firstOrNull ?? '原位置';
    return MoveResult(
      itemId: itemId,
      locationId: toLocationId,
      created: fromQty == quantity,
      previousLocations: <String>[fromName],
      quantity: total,
      quantityChanged: total != before,
    );
  }

  /// V3.11：读在库数——items.quantity 是 SUM 缓存，不再拿在借数兜底。
  int _readStock(int itemId) {
    final hit = _items.where((i) => i.id == itemId).firstOrNull;
    return hit?.quantity ?? 0;
  }

  /// 活跃位置数量表，供 UI 回显「阳台 2 个、客厅 1 个」。
  Map<int, int> _locationQtyMap(int itemId) => <int, int>{
        for (final l in _links)
          if (l.itemId == itemId && !l.isDeleted) l.locationId: l.quantity,
      };

  @override
  Future<ItemWithLocations?> findByName(String name) async {
    final key = normalizeName(name);
    // 与生产一致：只查活跃物品（软删的在回收站，不算"记录过"）。
    final item = _items.where((i) => i.name == key && !i.isDeleted).toList();
    if (item.isEmpty) return null;
    // V3.11：软删关联是历史留底，不能出现在当前位置查询里。
    final locationIds = _links
        .where((l) => l.itemId == item.first.id && !l.isDeleted)
        .map((l) => l.locationId)
        .toList();
    final locations = _locations
        .where((l) => locationIds.contains(l.id))
        .toList(growable: false);
    return ItemWithLocations(
      item: item.first,
      locations: locations,
      locationQuantities: _locationQtyMap(item.first.id!),
    );
  }

  @override
  Future<List<ItemWithLocations>> getAllItemsWithLocations() async {
    final items = _items
        .where((i) => !i.isDeleted)
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return <ItemWithLocations>[
      for (final item in items)
        ItemWithLocations(
          item: item,
          locations: _locations
              .where((l) =>
                  !l.isDeleted &&
                  _links.any((link) =>
                      !link.isDeleted &&
                      link.itemId == item.id &&
                      link.locationId == l.id))
              .toList(growable: false),
          locationQuantities: _locationQtyMap(item.id!),
        ),
    ];
  }

  Map<String, Object?>? lastExportedBackup;
  Map<String, Object?>? lastRestoredBackup;

  @override
  Future<Map<String, Object?>> exportBackup() async {
    lastExportedBackup = <String, Object?>{
      'app': 'home_inventory',
      'schemaVersion': 5,
      'items': _items.map((i) => i.toMap()).toList(),
      'locations': _locations.map((l) => l.toMap()).toList(),
      'item_locations': _links.map((l) => l.toMap()).toList(),
    };
    return lastExportedBackup!;
  }

  @override
  Future<void> restoreBackup(Map<String, Object?> data) async {
    lastRestoredBackup = data;
  }

  int get linkCount => _links.length;
  int get locationCount => _locations.length;
}

void main() {
  late InMemoryRepository repo;

  // V3 交互说明文案（测试按模板生成期望值，不写死样例值）。
  const notUnderstood = '没听懂，试试"XX放阳台"或"XX在哪"';
  String notFound(String item) => '暂未记录该物品：$item。';
  String recorded(String item, String location) => '已记下：$item → $location';
  String alreadyRecorded(String item, String location) =>
      '「$item」已经在「$location」了。';
  // （V3.4：locationAdded/emptyLocation 文案常量随首页手动添加入口
  // 撤下移除，相关场景迁移至位置管理页测试。）

  setUp(() {
    repo = InMemoryRepository();
  });

  // Step 0 等价断言：直接证明内存仓储的归一化与生产共用 helper 一致，
  // 不经过 UI。N2/N4 依赖的前提由此从「推断」变为「实测」。
  test('Step0 归一化等价：全角/带空格输入经内存仓储落成归一化名', () async {
    final id = await repo.addLocation('　ＡＢＣ　');
    final locations = await repo.getAllLocations();
    expect(locations, hasLength(1));
    expect(locations.single.name, normalizeName('　ＡＢＣ　'));
    expect(locations.single.name, 'abc');
    expect(locations.single.id, id);
  });

  Future<void> pumpApp(WidgetTester tester) {
    return tester.pumpWidget(MaterialApp(home: HomePage(repository: repo)));
  }

  /// pump 一帧让 async 微任务与 rebuild 完成。
  /// 内存仓储无真实 I/O，无需 runAsync（headless 下 runAsync 会死锁）。
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
  }

  Future<void> submit(WidgetTester tester, String phrase) async {
    await tester.enterText(find.byKey(const Key('phrase_field')), phrase);
    await tester.pump(); // 让 onChanged 刷新「确定」按钮的禁用态
    await tester.tap(find.byKey(const Key('submit_button')));
    await settle(tester);
  }

  /// V3.10 复验修复：归还后弹「放回哪儿」，测试统一点「先不改」沿用原位置。
  Future<void> keepReturnLocation(WidgetTester tester) async {
    final dialog = find.byKey(const Key('return_location_dialog'));
    if (dialog.evaluate().isEmpty) return;
    await tester.tap(find.byKey(const Key('return_location_skip')));
    await settle(tester);
  }

  testWidgets('V3.3：右上角列表图标不复存在，明细页经抽屉可达', (tester) async {
    await pumpApp(tester);
    await settle(tester);

    // V3.3 决策点①：右上角 V1 遗留图标撤下，入口统一三道杠。
    expect(find.byKey(const Key('open_item_list')), findsNothing);
    expect(find.byKey(const Key('open_drawer')), findsOneWidget);

    // 明细页仍经抽屉可达（链路回归）。
    await tester.tap(find.byKey(const Key('open_drawer')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drawer_items')));
    await tester.pumpAndSettle();
    expect(find.text('物品明细'), findsOneWidget);
    expect(find.byKey(const Key('detail_search')), findsOneWidget);
    expect(find.textContaining('还没有记录'), findsOneWidget,
        reason: '空库空态');

    // 返回首页仍正常。
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('phrase_field')), findsOneWidget);
  });

  /// V3.4：首页手动添加入口已撤下，手动添加统一走
  /// 抽屉 → 位置管理页 → FAB → 对话框；完成后返回首页。
  Future<void> addLocationViaDrawer(WidgetTester tester, String name) async {
    await tester.tap(find.byKey(const Key('open_drawer')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drawer_locations')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add_location_fab')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('location_name_field')), name);
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    // 返回首页（位置页为 push 进入的独立路由）。
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('phrase_field')), findsOneWidget);
  }

  // ============ 6 条原有回归用例（保留意图，改为单句式驱动 + 冻结文案）============

  testWidgets('新增位置→录入→按精确名称能查到', (tester) async {
    await pumpApp(tester);
    await addLocationViaDrawer(tester, '阳台');
    // 手动添加落库后回到首页，「已添加位置」提示归位置页职责（V3.4），
    // 此处断言库内状态。
    expect(repo.locationCount, 1);

    await submit(tester, '梯子放阳台');
    expect(find.text(recorded('梯子', '阳台')), findsOneWidget);

    await submit(tester, '梯子在哪');
    expect(find.text('「梯子」在：阳台（共1处）。'), findsOneWidget);
    expect(find.byKey(const Key('result_location_1')), findsOneWidget);
    expect(find.textContaining('暂未记录'), findsNothing);
  });

  testWidgets('连点两下记下只产生一条关联', (tester) async {
    await pumpApp(tester);
    await submit(tester, '梯子放阳台');
    // 第一次：断言「已记下」确实出现过（建立对比基线）。
    expect(find.text(recorded('梯子', '阳台')), findsOneWidget);

    await submit(tester, '梯子放阳台');
    // 第二次：走幂等分支，只显示「已记过」；第一次的「已记下」被覆盖，
    // 不得两条并存——否则文案分支判定错误（DeepSeek 第92轮圈点）。
    expect(repo.linkCount, 1);
    expect(repo.locationCount, 1);
    expect(find.text(alreadyRecorded('梯子', '阳台')), findsOneWidget);
    expect(find.text(recorded('梯子', '阳台')), findsNothing);
  });

  testWidgets('空库查询显示没有记录且不报错', (tester) async {
    await pumpApp(tester);
    await submit(tester, '梯子在哪');

    expect(find.text(notFound('梯子')), findsOneWidget);
  });

  testWidgets('空输入时确定按钮禁用、零写入（文档验收场景5）', (tester) async {
    await pumpApp(tester);
    // 空输入：「确定」禁用，tap 无响应。
    final button = tester.widget<FilledButton>(find.byKey(const Key('submit_button')));
    expect(button.onPressed, isNull, reason: '空输入时确定须禁用');
    await tester.tap(find.byKey(const Key('submit_button')));
    await settle(tester);
    expect(repo.linkCount, 0);
    expect(find.text(notUnderstood), findsNothing);
  });

  testWidgets('挪位：同物品再记新位置替换旧位置（V3.2 语义）', (tester) async {
    await pumpApp(tester);
    await submit(tester, '梯子放阳台');

    await submit(tester, '梯子放储物间');
    expect(find.textContaining('已更新：梯子 → 储物间（原位置：阳台）'),
        findsOneWidget,
        reason: 'V3.2 起再记即挪位，旧位置软删');

    await submit(tester, '梯子在哪');
    expect(find.text('「梯子」在：储物间（共1处）。'), findsOneWidget);
    expect(find.byKey(const Key('result_location_2')), findsOneWidget,
        reason: '储物间是第 2 个创建的位置（id=2）');
    expect(find.text('阳台'), findsNothing, reason: '旧位置不再列出');
  });

  testWidgets('挪位：动词「挪到」也走替换语义（梯子挪到客厅）', (tester) async {
    await pumpApp(tester);
    await submit(tester, '梯子放阳台');

    await submit(tester, '梯子挪到客厅');
    // V3.11（元宝批复④）：「挪」必须明说整体挪、数量不变，
    // 不能让用户以为只挪了一个（旧「已更新」文案已废弃）。
    expect(find.textContaining('已整体把「梯子」挪到'), findsOneWidget);
    expect(find.textContaining('总数不变'), findsOneWidget);

    await submit(tester, '梯子在哪');
    expect(find.text('「梯子」在：客厅（共1处）。'), findsOneWidget);
  });

  testWidgets('挪位：重复记同一位置不提示原位置（幂等）', (tester) async {
    await pumpApp(tester);
    await submit(tester, '梯子放阳台');
    await submit(tester, '梯子放阳台');
    expect(find.text('「梯子」已经在「阳台」了。'), findsOneWidget);
  });

  testWidgets('精确名称不通配：查「梯」找不到「梯子」', (tester) async {
    await pumpApp(tester);
    await submit(tester, '梯子放阳台');

    await submit(tester, '梯在哪');
    expect(find.text(notFound('梯')), findsOneWidget);
    expect(find.textContaining('「梯子」在：'), findsNothing);
  });

  // ============ 6 条新增用例（自动新建 / 归一化驱动 / 幂等 / 同源 / 提示分开）============

  testWidgets('N1 句式录入新位置自动新建并关联', (tester) async {
    await pumpApp(tester);
    // 前置：库里没有任何位置（未点 add_location_button）。
    expect(repo.locationCount, 0);

    await submit(tester, '梯子放阳台');

    expect(find.text(recorded('梯子', '阳台')), findsOneWidget);
    expect(repo.locationCount, 1);
    expect(repo.linkCount, 1);
    final locations = await repo.getAllLocations();
    expect(locations.single.name, '阳台');
  });

  testWidgets('N2 自动新建由归一化结果驱动（全角+空格）', (tester) async {
    await pumpApp(tester);
    await submit(tester, '梯子放　ＡＢＣ　');

    final locations = await repo.getAllLocations();
    expect(locations.single.name, 'abc'); // 全角转半角 + lower + trim
    expect(repo.locationCount, 1);
  });

  testWidgets('N2b 添加位置名为空走专属文案，非没听懂（V3.4 场景迁移至位置管理页）', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('open_drawer')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drawer_locations')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add_location_fab')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('location_name_field')), '   ');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    // 空名 →「位置名称不能为空」SnackBars，且不得显示「没听懂」、零写入。
    expect(find.text('位置名称不能为空。'), findsOneWidget);
    expect(find.text(notUnderstood), findsNothing);
    expect(repo.locationCount, 0);
  });

  testWidgets('N3 重复录入同一新位置幂等、无 UI 旁路', (tester) async {
    await pumpApp(tester);
    await submit(tester, '梯子放阳台');
    await submit(tester, '梯子放阳台');

    expect(repo.locationCount, 1);
    expect(repo.linkCount, 1);
  });

  testWidgets('N4 显式添加位置与句式录入同源：位置表、关联表各恰好1条', (tester) async {
    await pumpApp(tester);
    // 显式入口（V3.4 起在位置管理页）添加全角位置名 → 归一化落库。
    await addLocationViaDrawer(tester, '　ＡＢＣ　');
    expect(repo.locationCount, 1);

    // 句式录入到同一位置（归一化后同为 abc）。
    await submit(tester, '梯子放abc');

    // 两处分别断言，精确同源。
    final locations = await repo.getAllLocations();
    expect(locations, hasLength(1)); // 位置表恰好 1 条
    expect(locations.single.name, 'abc');
    expect(repo.linkCount, 1); // 关联表恰好 1 条
  });

  testWidgets('N5 两种提示分开且没听懂零写入', (tester) async {
    await pumpApp(tester);
    // 句式不合规 → 没听懂，且无任何写入。
    await submit(tester, '梯子呢');
    expect(find.text(notUnderstood), findsOneWidget);
    expect(repo.linkCount, 0);
    expect(repo.locationCount, 0);
    final locations = await repo.getAllLocations();
    expect(locations, isEmpty);

    // 句式合法但查不到 → 没有记录（与没听懂不混）。
    await submit(tester, '梯子在哪');
    expect(find.text(notFound('梯子')), findsOneWidget);
    expect(find.text(notUnderstood), findsNothing);
  });

  testWidgets('N6 V2倒装与介词口语现在录入成功且位置不重复', (tester) async {
    // 契约变更 CR-V2-R1：V1 这两句判没听懂、零写入；V2 方案 C 认倒装与介词变体。
    await pumpApp(tester);

    await submit(tester, '我把梯子放阳台了');
    expect(find.text(recorded('梯子', '阳台')), findsOneWidget);
    expect(find.text(notUnderstood), findsNothing);
    expect(repo.locationCount, 1);
    expect(repo.linkCount, 1);

    // 第二句同物同位的口语变体（放到=放），应走「已经记过」分支，不重复建位置/关联。
    await submit(tester, '梯子放到阳台');
    expect(find.text(alreadyRecorded('梯子', '阳台')), findsOneWidget);
    expect(find.text(notUnderstood), findsNothing);
    expect(repo.locationCount, 1);
    expect(repo.linkCount, 1);
  });

  testWidgets('N7 语序非法输入判没听懂且零写入（叠用倒装/多动词）',
      (tester) async {
    // 审查需改点1：规则层能确定非法的语序必须拦住，且不产生任何脏数据。
    await pumpApp(tester);

    for (final phrase in const <String>[
      '我把把梯子放阳台', // 叠用倒装
      '梯子搁阳台放厨房', // 多动词连写
      '梯子和阳台', // 无放置动词
    ]) {
      await submit(tester, phrase);
      expect(find.text(notUnderstood), findsOneWidget, reason: phrase);
      expect(repo.locationCount, 0, reason: phrase);
      expect(repo.linkCount, 0, reason: phrase);
    }
    expect(await repo.getAllLocations(), isEmpty);
  });

  // ---- 文档验收场景（端到端 UI）----

  testWidgets('验收2：记：螺丝放厨房抽屉 → 正确入库并提示成功', (tester) async {
    await pumpApp(tester);
    await submit(tester, '记：螺丝放厨房抽屉');
    expect(find.text(recorded('螺丝', '厨房抽屉')), findsOneWidget);
    expect(repo.linkCount, 1);
  });

  testWidgets('验收3：查：螺丝 → 返回厨房抽屉', (tester) async {
    await pumpApp(tester);
    await submit(tester, '记：螺丝放厨房抽屉');
    await submit(tester, '查：螺丝');
    expect(find.textContaining('「螺丝」在：厨房抽屉'), findsOneWidget);
    expect(find.text(notFound('螺丝')), findsNothing);
  });

  testWidgets('验收4：添加新位置车库 → 可被后续记录引用', (tester) async {
    await pumpApp(tester);
    await addLocationViaDrawer(tester, '车库');
    expect(repo.locationCount, 1);
    await submit(tester, '电钻放车库');
    expect(find.text(recorded('电钻', '车库')), findsOneWidget);
    expect(repo.linkCount, 1);
  });

  testWidgets('验收7：页面无 DIAG/DIAG6 调试标记与内部代号残留', (tester) async {
    await pumpApp(tester);
    expect(find.textContaining('DIAG'), findsNothing);
    expect(find.textContaining('755b329'), findsNothing);
    expect(find.textContaining('TRACE MARK'), findsNothing);
  });

  // 技术审核条件①：语音隐私弱提示常驻可见。
  // V3.3：文案去技术味（口径不变：12px 灰色、常驻展示）。
  testWidgets('弱提示：语音由系统输入法处理 常驻显示', (tester) async {
    await pumpApp(tester);
    expect(find.byKey(const Key('voice_hint')), findsOneWidget);
    expect(find.text('语音由系统输入法处理'), findsOneWidget);
    expect(find.text('语音由当前输入法处理'), findsNothing,
        reason: '旧文案不复存在');
  });

  // ---- V3.1 导航：抽屉菜单 + 兜底文字入口 ----

  testWidgets('抽屉：汉堡按钮打开，四项菜单齐全', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('open_drawer')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home_drawer')), findsOneWidget);
    expect(find.text('语音记账'), findsOneWidget);
    expect(find.text('位置管理'), findsOneWidget);
    expect(find.text('物品明细'), findsOneWidget);
    expect(find.text('数据备份与恢复'), findsOneWidget);
  });

  testWidgets('抽屉：点「物品明细」进入明细页（底部操作区可见）', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('open_drawer')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drawer_items')));
    await tester.pumpAndSettle();

    expect(find.text('物品明细'), findsOneWidget);
    expect(find.byKey(const Key('detail_search')), findsOneWidget);
    // 底部操作区两个按钮都在明细页内。
    expect(find.byKey(const Key('export_backup')), findsOneWidget);
    expect(find.byKey(const Key('restore_backup')), findsOneWidget);
  });

  testWidgets('抽屉：点「位置管理」进入位置页', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('open_drawer')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drawer_locations')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('add_location_fab')), findsOneWidget);
    expect(find.textContaining('还没有位置'), findsOneWidget,
        reason: '空库显示空态引导');
  });

  testWidgets('抽屉：点「数据备份与恢复」进入备份页', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('open_drawer')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drawer_backup')));
    await tester.pumpAndSettle();

    expect(find.text('数据备份与恢复'), findsOneWidget);
    expect(find.byKey(const Key('export_backup')), findsOneWidget);
  });

  // ---- V3.3 导航收敛 ----

  testWidgets('V3.3：底部兜底按钮不复存在，静态引导文字不可点', (tester) async {
    await pumpApp(tester);

    // 决策点②：兜底按钮撤下，原位置留静态引导文字。
    expect(find.byKey(const Key('home_menu_fallback')), findsNothing,
        reason: 'home_menu_fallback 整块移除');
    final hint = tester.widget<Text>(
      find.byKey(const Key('home_menu_hint')),
    );
    expect(hint.data, '管理物品 / 位置 / 备份：点左上角 ☰ 菜单');

    // 静态文字无任何点击响应：tap 后抽屉不展开。
    // V3.9 加固：这一条用屏幕坐标 tap，而首页高度会随「句式标准」卡片
    // 增减变化，坐标漂到别处会造成偶发失败（并行跑全量时更易触发）。
    // tap 前先确保该文字在视口内，去掉对绝对坐标的依赖。
    final hintFinder = find.byKey(const Key('home_menu_hint'));
    await tester.ensureVisible(hintFinder);
    await tester.pumpAndSettle();
    await tester.tap(hintFinder);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home_drawer')), findsNothing,
        reason: '引导文字禁止添加点击响应（审核补充提醒）');
  });

  testWidgets('V3.3：首页左边缘右滑唤醒抽屉', (tester) async {
    await pumpApp(tester);

    // Scaffold drawer 原生手势：从屏幕左缘水平拖入。
    await tester.dragFrom(const Offset(1, 300), const Offset(400, 0));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home_drawer')), findsOneWidget);
    expect(find.text('语音记账'), findsOneWidget);
    expect(find.text('物品明细'), findsOneWidget);
  });

  // ---- V3.4 首页交互收敛 + 三道杠可见性 ----

  testWidgets('V3.4：「管理位置」整块不复存在（输入框/按钮/标题/分隔线）',
      (tester) async {
    await pumpApp(tester);

    // 审核拍板：按代码实际 key 撤除（需求单 home_query_field/
    // home_add_location_field 不存在，笔误已按代码修正）。
    expect(find.byKey(const Key('new_location_field')), findsNothing);
    expect(find.byKey(const Key('add_location_button')), findsNothing);
    expect(find.text('管理位置'), findsNothing);
    expect(find.text('东西在哪里？'), findsNothing);
    expect(find.text('添加位置'), findsNothing);
    expect(find.byType(Divider), findsNothing,
        reason: '中间分隔线随「管理位置」一并撤除，不留占位');
  });

  testWidgets('V3.4：首页仅剩顶部一个输入控件（说一句）', (tester) async {
    await pumpApp(tester);

    expect(find.byType(TextField), findsOneWidget,
        reason: '首页无其他手动添加/查询入口残留');
    expect(find.byKey(const Key('phrase_field')), findsOneWidget);
  });

  testWidgets('V3.4.1：三道杠可见性锁定（深色 AppBar 底 + 亮色图标）',
      (tester) async {
    await pumpApp(tester);

    // PM 修订方向：AppBar 反转——深绿底 + 白配绿对比拉满。
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    final appBar = scaffold.appBar as AppBar;
    final theme = Theme.of(tester.element(find.byType(Scaffold).first));
    expect(appBar.backgroundColor, theme.colorScheme.primary,
        reason: 'AppBar 深色底（主题绿）');
    expect(appBar.foregroundColor, theme.colorScheme.onPrimary,
        reason: '标题亮色');
    final button = tester.widget<IconButton>(
      find.byKey(const Key('open_drawer')),
    );
    expect(button.color, Colors.white, reason: '按钮设色白色');
    expect(button.iconSize, 28, reason: '视觉尺寸较默认 24 增大');
    // V3.5.1 真机缺陷修复：颜色直接写死在 Icon 本体（不再依赖
    // M3 样式继承链），断言锁最终渲染的 Icon 而非仅参数值。
    final icon = tester.widget<Icon>(find.byIcon(Icons.menu));
    expect(icon.color, Colors.white,
        reason: '白色图标在深绿底上对比最大，真机可见（两轮缺陷后改锁渲染本体）');
    expect(icon.size, 28);
    // 点击展开（功能链路继续有效）。
    await tester.tap(find.byKey(const Key('open_drawer')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home_drawer')), findsOneWidget);
  });

  testWidgets('V3.4.1：首屏示例引导文案展示', (tester) async {
    await pumpApp(tester);
    expect(find.byKey(const Key('sample_hint')), findsOneWidget);
    expect(find.text('试试说：梯子放阳台，或：梯子在哪'), findsOneWidget);
  });

  testWidgets('V3.4：键盘弹起态顶部三道杠不被裁切、仍可点击', (tester) async {
    await pumpApp(tester);

    // 键盘弹起（聚焦顶部输入框）后再点三道杠，抽屉必须能打开。
    await tester.enterText(find.byKey(const Key('phrase_field')), '梯子放阳台');
    await tester.pump();
    await tester.tap(find.byKey(const Key('open_drawer')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home_drawer')), findsOneWidget,
        reason: 'AppBar 位于 Scaffold 顶部，键盘弹起不裁切、热区可用');
  });

  // ---------- V3.5 一级模块底栏导航骨架（V4.1 批次 4：五项 → 四项）----------

  testWidgets('V4.2.0：底栏渲染 3 个一级模块按钮（知识库提平顶栏第四域后，生活区底栏三栏）',
      (tester) async {
    await pumpApp(tester);

    expect(find.byKey(const Key('home_bottom_nav')), findsOneWidget);
    expect(find.text('仓储'), findsOneWidget);
    // V4.1 批次 4（PM 拍板「生活区底栏 5→4」）：
    // 「日程」不再占生活区底栏——它上移到概览层的「日程」签（跨域展示 + 可编辑）。
    expect(find.text('日程'), findsNothing,
        reason: '日程上移概览层，生活区底栏没有日程');
    // V4.2.0（PM 2026-11-28 拍板「顶栏四栏 + 生活区底栏三栏」）：
    // 「知识库」撤下底栏——提平为顶栏第四栏「知识」独立域。
    expect(find.text('知识库'), findsNothing,
        reason: '知识库提平为顶栏知识域，不占底栏');
    // 底栏三栏按 PM 原话顺序：仓储 / 衣橱 / 餐饮。
    expect(find.text('衣橱'), findsOneWidget);
    expect(find.text('餐饮'), findsOneWidget);
  });

  testWidgets('V3.5：仓储默认选中，抽屉显示真实四项子菜单', (tester) async {
    await pumpApp(tester);

    final nav = tester.widget<BottomNavigationBar>(
      find.byKey(const Key('home_bottom_nav')),
    );
    expect(nav.currentIndex, 0, reason: '仓储默认选中（唯一可用模块）');

    await tester.tap(find.byKey(const Key('open_drawer')));
    await tester.pumpAndSettle();

    expect(find.text('仓储模块'), findsOneWidget, reason: '副标题随模块显示');
    expect(find.byKey(const Key('drawer_voice')), findsOneWidget);
    expect(find.byKey(const Key('drawer_locations')), findsOneWidget);
    expect(find.byKey(const Key('drawer_items')), findsOneWidget);
    expect(find.byKey(const Key('drawer_backup')), findsOneWidget);
    expect(find.byKey(const Key('drawer_building_schedule')), findsNothing,
        reason: '仓储模块不渲染占位项');
  });

  testWidgets('V4.2.0：切至衣橱 → 抽屉自动弹出并显示建设中占位'
      '（沿用 V3.5.1 决策点①A；知识库已提平顶栏第四域，被测对象由知识库换成同为占位模块的衣橱）',
      (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('衣橱'));
    await tester.pumpAndSettle();

    final nav = tester.widget<BottomNavigationBar>(
      find.byKey(const Key('home_bottom_nav')),
    );
    expect(nav.currentIndex, 1, reason: '底栏高亮随点击切换');

    // V3.5.1 真机缺陷修复（修订单原文「点击一级按钮 → 左侧菜单
    // 仅展示该模块子菜单」）：底栏点击后抽屉自动弹出，占位模块
    // 有即时可见反馈（此前只切状态不弹抽屉，叠加 ☰ 不可见导致
    // 真机点占位模块零反馈）。
    expect(find.byKey(const Key('home_drawer')), findsOneWidget,
        reason: '点底栏一级按钮后抽屉自动展开');

    expect(find.text('衣橱模块'), findsOneWidget);
    // V3.5 补丁（占位项收敛）：只渲染当前模块自己的一条占位项。
    expect(find.byKey(const Key('drawer_building_wardrobe')), findsOneWidget);
    expect(find.byKey(const Key('drawer_building_dining')), findsNothing,
        reason: '非选中模块不渲染占位项');
    expect(find.byKey(const Key('drawer_building_knowledge')), findsNothing);
    expect(find.byKey(const Key('drawer_locations')), findsNothing,
        reason: '非仓储模块不渲染仓储四项');

    // 决策点③：占位点击仅提示，不进空白页。
    await tester.tap(find.byKey(const Key('drawer_building_wardrobe')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('building_snackbar_wardrobe')), findsOneWidget,
        reason: '点击占位项提示建设中');
    expect(find.byKey(const Key('detail_search')), findsNothing,
        reason: '不进入任何子页');
  });

  testWidgets('V3.5 补丁：切餐饮/衣橱 → 抽屉各只锁单条占位项（V4.2.0：知识库已提平顶栏第四域，底栏撤项）',
      (tester) async {
    await pumpApp(tester);

    final cases = <String, String>{
      '餐饮': 'dining',
      '衣橱': 'wardrobe',
    };
    for (final entry in cases.entries) {
      await tester.tap(find.text(entry.key));
      await tester.pumpAndSettle();

      expect(find.byKey(Key('drawer_building_${entry.value}')), findsOneWidget,
          reason: '${entry.key}抽屉仅显示自己的占位项');
      // 其余三个占位项与仓储四项均不出现。
      for (final other in cases.entries) {
        if (other.value != entry.value) {
          expect(find.byKey(Key('drawer_building_${other.value}')),
              findsNothing);
        }
      }
      expect(find.byKey(const Key('drawer_items')), findsNothing);

      // 决策点③：点击不进页（SnackBar 提示行为已由日程组锁定；
      // SnackBar 默认驻留 4 秒会跨组排队，故此处不重复断言提示）。
      await tester.tap(find.byKey(Key('drawer_building_${entry.value}')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('detail_search')), findsNothing,
          reason: '不进入任何子页');

      // 关抽屉进入下一组。
      tester
          .state<ScaffoldState>(find.byType(Scaffold).first)
          .closeDrawer();
      await tester.pumpAndSettle();
    }
  });

  testWidgets('V3.5：切回仓储 → 抽屉恢复真实四项', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('衣橱'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home_drawer')), findsOneWidget,
        reason: '切占位模块抽屉自动弹出');

    // 模拟用户关闭抽屉后再切回仓储。
    tester.state<ScaffoldState>(find.byType(Scaffold).first).closeDrawer();
    await tester.pumpAndSettle();
    await tester.tap(find.text('仓储'));
    await tester.pumpAndSettle();

    expect(find.text('仓储模块'), findsOneWidget);
    expect(find.byKey(const Key('drawer_items')), findsOneWidget);
    expect(find.byKey(const Key('drawer_building_wardrobe')), findsNothing);
  });

  testWidgets('V3.5：仓储子菜单 → 物品明细全屏页，返回后底栏高亮不变',
      (tester) async {
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('open_drawer')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drawer_items')));
    await tester.pumpAndSettle();

    // 全屏子页（MaterialPageRoute），底栏不在该路由上。
    expect(find.text('物品明细'), findsOneWidget);
    expect(find.byKey(const Key('home_bottom_nav')), findsNothing,
        reason: '子页全屏展示，不叠底栏');

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('phrase_field')), findsOneWidget,
        reason: '返回栈正确：子页返回回首页');
    final nav = tester.widget<BottomNavigationBar>(
      find.byKey(const Key('home_bottom_nav')),
    );
    expect(nav.currentIndex, 0, reason: '返回后底栏高亮保持仓储');
  });

  testWidgets('V3.5：语音主入口与底栏并存不冲突（首屏不空回归）',
      (tester) async {
    await pumpApp(tester);

    expect(find.byKey(const Key('phrase_field')), findsOneWidget);
    expect(find.byKey(const Key('sample_hint')), findsOneWidget);
    expect(find.byKey(const Key('home_bottom_nav')), findsOneWidget);
  });

  // =========== V3.7 借出入口 + 未识别确认框 ===========
  testWidgets('V3.7：仓储抽屉末项「借出管理」可进入借出页', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('open_drawer')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('drawer_loans')), findsOneWidget);
    expect(find.text('借出管理'), findsOneWidget);

    await tester.tap(find.byKey(const Key('drawer_loans')));
    await tester.pumpAndSettle();
    expect(find.text('借出管理'), findsWidgets);
    expect(find.byKey(const Key('loan_add_fab')), findsOneWidget);
  });

  testWidgets('V3.7：未识别带借意图弹确认框，点「用这个说法」填回示例句式',
      (tester) async {
    await pumpApp(tester);
    await submit(tester, '借梯子'); // 有 guess=lend 但解析不出完整三要素
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('intent_confirm_dialog')), findsOneWidget);
    expect(find.textContaining('借出'), findsWidgets);

    await tester.tap(find.byKey(const Key('intent_confirm_use')));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byKey(const Key('phrase_field')));
    expect(field.controller!.text, contains('借给'));
  });

  testWidgets('V3.7：未识别无意图（纯物品名）仍提示没听懂、不弹确认框',
      (tester) async {
    await pumpApp(tester);
    await submit(tester, '梯子');
    await settle(tester);
    expect(find.byKey(const Key('intent_confirm_dialog')), findsNothing);
    expect(find.textContaining('没听懂'), findsOneWidget);
  });

  // =========== V3.7 借出入口 + 未识别确认框 ===========
  testWidgets('V3.7：仓储抽屉末项「借出管理」可进入借出页', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('open_drawer')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('drawer_loans')), findsOneWidget);
    expect(find.text('借出管理'), findsOneWidget);

    await tester.tap(find.byKey(const Key('drawer_loans')));
    await tester.pumpAndSettle();
    expect(find.text('借出管理'), findsWidgets);
    expect(find.byKey(const Key('loan_add_fab')), findsOneWidget);
  });

  testWidgets('V3.7：未识别带借意图弹确认框，点「用这个说法」填回示例句式',
      (tester) async {
    await pumpApp(tester);
    await submit(tester, '借梯子'); // 有 guess=lend 但解析不出完整三要素
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('intent_confirm_dialog')), findsOneWidget);
    expect(find.textContaining('借出'), findsWidgets);

    await tester.tap(find.byKey(const Key('intent_confirm_use')));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byKey(const Key('phrase_field')));
    expect(field.controller!.text, contains('借给'));
  });

  testWidgets('V3.7：未识别无意图（纯物品名）仍提示没听懂、不弹确认框',
      (tester) async {
    await pumpApp(tester);
    await submit(tester, '梯子');
    await settle(tester);
    expect(find.byKey(const Key('intent_confirm_dialog')), findsNothing);
    expect(find.textContaining('没听懂'), findsOneWidget);
  });

  // =========== 缺陷修复：语音借出/归还端到端落库 ===========
  testWidgets('修复：说「借给张三1个梯子」直接借出落库（数量1）',
      (tester) async {
    await pumpApp(tester);
    // V3.10（PM 拍板④）：没记录过的东西不能借出——先录入再借。
    await submit(tester, '梯子放阳台');
    await settle(tester);
    await submit(tester, '借给张三1个梯子');
    await settle(tester);

    final loans = await repo.getAllLoans();
    expect(loans, hasLength(1), reason: '说一句应直接落库，无需进借出页手填');
    expect(loans.first.itemName, '梯子');
    expect(loans.first.borrowerName, '张三');
    expect(loans.first.quantity, 1);
    expect(find.byKey(const Key('notice')), findsOneWidget);
    expect(find.textContaining('已借出：梯子 → 张三'), findsOneWidget);
  });

  testWidgets('修复：说「借给张三2个梯子」数量2落库', (tester) async {
    await pumpApp(tester);
    // V3.10（PM 拍板④）：没记录过的东西不能借出——先录入再借。
    await submit(tester, '3个梯子放阳台');
    await settle(tester);
    await submit(tester, '借给张三2个梯子');
    await settle(tester);

    final loans = await repo.getAllLoans();
    expect(loans, hasLength(1));
    expect(loans.first.quantity, 2);
  });

  testWidgets('修复：说「还了1个梯子」部分归还落库（剩余数量正确）',
      (tester) async {
    await pumpApp(tester);
    // V3.10（PM 拍板④）：没记录过的东西不能借出——先录入再借。
    await submit(tester, '3个梯子放阳台');
    await settle(tester);
    await submit(tester, '借给张三2个梯子');
    await settle(tester);
    await submit(tester, '还了1个梯子');
    await settle(tester);
    await keepReturnLocation(tester);

    final loans = await repo.getAllLoans();
    expect(loans, hasLength(1));
    expect(loans.first.returnedQty, 1, reason: '部分归还累加到原记录');
    expect(loans.first.quantity - loans.first.returnedQty, 1);
    // 元宝批复补充①③：反馈带借阅人 + 剩余数量，与借出文案对称。
    expect(find.textContaining('已归还：梯子 → 张三（1 个 · 还剩 1 个）'),
        findsOneWidget);
  });

  testWidgets('修复：没有借出记录时说「还了梯子」给明确提示、不误判没听懂',
      (tester) async {
    await pumpApp(tester);
    // V3.10（PM 拍板④）：没记录过的东西不能借出——先录入再借。
    await submit(tester, '梯子放阳台');
    await settle(tester);
    await submit(tester, '还了梯子');
    await settle(tester);

    expect(find.textContaining('没有借出的梯子可还'), findsOneWidget);
    expect((await repo.getAllLoans()), isEmpty);
  });

  testWidgets('修复：同物品借给多人，说「还了1个梯子」弹候选问是谁还的（不再静默 FIFO）',
      (tester) async {
    await pumpApp(tester);
    // V3.10（PM 拍板④）：没记录过的东西不能借出——先录入再借。
    await submit(tester, '2个梯子放阳台');
    await settle(tester);
    await submit(tester, '借给张三1个梯子'); // 先借出
    await settle(tester);
    await submit(tester, '借给李四1个梯子'); // 后借出
    await settle(tester);
    await submit(tester, '还了1个梯子');
    await settle(tester);

    // V3.8（PM 真机反馈：没说谁还的会记错账）：多人未还且句中没指名 →
    // 弹候选框让用户点是谁还的，没点之前不写任何归还。
    expect(find.byKey(const Key('return_picker_dialog')), findsOneWidget);
    final before = await repo.getAllLoans();
    expect(before.every((l) => l.returnedQty == 0), isTrue,
        reason: '没选之前零写入');

    // 点「张三」→ 扣张三那笔。
    await tester.tap(find.byKey(const Key('return_pick_张三_1')));
    await settle(tester);
    await keepReturnLocation(tester);

    final loans = await repo.getAllLoans();
    final zhang = loans.firstWhere((l) => l.borrowerName == '张三');
    final li = loans.firstWhere((l) => l.borrowerName == '李四');
    expect(zhang.returnedQty, 1, reason: '用户选了张三那笔');
    expect(li.returnedQty, 0, reason: '李四那笔完全未动');
    expect(find.textContaining('已归还：梯子 → 张三'), findsOneWidget);
  });

  testWidgets('V3.8：说「张三还了1个梯子」指名到人，直接扣张三那笔、不弹候选',
      (tester) async {
    await pumpApp(tester);
    // V3.10（PM 拍板④）：没记录过的东西不能借出——先录入再借。
    await submit(tester, '2个梯子放阳台');
    await settle(tester);
    await submit(tester, '借给张三1个梯子');
    await settle(tester);
    await submit(tester, '借给李四1个梯子');
    await settle(tester);
    await submit(tester, '张三还了1个梯子');
    await settle(tester);
    await keepReturnLocation(tester);

    expect(find.byKey(const Key('return_picker_dialog')), findsNothing,
        reason: '句中已指名，不需要问');
    final loans = await repo.getAllLoans();
    final zhang = loans.firstWhere((l) => l.borrowerName == '张三');
    final li = loans.firstWhere((l) => l.borrowerName == '李四');
    expect(zhang.returnedQty, 1);
    expect(li.returnedQty, 0, reason: '没点名的李四那笔不动');
    expect(find.textContaining('已归还：梯子 → 张三'), findsOneWidget);
  });

  testWidgets('V3.8：说「还了1个梯子给张三」指名到人，直接扣张三那笔',
      (tester) async {
    await pumpApp(tester);
    // V3.10（PM 拍板④）：没记录过的东西不能借出——先录入再借。
    await submit(tester, '2个梯子放阳台');
    await settle(tester);
    await submit(tester, '借给张三1个梯子');
    await settle(tester);
    await submit(tester, '借给李四1个梯子');
    await settle(tester);
    await submit(tester, '还了1个梯子给张三');
    await settle(tester);
    await keepReturnLocation(tester);

    expect(find.byKey(const Key('return_picker_dialog')), findsNothing);
    final loans = await repo.getAllLoans();
    expect(loans.firstWhere((l) => l.borrowerName == '张三').returnedQty, 1);
    expect(loans.firstWhere((l) => l.borrowerName == '李四').returnedQty, 0);
  });

  testWidgets('V3.8：指名的人没借这笔 → 提示真实候选，不静默记到别人头上',
      (tester) async {
    await pumpApp(tester);
    // V3.10（PM 拍板④）：没记录过的东西不能借出——先录入再借。
    await submit(tester, '梯子放阳台');
    await settle(tester);
    await submit(tester, '借给张三1个梯子');
    await settle(tester);
    await submit(tester, '王五还了1个梯子');
    await settle(tester);

    final loans = await repo.getAllLoans();
    expect(loans.first.returnedQty, 0, reason: '没指名成功就不写');
    expect(find.textContaining('没有借给「王五」的梯子未还记录'), findsOneWidget);
  });

  testWidgets('V3.8：句式格式标准常驻输入框下方', (tester) async {
    await pumpApp(tester);
    expect(find.byKey(const Key('phrase_syntax_guide')), findsOneWidget);
    // 借出/归还句式都要写明（含指名说法）。
    expect(find.textContaining('借给张三2个梯子'), findsOneWidget);
    expect(find.textContaining('张三还了1个梯子'), findsOneWidget);
    expect(find.textContaining('还了1个梯子给张三'), findsOneWidget);
  });

  testWidgets('V3.8：借出/归还反馈带位置标签', (tester) async {
    await pumpApp(tester);
    // 先记位置：梯子放阳台
    await submit(tester, '梯子放阳台');
    await settle(tester);
    await submit(tester, '借给张三1个梯子');
    await settle(tester);
    expect(find.textContaining('已借出：梯子 → 张三'), findsOneWidget);
    expect(find.textContaining('在阳台'), findsOneWidget);

    await submit(tester, '张三还了1个梯子');
    await settle(tester);
    await keepReturnLocation(tester);
    expect(find.textContaining('已归还：梯子 → 张三'), findsOneWidget);
    expect(find.textContaining('在阳台'), findsOneWidget);
  });

  // ============ V3.9 语音化第一批：废弃 / 恢复 / 改借期 ============

  // ============ V3.9 语音化第一批：废弃 / 恢复 / 改借期 ============

  group('V3.9 语音化第一批', () {
    testWidgets('废弃：物品转入回收站（破坏性操作先二次确认）',
        (tester) async {
      final loc = await repo.addLocation('阳台');
      await repo.upsertItemLocation('梯子', loc);
      await pumpApp(tester);
      await settle(tester);

      // V3.10（PM 拍板④）：没记录过的东西不能借出——先录入再借。
      await submit(tester, '梯子放阳台');
      await settle(tester);
      await submit(tester, '梯子废弃了');
      await tester.pumpAndSettle();
      // 必须先弹确认，不直接落库。
      expect(find.byKey(const Key('action_confirm_dialog')), findsOneWidget);
      expect(find.textContaining('转入回收站'), findsWidgets);
      expect(await repo.getDeletedItems(), isEmpty);

      await tester.tap(find.byKey(const Key('action_confirm_ok')));
      await settle(tester);
      final deleted = await repo.getDeletedItems();
      expect(deleted.map((r) => r.item.name), contains('梯子'));
      expect(find.textContaining('已把「梯子」转入回收站'), findsOneWidget);
    });

    testWidgets('废弃：借出中的物品先自动归还再转回收站（PM 拍板）',
        (tester) async {
      final loc = await repo.addLocation('阳台');
      await repo.upsertItemLocation('梯子', loc);
      await repo.lendItem('梯子', '张三');
      await pumpApp(tester);
      await settle(tester);

      // V3.10（PM 拍板④）：没记录过的东西不能借出——先录入再借。
      await submit(tester, '梯子放阳台');
      await settle(tester);
      await submit(tester, '梯子废弃了');
      await tester.pumpAndSettle();
      // 确认框要明说会先自动归还给谁。
      expect(find.textContaining('先自动归还'), findsWidgets);
      expect(find.textContaining('现在借给张三'), findsOneWidget);

      await tester.tap(find.byKey(const Key('action_confirm_ok')));
      await settle(tester);
      final loans = await repo.getAllLoans();
      expect(loans.single.returnedQty, 1, reason: '先自动归还');
      expect(loans.single.isReturned, isTrue);
      final deleted = await repo.getDeletedItems();
      expect(deleted.map((r) => r.item.name), contains('梯子'));
      expect(find.textContaining('已先归还给张三'), findsOneWidget);
    });

    testWidgets('恢复：从回收站回到明细（二次确认）', (tester) async {
      final loc = await repo.addLocation('阳台');
      final up = await repo.upsertItemLocation('梯子', loc);
      await repo.deleteItem(up.itemId);
      await pumpApp(tester);
      await settle(tester);

      await submit(tester, '恢复梯子');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('action_confirm_dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('action_confirm_ok')));
      await settle(tester);

      expect(await repo.getDeletedItems(), isEmpty);
      expect(find.textContaining('已恢复'), findsOneWidget);
    });

    testWidgets('恢复：明细已有同名则合并数量并如实回显（PM 拍板）',
        (tester) async {
      final loc = await repo.addLocation('阳台');
      final up = await repo.upsertItemLocation('梯子', loc);
      await repo.deleteItem(up.itemId);
      await repo.upsertItemLocation('梯子', loc); // 明细里同名再一个
      await pumpApp(tester);
      await settle(tester);

      await submit(tester, '恢复梯子');
      await tester.pumpAndSettle();
      // 确认框要提前说明"会并进去"。
      expect(find.textContaining('并进去'), findsWidgets);
      await tester.tap(find.byKey(const Key('action_confirm_ok')));
      await settle(tester);

      final live = await repo.getAllItemsWithLocations();
      expect(live, hasLength(1));
      expect(live.single.item.quantity, 2, reason: '1 + 1 合并');
      expect(find.textContaining('并入明细里已有的同名物品'), findsOneWidget);
    });

    testWidgets('改借期：二次确认后按新天数改到期日', (tester) async {
      await pumpApp(tester);
      await settle(tester);

      // V3.10（PM 拍板④）：没记录过的东西不能借出——先录入再借。
      await submit(tester, '梯子放阳台');
      await settle(tester);
      await repo.lendItem('梯子', '张三');
      await settle(tester);
      await submit(tester, '梯子借期改成5天');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('action_confirm_dialog')), findsOneWidget);
      expect(find.textContaining('5 天'), findsWidgets);
      await tester.tap(find.byKey(const Key('action_confirm_ok')));
      await settle(tester);

      final loans = await repo.getAllLoans();
      expect(loans.single.dueAt, loans.single.borrowedAt + 5 * 86400000);
      expect(find.textContaining('已改借期'), findsOneWidget);
    });

    testWidgets('改借期：「再借3天」是在当前借期上追加', (tester) async {
      await pumpApp(tester);
      await settle(tester);

      // V3.10（PM 拍板④）：没记录过的东西不能借出——先录入再借。
      await submit(tester, '梯子放阳台');
      await settle(tester);
      await repo.lendItem('梯子', '张三');
      await settle(tester);

      await submit(tester, '梯子再借3天');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('action_confirm_ok')));
      await settle(tester);

      final loans = await repo.getAllLoans();
      final expectDays =
          ((loans.single.dueAt - loans.single.borrowedAt) / 86400000).round();
      expect(expectDays, 6, reason: '默认 3 天 + 追加 3 天');
    });

    testWidgets('改借期：已还清的记录改不了，如实提示（元宝补充③）',
        (tester) async {
      await pumpApp(tester);
      await settle(tester);

      // V3.10（PM 拍板④）：没记录过的东西不能借出——先录入再借。
      await submit(tester, '梯子放阳台');
      await settle(tester);
      final loan = await repo.lendItem('梯子', '张三');
      await repo.returnLoan(loan.id!);
      await settle(tester);

      await submit(tester, '梯子借期改成5天');
      await settle(tester);
      expect(find.textContaining('这笔已还清，改不了'), findsOneWidget);
    });

    testWidgets('改借期：多笔未还清时弹候选让用户点，不静默 FIFO',
        (tester) async {
      await pumpApp(tester);
      await settle(tester);

      // V3.10（PM 拍板④）：没记录过的东西不能借出——先录入再借。
      await submit(tester, '2个梯子放阳台');
      await settle(tester);
      await repo.lendItem('梯子', '张三');
      await repo.lendItem('梯子', '李四');
      await settle(tester);

      await submit(tester, '梯子借期改成5天');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('due_picker_dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('due_pick_张三_1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('action_confirm_dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('action_confirm_ok')));
      await settle(tester);

      final loans = await repo.getAllLoans();
      final zhang = loans.firstWhere((l) => l.borrowerName == '张三');
      final li = loans.firstWhere((l) => l.borrowerName == '李四');
      expect(zhang.dueAt, zhang.borrowedAt + 5 * 86400000);
      expect(li.dueAt, isNot(li.borrowedAt + 5 * 86400000),
          reason: '没选的那笔不该动');
    });

    testWidgets('歧义：「梯子不要了放阳台」弹框让用户选意图，不擅自废弃',
        (tester) async {
      await pumpApp(tester);
      await settle(tester);

      // V3.10（PM 拍板④）：没记录过的东西不能借出——先录入再借。
      await submit(tester, '梯子放阳台');
      await settle(tester);
      await submit(tester, '梯子不要了放阳台');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ambiguous_dialog')), findsOneWidget);
      expect(find.textContaining('两种理解'), findsWidgets);

      await tester.tap(find.text('把「梯子」放到阳台'));
      await settle(tester);

      // 选了"放到阳台" → 走放置，没进回收站。
      final items = await repo.getAllItemsWithLocations();
      expect(items.single.item.name, '梯子');
      expect(items.single.locations.map((l) => l.name), contains('阳台'));
      expect(await repo.getDeletedItems(), isEmpty);
    });

    testWidgets('歧义：选「转入回收站」则走废弃', (tester) async {
      final loc = await repo.addLocation('阳台');
      await repo.upsertItemLocation('梯子', loc);
      await pumpApp(tester);
      await settle(tester);

      // V3.10（PM 拍板④）：没记录过的东西不能借出——先录入再借。
      await submit(tester, '梯子放阳台');
      await settle(tester);
      await submit(tester, '梯子不要了放阳台');
      await tester.pumpAndSettle();
      await tester.tap(find.text('把「梯子」转入回收站（废弃）'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('action_confirm_dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('action_confirm_ok')));
      await settle(tester);

      final deleted = await repo.getDeletedItems();
      expect(deleted.map((r) => r.item.name), contains('梯子'));
    });

    testWidgets('歧义选废弃但物品不存在：如实说没法废弃，不弹确认框',
        (tester) async {
      await pumpApp(tester);
      await settle(tester);

      // 注意：本用例刻意**不录入**梯子——选「废弃」时物品查不到，应如实说没有找到。
      await submit(tester, '梯子不要了放阳台');
      await tester.pumpAndSettle();
      await tester.tap(find.text('把「梯子」转入回收站（废弃）'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('action_confirm_dialog')), findsNothing);
      expect(find.textContaining('没有找到'), findsOneWidget);
    });
  });

  // ============ V3.9.1 真机打回修复（PM 复验场景②④） ============
  //
  // 根因：口语「梯子借给张三」（物品在前、动词在后）旧解析器不认，
  // 借出动词「借」留在了物品名里 → 物品被建成「梯子借」、借出记录挂在脏名上，
  // 之后说「借给张三的梯子废弃了」「梯子借期改成5天」全都对不上。
  group('V3.9.1 真机打回修复', () {
    testWidgets('说「梯子借给张三」物品名不再被污染成「梯子借」',
        (tester) async {
      final loc = await repo.addLocation('阳台');
      await repo.upsertItemLocation('梯子', loc);
      await pumpApp(tester);
      await settle(tester);

      await submit(tester, '梯子借给张三');
      await settle(tester);

      final loans = await repo.getAllLoans();
      expect(loans.single.itemName, '梯子',
          reason: '借出记录必须挂在干净物品名上');
      final items = await repo.getAllItemsWithLocations();
      expect(items.map((i) => i.item.name), isNot(contains('梯子借')),
          reason: '不能凭空多出一个叫「梯子借」的物品');
    });

    testWidgets('废弃：「借给张三的梯子废弃了」认得出是梯子，并明说先归还',
        (tester) async {
      final loc = await repo.addLocation('阳台');
      await repo.upsertItemLocation('梯子', loc);
      await repo.lendItem('梯子', '张三');
      await pumpApp(tester);
      await settle(tester);

      // V3.10（PM 拍板④）：没记录过的东西不能借出——先录入再借。
      await submit(tester, '梯子放阳台');
      await settle(tester);
      await submit(tester, '借给张三的梯子废弃了');
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('action_confirm_dialog')), findsOneWidget);
      // V3.9.2：指名废弃的文案改成「会先归还张三」——只还被他点名的那笔。
      expect(find.textContaining('会先归还张三'), findsOneWidget);
      expect(find.textContaining('会先自动归还'), findsNothing,
          reason: '指名时不能写成"全部自动归还"');

      await tester.tap(find.byKey(const Key('action_confirm_ok')));
      await settle(tester);

      final loans = await repo.getAllLoans();
      expect(loans.single.isReturned, isTrue, reason: '先自动归还');
      final deleted = await repo.getDeletedItems();
      expect(deleted.map((r) => r.item.name), contains('梯子'));
    });

    testWidgets('改借期：单笔在借时说改借期直接改，不弹候选', (tester) async {
      // V3.10（PM 拍板④）：没记录过的东西不能借出——先录入再借。
      final loc = await repo.addLocation('阳台');
      await repo.upsertItemLocation('梯子', loc);
      await repo.lendItem('梯子', '张三');
      await pumpApp(tester);
      await settle(tester);

      await submit(tester, '梯子借期改成5天');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('due_picker_dialog')), findsNothing);
      expect(find.byKey(const Key('action_confirm_dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('action_confirm_ok')));
      await settle(tester);

      final loans = await repo.getAllLoans();
      expect(loans.single.dueAt, loans.single.borrowedAt + 5 * 86400000);
    });

    testWidgets('改借期：历史脏名「梯子借」的记录也能被说「梯子」找到',
        (tester) async {
      // 复刻 PM 真机脏数据：V3.9 之前说「梯子借给张三」会建成「梯子借」。
      // V3.10（PM 拍板④）：借出前物品必须已录入。
      final loc = await repo.addLocation('阳台');
      await repo.upsertItemLocation('梯子借', loc);
      await repo.lendItem('梯子借', '张三');
      await pumpApp(tester);
      await settle(tester);

      await submit(tester, '梯子借期改成5天');
      await tester.pumpAndSettle();
      expect(find.textContaining('没有找到可以改借期的借出记录'), findsNothing);
      expect(find.byKey(const Key('action_confirm_dialog')), findsOneWidget);
      expect(find.textContaining('梯子借'), findsWidgets);

      await tester.tap(find.byKey(const Key('action_confirm_ok')));
      await settle(tester);
      final loans = await repo.getAllLoans();
      expect(loans.single.dueAt, loans.single.borrowedAt + 5 * 86400000);
    });

    testWidgets('废弃：历史脏名「梯子借」借出中，说「梯子废弃了」也要先归还',
        (tester) async {
      final loc = await repo.addLocation('阳台');
      await repo.upsertItemLocation('梯子借', loc);
      await repo.lendItem('梯子借', '张三');
      await pumpApp(tester);
      await settle(tester);

      // V3.10（PM 拍板④）：没记录过的东西不能借出——先录入再借。
      await submit(tester, '梯子放阳台');
      await settle(tester);
      await submit(tester, '梯子废弃了');
      await tester.pumpAndSettle();
      expect(find.textContaining('现在借给张三'), findsOneWidget);
      expect(find.textContaining('先自动归还'), findsWidgets);

      await tester.tap(find.byKey(const Key('action_confirm_ok')));
      await settle(tester);
      final loans = await repo.getAllLoans();
      expect(loans.single.isReturned, isTrue);
      final deleted = await repo.getDeletedItems();
      expect(deleted.map((r) => r.item.name), contains('梯子借'));
    });

    testWidgets('废弃：同词根的历史脏记录一起进回收站，不留幽灵物品',
        (tester) async {
      final loc = await repo.addLocation('阳台');
      await repo.upsertItemLocation('梯子', loc);
      await repo.upsertItemLocation('梯子借', loc);
      await pumpApp(tester);
      await settle(tester);

      // V3.10（PM 拍板④）：没记录过的东西不能借出——先录入再借。
      await submit(tester, '梯子放阳台');
      await settle(tester);
      await submit(tester, '梯子废弃了');
      await tester.pumpAndSettle();
      expect(find.textContaining('同一件东西'), findsWidgets);
      await tester.tap(find.byKey(const Key('action_confirm_ok')));
      await settle(tester);

      final deleted = await repo.getDeletedItems();
      expect(deleted.map((r) => r.item.name),
          containsAll(<String>['梯子', '梯子借']));
    });
  });

  // ============ V3.9.2 指名废弃只处理被点名那一笔 ============
  //
  // PM 真机复验新缺陷：梯子借给张三、李四、王五各 1 个，说「借给王五的梯子
  // 废弃了」，旧实现把三笔借出全量归还——李四和张三的账被无辜清零，账乱了。
  group('V3.9.2 指名废弃只处理被点名那一笔', () {
    testWidgets('指名王五废弃：只归还王五那一笔，李四张三保持原样',
        (tester) async {
      final loc = await repo.addLocation('阳台');
      // V3.10：三个人各借 1 个，库存必须够 3 个。
      await repo.upsertItemLocation('梯子', loc, quantity: 3);
      await repo.lendItem('梯子', '张三');
      await repo.lendItem('梯子', '李四');
      await repo.lendItem('梯子', '王五');
      await pumpApp(tester);
      await settle(tester);

      await submit(tester, '借给王五的梯子废弃了');
      await tester.pumpAndSettle();

      // 确认框只提王五，不该把另外两个人也列进"要归还"里。
      expect(find.byKey(const Key('action_confirm_dialog')), findsOneWidget);
      expect(find.textContaining('会先归还王五'), findsOneWidget);
      expect(find.textContaining('张三借的那几笔不动'), findsOneWidget);

      await tester.tap(find.byKey(const Key('action_confirm_ok')));
      await settle(tester);

      final loans = await repo.getAllLoans();
      final byBorrower = <String, bool>{
        for (final l in loans) l.borrowerName: l.isReturned,
      };
      expect(byBorrower['王五'], isTrue, reason: '被点名的那笔要归还');
      expect(byBorrower['李四'], isFalse, reason: '没点名的人账不能被清零');
      expect(byBorrower['张三'], isFalse, reason: '没点名的人账不能被清零');
    });

    testWidgets('指名废弃：确认框写明其余在借记录不动', (tester) async {
      final loc = await repo.addLocation('阳台');
      await repo.upsertItemLocation('梯子', loc, quantity: 2);
      await repo.lendItem('梯子', '张三');
      await repo.lendItem('梯子', '王五');
      await pumpApp(tester);
      await settle(tester);

      await submit(tester, '借给王五的梯子废弃了');
      await tester.pumpAndSettle();
      expect(find.textContaining('张三借的那几笔不动'), findsOneWidget);
      expect(find.textContaining('他们还借着'), findsOneWidget);
    });

    testWidgets('指名废弃：被点名的人没有在借记录，如实提示而不是全量归还',
        (tester) async {
      final loc = await repo.addLocation('阳台');
      await repo.upsertItemLocation('梯子', loc);
      await repo.lendItem('梯子', '张三');
      await pumpApp(tester);
      await settle(tester);

      // V3.10（PM 拍板④）：没记录过的东西不能借出——先录入再借。
      await submit(tester, '梯子放阳台');
      await settle(tester);
      await submit(tester, '借给王五的梯子废弃了');
      await settle(tester);

      expect(find.textContaining('没有王五的借出记录'), findsOneWidget);
      final loans = await repo.getAllLoans();
      expect(loans.single.isReturned, isFalse, reason: '张三的账不该被动');
      expect(await repo.getDeletedItems(), isEmpty, reason: '没确认就不该废弃');
    });

    testWidgets('没指名时仍是全量归还（PM V3.9 拍板口径不变）',
        (tester) async {
      final loc = await repo.addLocation('阳台');
      await repo.upsertItemLocation('梯子', loc, quantity: 2);
      await repo.lendItem('梯子', '张三');
      await repo.lendItem('梯子', '王五');
      await pumpApp(tester);
      await settle(tester);

      await submit(tester, '梯子废弃了');
      await tester.pumpAndSettle();
      expect(find.textContaining('现在借给'), findsOneWidget);
      expect(find.textContaining('张三'), findsWidgets);
      expect(find.textContaining('王五'), findsWidgets);
      expect(find.textContaining('会先自动归还'), findsOneWidget);

      await tester.tap(find.byKey(const Key('action_confirm_ok')));
      await settle(tester);
      final loans = await repo.getAllLoans();
      expect(loans.every((l) => l.isReturned), isTrue);
    });

    testWidgets('指名同一人多笔在借：弹候选问是哪一笔，不替用户猜',
        (tester) async {
      final loc = await repo.addLocation('阳台');
      await repo.upsertItemLocation('梯子', loc, quantity: 2);
      await repo.lendItem('梯子', '王五');
      await repo.lendItem('梯子', '王五');
      await pumpApp(tester);
      await settle(tester);

      await submit(tester, '借给王五的梯子废弃了');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('discard_picker_dialog')), findsOneWidget);
      expect(find.byKey(const Key('action_confirm_dialog')), findsNothing);

      await tester.tap(find.byKey(const Key('discard_picker_cancel')));
      await settle(tester);
      expect(find.textContaining('已取消废弃'), findsOneWidget);
      final loans = await repo.getAllLoans();
      expect(loans.every((l) => !l.isReturned), isTrue, reason: '取消零副作用');
    });
  });

  // ============ V3.11：多位置弹窗四条路径（元宝第 3、9 条）============
  group('V3.11 多位置问位置', () {
    Future<void> seedTwoLocations() async {
      final balcony = await repo.addLocation('阳台');
      final living = await repo.addLocation('客厅');
      await repo.upsertItemLocation('梯子', balcony, quantity: 2);
      await repo.upsertItemLocation('梯子', living, quantity: 1);
    }

    testWidgets('借出多位置：弹窗问从哪儿借，只扣被点名那处', (tester) async {
      await seedTwoLocations();
      await pumpApp(tester);
      await submit(tester, '借给张三1个梯子');
      expect(find.byKey(const Key('pick_location_dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('pick_location_客厅')));
      await settle(tester);

      final loans = await repo.getAllLoans();
      expect(loans, hasLength(1));
      expect((await repo.getQuantityInfo('梯子')).stock, 2);
      final found = await repo.findByName('梯子');
      expect(found!.quantityAt(found.locations
          .firstWhere((l) => l.name == '客厅')
          .id!), 0, reason: '客厅那 1 个被借走');
    });

    testWidgets('无位置累加多位置：弹窗问加到哪儿，不静默归主位置', (tester) async {
      await seedTwoLocations();
      await pumpApp(tester);
      await submit(tester, '又多了2个梯子');
      // 无位置累加走「数量目标」弹窗（不是借出/挪位的来源位置弹窗）。
      expect(find.byKey(const Key('quantity_target_dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('quantity_target_客厅')));
      await settle(tester);

      final found = await repo.findByName('梯子');
      final livingId = found!.locations
          .firstWhere((l) => l.name == '客厅')
          .id!;
      expect(found.quantityAt(livingId), 3, reason: '客厅 1 + 2');
      expect(found.item.quantity, 5);
    });

    testWidgets('带数量挪入多位置：弹窗问从哪儿挪，总数不变', (tester) async {
      await seedTwoLocations();
      await pumpApp(tester);
      await submit(tester, '把1个梯子挪到车库');
      expect(find.byKey(const Key('pick_location_dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('pick_location_阳台')));
      await settle(tester);

      final found = await repo.findByName('梯子');
      expect(found!.locations.map((l) => l.name), containsAll(<String>[
        '阳台', '客厅', '车库',
      ]));
      expect(found.item.quantity, 3, reason: '部分挪不改总数');
      expect(found.quantityAt(found.locations
          .firstWhere((l) => l.name == '阳台')
          .id!), 1);
    });

    testWidgets('只带数量覆盖多位置：弹窗二选一，两种选择各走各的口径',
        (tester) async {
      await seedTwoLocations();
      await pumpApp(tester);

      // ① 选「家里一共 4 个」：只改总数，差额落主位置。
      await submit(tester, '4个梯子');
      expect(find.byKey(const Key('quantity_target_dialog')), findsOneWidget);
      expect(find.byKey(const Key('quantity_target_total')), findsOneWidget);
      await tester.tap(find.byKey(const Key('quantity_target_total')));
      await settle(tester);
      var found = await repo.findByName('梯子');
      expect(found!.item.quantity, 4);
      expect(found.quantityAt(found.locations
          .firstWhere((l) => l.name == '客厅')
          .id!), 1, reason: '选总数不能偷改客厅');

      // ② 选「客厅 5 个」：只改目标位置，其他位置不动。
      await submit(tester, '5个梯子');
      expect(find.byKey(const Key('quantity_target_dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('quantity_target_客厅')));
      await settle(tester);
      found = await repo.findByName('梯子');
      expect(found!.quantityAt(found.locations
          .firstWhere((l) => l.name == '客厅')
          .id!), 5);
      expect(found.quantityAt(found.locations
          .firstWhere((l) => l.name == '阳台')
          .id!), 3, reason: '阳台保持上一步的结果');
    });
  });

  // ============ V3.12 部分废弃（只废 1 个，不连坐） ============
  group('V3.12 部分废弃', () {
    Future<void> seedTwoLocations() async {
      final balcony = await repo.addLocation('阳台');
      final living = await repo.addLocation('客厅');
      await repo.upsertItemLocation('梯子', balcony, quantity: 2);
      await repo.upsertItemLocation('梯子', living, quantity: 1);
    }

    testWidgets('「废弃1个梯子」：问从哪废弃，只废 1 个，其余留在明细',
        (tester) async {
      await seedTwoLocations();
      await pumpApp(tester);
      await submit(tester, '废弃1个梯子');

      // 多位置 → 先问从哪儿废弃（带上各处数量）。
      expect(find.byKey(const Key('pick_location_dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('pick_location_阳台')));
      await settle(tester);

      // 确认框要说清后果。
      expect(find.byKey(const Key('action_confirm_dialog')), findsOneWidget);
      expect(find.textContaining('会'), findsWidgets);
      await tester.tap(find.byKey(const Key('action_confirm_ok')));
      await settle(tester);

      final found = await repo.findByName('梯子');
      expect(found, isNotNull, reason: '物品不能被整条删掉');
      expect(found!.item.quantity, 2, reason: '3 个废 1 个剩 2 个');
      final balconyId = found.locations
          .firstWhere((l) => l.name == '阳台')
          .id!;
      final livingId = found.locations
          .firstWhere((l) => l.name == '客厅')
          .id!;
      expect(found.quantityAt(balconyId), 1, reason: '阳台 2 → 1');
      expect(found.quantityAt(livingId), 1, reason: '客厅不受影响');

      final discards = await repo.getDiscards();
      expect(discards.length, 1);
      expect(discards.first.quantity, 1);
      expect(discards.first.locationName, '阳台');
    });

    testWidgets('「废弃一个梯子」中文数字同样认得', (tester) async {
      await seedTwoLocations();
      await pumpApp(tester);
      await submit(tester, '废弃一个梯子');

      expect(find.byKey(const Key('pick_location_dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('pick_location_客厅')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('action_confirm_ok')));
      await settle(tester);

      final found = await repo.findByName('梯子');
      expect(found!.item.quantity, 2);
      final livingId = found.locations
          .firstWhere((l) => l.name == '客厅')
          .id!;
      expect(found.quantityAt(livingId), 0, reason: '客厅那 1 个被废弃');
    });

    testWidgets('单位置物品：不用问位置，直接确认后只废 1 个', (tester) async {
      final balcony = await repo.addLocation('阳台');
      await repo.upsertItemLocation('梯子', balcony, quantity: 3);
      await pumpApp(tester);
      await submit(tester, '废弃1个梯子');

      expect(find.byKey(const Key('pick_location_dialog')), findsNothing,
          reason: '只有一个位置不必问');
      expect(find.byKey(const Key('action_confirm_dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('action_confirm_ok')));
      await settle(tester);

      final found = await repo.findByName('梯子');
      expect(found!.item.quantity, 2);
    });

    testWidgets('取消确认：零副作用（什么都没改）', (tester) async {
      await seedTwoLocations();
      await pumpApp(tester);
      await submit(tester, '废弃1个梯子');
      await tester.tap(find.byKey(const Key('pick_location_阳台')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('action_confirm_cancel')));
      await settle(tester);

      final found = await repo.findByName('梯子');
      expect(found!.item.quantity, 3, reason: '取消后数量不变');
      expect((await repo.getDiscards()).length, 0, reason: '取消不留流水');
    });

    testWidgets('多笔在借：弹窗问是哪笔，不静默选（元宝批复第 3 条）',
        (tester) async {
      await seedTwoLocations();
      // 两笔在借：张三 1 个、李四 1 个。
      final zhang = await repo.lendItem('梯子', '张三', quantity: 1);
      await repo.lendItem('梯子', '李四', quantity: 1);
      await pumpApp(tester);

      await submit(tester, '废弃1个梯子');

      // 来源弹窗：一次列全（在库的 + 每一笔在借）。
      expect(find.byKey(const Key('discard_source_dialog')), findsOneWidget);
      expect(find.byKey(const Key('discard_source_in_stock')), findsOneWidget);
      expect(find.byKey(Key('discard_source_loan_${zhang.id}')), findsOneWidget);
      expect(find.textContaining('李四'), findsWidgets);

      // 选李四那笔 → 先归还再废弃。
      final liLoan = (await repo.getAllLoans())
          .firstWhere((l) => l.borrowerName == '李四');
      await tester.tap(find.byKey(Key('discard_source_loan_${liLoan.id}')));
      await settle(tester);

      expect(find.byKey(const Key('pick_location_dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('pick_location_客厅')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('action_confirm_ok')));
      await settle(tester);

      // 李四那笔已归还（不再是在借），张三那笔不动。
      final loans = await repo.getAllLoans();
      expect(loans.firstWhere((l) => l.id == liLoan.id).isReturned, isTrue,
          reason: '选中的那笔先归还');
      expect(loans.firstWhere((l) => l.id == zhang.id).isReturned, isFalse,
          reason: '没选中的那笔不动');
    });

    // ============ V3.13 来源弹窗要显示可用数量（PM 真机截图暴露） ============

    testWidgets('V3.13 来源弹窗写明在库还有几个、分别在哪', (tester) async {
      await seedTwoLocations();
      await repo.lendItem('梯子', '张三', quantity: 1);
      await repo.lendItem('梯子', '李四', quantity: 1);
      await pumpApp(tester);

      await submit(tester, '废弃1个梯子');

      expect(find.byKey(const Key('discard_source_dialog')), findsOneWidget);
      // 阳台 2 + 客厅 1 = 3，借出 2 个 → 在库剩 1 个。
      expect(find.textContaining('家里现在有 1 个'), findsOneWidget,
          reason: '必须告诉用户在库还有几个，否则只能点了才知道够不够');
      expect(find.textContaining('客厅 1 个'), findsOneWidget,
          reason: '还要写清各处分布');
    });

    testWidgets('V3.13 在库不够时，该来源置灰不可点（别让人白点一次）',
        (tester) async {
      final balcony = await repo.addLocation('阳台');
      await repo.upsertItemLocation('梯子', balcony, quantity: 2);
      await repo.lendItem('梯子', '张三', quantity: 1);
      await repo.lendItem('梯子', '李四', quantity: 1);
      await pumpApp(tester);

      await submit(tester, '废弃1个梯子');

      expect(find.textContaining('家里现在只有 0 个'), findsOneWidget);
      expect(find.textContaining('不够废弃 1 个'), findsOneWidget);
      // 点它不应该有任何动作（列表项已禁用）。
      final tile = tester.widget<ListTile>(
          find.byKey(const Key('discard_source_in_stock')));
      expect(tile.onTap, isNull, reason: '在库 0 个时这个来源不该可点');
    });

    testWidgets('废弃在借的：借出的那笔也只动说好的数量', (tester) async {
      await seedTwoLocations();
      await repo.lendItem('梯子', '张三', quantity: 1);
      await pumpApp(tester);

      await submit(tester, '废弃1个梯子');
      final loan = (await repo.getAllLoans()).first;
      await tester.tap(find.byKey(Key('discard_source_loan_${loan.id}')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('pick_location_客厅')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('action_confirm_ok')));
      await settle(tester);

      // 归还 1 个 + 废弃 1 个 → 家里还是 2 个（3 - 1 借出 + 1 归还 - 1 废弃）。
      final found = await repo.findByName('梯子');
      expect(found!.item.quantity, 2);
      final discards = await repo.getDiscards();
      expect(discards.length, 1);
      expect(discards.first.sourceType, DiscardSource.onLoan,
          reason: '来源标成在借');
    });

    testWidgets('整件废弃不受影响：「梯子废弃了」仍是全件进回收站',
        (tester) async {
      await seedTwoLocations();
      await pumpApp(tester);
      await submit(tester, '梯子废弃了');
      await tester.tap(find.byKey(const Key('action_confirm_ok')));
      await settle(tester);

      expect(await repo.findByName('梯子'), isNull, reason: '整条进回收站');
      final deleted = await repo.getDeletedItems();
      expect(deleted.any((d) => d.item.name == '梯子'), isTrue);
      expect((await repo.getDiscards()).length, 0,
          reason: '整件废弃不产生部分废弃流水');
    });
  });
}

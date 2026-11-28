/// V4.3.1（+38 P0-2）备份导出前完整性校验。
///
/// PM 口径：导出 JSON 前先扫一遍——关键字段非空、外键指向存在；
/// 校验不通过 → 不生成备份文件，提示「数据异常，暂不备份，请联系排查」。
/// 绝不让坏数据进备份文件。
///
/// 校验范围按本仓**真实表清单**执行（元宝原单里的「日程/餐饮/衣橱」
/// 不在本仓表内，按台账口径修正）：
///  * 仓储域：items / locations / item_locations / borrowers / loans /
///    item_discards / reminders（生活+工作两库同构）；
///  * 知识域：knowledge_nodes（parent_id 指向存在）+ knowledge_entries
///    （node_id 指向存在、一句话核心非空）。
///
/// 只读不改：校验只扫备份 Map，不动库、不动文件。
class BackupIntegrity {
  BackupIntegrity._();

  /// 仓储域备份校验（生活/工作分区与全系统分区内共用）。
  /// 返回问题清单（空 = 通过）。
  static List<String> validateInventoryBackup(Map<String, Object?> backup) {
    final issues = <String>[];
    List<Map<String, Object?>> rowsOf(String table) =>
        (backup[table] as List<Object?>? ?? const <Object?>[])
            .whereType<Map<Object?, Object?>>()
            .map((r) => <String, Object?>{
                  for (final e in r.entries) '${e.key}': e.value,
                })
            .toList();

    final items = rowsOf('items');
    final locations = rowsOf('locations');
    final assocs = rowsOf('item_locations');
    final loans = rowsOf('loans');
    final borrowers = rowsOf('borrowers');
    final discards = rowsOf('item_discards');
    final reminders = rowsOf('reminders');

    final itemIds = items.map((r) => r['id']).toSet();
    final locationIds = locations.map((r) => r['id']).toSet();

    for (var i = 0; i < items.length; i++) {
      final r = items[i];
      if (r['id'] == null) issues.add('items[$i] 缺 id');
      if ((r['name'] as String? ?? '').trim().isEmpty) {
        issues.add('items[$i]（id=${r['id']}）物品名为空');
      }
      final qty = (r['quantity'] as num?)?.toInt();
      if (qty != null && qty < 0) {
        issues.add('items[$i]（id=${r['id']}）数量为负（$qty）');
      }
    }
    for (var i = 0; i < locations.length; i++) {
      final r = locations[i];
      if (r['id'] == null) issues.add('locations[$i] 缺 id');
      if ((r['name'] as String? ?? '').trim().isEmpty) {
        issues.add('locations[$i]（id=${r['id']}）位置名为空');
      }
    }
    for (var i = 0; i < assocs.length; i++) {
      final r = assocs[i];
      final itemId = r['item_id'];
      final locationId = r['location_id'];
      if (!itemIds.contains(itemId)) {
        issues.add('item_locations[$i] 的 item_id=$itemId 指向不存在的物品');
      }
      if (!locationIds.contains(locationId)) {
        issues.add('item_locations[$i] 的 location_id=$locationId 指向不存在的位置');
      }
      final qty = (r['quantity'] as num?)?.toInt();
      if (qty != null && qty < 0) {
        issues.add('item_locations[$i] 数量为负（$qty）');
      }
    }
    for (var i = 0; i < loans.length; i++) {
      final r = loans[i];
      if (!itemIds.contains(r['item_id'])) {
        issues.add('loans[$i]（${r['item_name']}）的 item_id=${r['item_id']} 指向不存在的物品');
      }
      final qty = (r['quantity'] as num?)?.toInt() ?? 0;
      final returned = (r['returned_qty'] as num?)?.toInt() ?? 0;
      if (qty < 1) issues.add('loans[$i]（${r['item_name']}）借出数量 < 1');
      if (returned < 0 || returned > qty) {
        issues.add('loans[$i]（${r['item_name']}）已还数 $returned 超出借出数 $qty');
      }
      if ((r['borrower_name'] as String? ?? '').trim().isEmpty) {
        issues.add('loans[$i]（id=${r['id']}）借阅人为空');
      }
    }
    for (var i = 0; i < borrowers.length; i++) {
      if ((borrowers[i]['name'] as String? ?? '').trim().isEmpty) {
        issues.add('borrowers[$i] 借阅人名为空');
      }
    }
    for (var i = 0; i < discards.length; i++) {
      final r = discards[i];
      if ((r['item_name'] as String? ?? '').trim().isEmpty) {
        issues.add('item_discards[$i] 物品名快照为空');
      }
      final qty = (r['quantity'] as num?)?.toInt();
      if (qty != null && qty < 1) {
        issues.add('item_discards[$i] 废弃数量 < 1');
      }
    }
    for (var i = 0; i < reminders.length; i++) {
      if ((reminders[i]['title'] as String? ?? '').trim().isEmpty) {
        issues.add('reminders[$i] 提醒标题为空');
      }
    }
    return issues;
  }

  /// 知识域备份校验。
  static List<String> validateKnowledgeBackup(Map<String, Object?> backup) {
    final issues = <String>[];
    final nodeRows = (backup['knowledge_nodes'] as List<Object?>? ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map((r) => <String, Object?>{
              for (final e in r.entries) '${e.key}': e.value,
            })
        .toList();
    final entryRows = (backup['knowledge_entries'] as List<Object?>? ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map((r) => <String, Object?>{
              for (final e in r.entries) '${e.key}': e.value,
            })
        .toList();

    final nodeIds = nodeRows.map((r) => r['id']).toSet();
    for (var i = 0; i < nodeRows.length; i++) {
      final r = nodeRows[i];
      if (r['id'] == null) issues.add('knowledge_nodes[$i] 缺 id');
      if ((r['title'] as String? ?? '').trim().isEmpty) {
        issues.add('knowledge_nodes[$i]（id=${r['id']}）标题为空');
      }
      final type = r['node_type'];
      if (type != 'subject' && type != 'topic' && type != 'entry') {
        issues.add('knowledge_nodes[$i]（id=${r['id']}）node_type 异常（$type）');
      }
      final parent = r['parent_id'];
      if (parent != null && !nodeIds.contains(parent)) {
        issues.add('knowledge_nodes[$i]（${r['title']}）parent_id=$parent 指向不存在的节点');
      }
    }
    for (var i = 0; i < entryRows.length; i++) {
      final r = entryRows[i];
      if (!nodeIds.contains(r['node_id'])) {
        issues.add('knowledge_entries[$i] 的 node_id=${r['node_id']} 指向不存在的节点');
      }
    }
    return issues;
  }

  /// 校验门卫：有问题直接抛 ArgumentError（文案 = PM 口径），
  /// 调用方据此「不生成备份文件」。
  static void ensureValid(Map<String, Object?> backup, {required bool knowledge}) {
    final issues =
        knowledge ? validateKnowledgeBackup(backup) : validateInventoryBackup(backup);
    if (issues.isEmpty) return;
    final head = issues.take(3).join('；');
    throw ArgumentError.value(
      backup,
      'backup',
      '数据异常，暂不备份，请联系排查'
          '（共 ${issues.length} 处）：$head',
    );
  }
}

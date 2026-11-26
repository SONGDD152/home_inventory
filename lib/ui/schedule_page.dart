import 'package:flutter/material.dart';

import '../data/daily_report_service.dart';
import '../data/domain.dart';
import '../data/reminder.dart';
import '../data/reminder_repository.dart';
import '../domain/reminder_editor.dart';
import '../domain/repeat_rule.dart';
import 'reminder_edit_dialog.dart';

/// V4.0：日程页（提醒列表 + 增删改 + 完成）。
///
/// 提醒能力受**域能力开关**约束：工作区本轮不开放提醒，
/// 页面直接说清「该区域暂不支持提醒」，不做半截功能。
class SchedulePage extends StatefulWidget {
  const SchedulePage({
    super.key,
    required this.domain,
    required this.reminders,
  });

  /// 当前域。
  final InventoryDomain domain;

  /// 提醒能力（null = 该实例没有这个能力）。
  final ReminderRepository? reminders;

  @override
  State<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<SchedulePage> {
  List<Reminder> _items = const <Reminder>[];
  bool _loading = true;

  bool get _supported =>
      widget.reminders != null &&
      domainSupports(widget.domain, DomainCapability.reminders);

  @override
  void initState() {
    super.initState();
    if (_supported) _reload();
  }

  Future<void> _reload() async {
    final repo = widget.reminders;
    if (repo == null) return;
    final items = await repo.getReminders();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  Future<void> _addReminder() async {
    final repo = widget.reminders;
    if (repo == null) return;
    final result = await _editDialog();
    if (result == null) return;
    await repo.addReminder(
      result.title,
      detail: result.detail,
      dueAt: result.dueAt,
      // V4.1 批次 3：重复规则在**新建**时就要写进去
      // （`addReminder` 本来就带这个参数，只是之前 UI 没给入口）。
      repeatRule: result.repeatRule,
      priority: result.priority,
    );
    await _reload();
  }

  Future<void> _editReminder(Reminder item) async {
    final repo = widget.reminders;
    if (repo == null) return;
    final result = await _editDialog(existing: item);
    if (result == null) return;
    // V4.1 批次 3：编辑时也要能改重复规则。
    //
    // `ReminderRepository.updateReminder` **不支持**改 `repeat_rule`
    // （它是 V4.0 的接口，改签名会波及所有实现者 → 破旧测试红线），
    // 所以这里改走批次 3 新增的 `ReminderEditor.editReminder`
    // ——它专管提醒条目，且支持显式清空重复规则。
    final editor = repo is ReminderEditor ? repo as ReminderEditor : null;
    if (editor != null) {
      await editor.editReminder(
        item.id!,
        title: result.title,
        detail: result.detail,
        dueAt: result.dueAt,
        repeatRule: result.repeatRule,
        clearRepeatRule: result.repeatRule == null,
        priority: result.priority,
      );
    } else {
      // 拿不到窄写口（测试假仓储等）→ 退回旧路径，重复规则不变。
      await repo.updateReminder(
        item.id!,
        title: result.title,
        detail: result.detail,
        priority: result.priority,
      );
    }
    await _reload();
  }

  Future<void> _deleteReminder(Reminder item) async {
    final repo = widget.reminders;
    if (repo == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('reminder_delete_dialog'),
        title: const Text('删除提醒'),
        content: Text('确定删除「${item.title}」？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('reminder_delete_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await repo.deleteReminder(item.id!);
    await _reload();
  }

  Future<void> _toggleDone(Reminder item) async {
    final repo = widget.reminders;
    if (repo == null) return;
    await repo.setReminderDone(item.id!, done: !item.isDone);
    await _reload();
  }

  Future<_ReminderDraft?> _editDialog({Reminder? existing}) async {
    // V4.1 批次 3：复用**共用**的提醒编辑弹窗。
    //
    // 之前这份弹窗是本文件私有的，概览页的日程签另有一份 →
    // 两处迟早漂移（一边能设重复一边不能）。现在统一走
    // `ReminderEditDialog`，两处入口同一套字段。
    final draft = await ReminderEditDialog.show(context, existing: existing);
    if (draft == null) return null;
    return _ReminderDraft(
      title: draft.title,
      detail: draft.detail,
      dueAt: draft.dueAt,
      priority: draft.priority,
      repeatRule: draft.repeatRule,
    );
  }

  /// 列表副标题：备注 + 优先级标记 + 重复规则（裁定① / 批次 3）。
  Widget? _subtitle(Reminder item) {
    final parts = <String>[];
    if (item.detail != null && item.detail!.isNotEmpty) {
      parts.add(item.detail!);
    }
    parts.add('优先级${ReminderPriority.labelOf(item.priority)}');
    // V4.1 批次 3：重复规则标记（不重复的不显示，别给界面添噪音）。
    if (item.repeatRule != null) {
      parts.add(RepeatRule.labelOf(item.repeatRule));
    }
    return Text(parts.join(' · '));
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported) {
      return Center(
        key: const Key('schedule_unsupported'),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('${widget.domain.label}暂不支持提醒',
              style: const TextStyle(fontSize: 16, color: Colors.grey)),
        ),
      );
    }

    final groups = <String, List<Reminder>>{};
    for (final item in _items) {
      final key = item.dueAt == null
          ? '无期限'
          : DailyReportService.formatDate(
              DateTime.fromMillisecondsSinceEpoch(item.dueAt!));
      groups.putIfAbsent(key, () => <Reminder>[]).add(item);
    }
    final keys = groups.keys.toList()..sort();

    return Scaffold(
      appBar: AppBar(title: const Text('日程')),
      body: _loading
          ? const Center(child: Text('加载中…'))
          : ListView(
              key: const Key('schedule_list'),
              padding: const EdgeInsets.only(bottom: 88),
              children: <Widget>[
                for (final key in keys) ...<Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(key,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, color: Colors.grey)),
                  ),
                  for (final item in groups[key]!)
                    ListTile(
                      key: Key('reminder_item_${item.id}'),
                      leading: Checkbox(
                        key: Key('reminder_check_${item.id}'),
                        value: item.isDone,
                        onChanged: (_) => _toggleDone(item),
                      ),
                      title: Text(item.title,
                          style: TextStyle(
                              decoration:
                                  item.isDone ? TextDecoration.lineThrough : null)),
                      subtitle: _subtitle(item),
                      trailing: PopupMenuButton<String>(
                        key: Key('reminder_menu_${item.id}'),
                        onSelected: (value) {
                          if (value == 'edit') {
                            _editReminder(item);
                          } else if (value == 'delete') {
                            _deleteReminder(item);
                          }
                        },
                        itemBuilder: (context) => const <PopupMenuEntry<String>>[
                          PopupMenuItem<String>(value: 'edit', child: Text('编辑')),
                          PopupMenuItem<String>(
                              value: 'delete', child: Text('删除')),
                        ],
                      ),
                    ),
                ],
                if (_items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                      child: Text('还没有提醒，点右下角新增',
                          style: TextStyle(color: Colors.grey)),
                    ),
                  ),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        key: const Key('reminder_add'),
        onPressed: _addReminder,
        tooltip: '新增提醒',
        child: const Icon(Icons.add),
      ),
    );
  }
}

/// 提醒编辑对话框的返回值。
class _ReminderDraft {
  const _ReminderDraft({
    required this.title,
    this.detail,
    this.dueAt,
    this.priority = ReminderPriority.normal,
    this.repeatRule,
  });

  final String title;
  final String? detail;
  final DateTime? dueAt;

  /// 优先级（0 低 / 1 中 / 2 高）——元宝裁定①。
  final int priority;

  /// 重复规则（null = 不重复）——批次 3。
  final String? repeatRule;
}

import 'package:flutter/material.dart';

import '../data/daily_report_service.dart';
import '../data/domain.dart';
import '../data/reminder.dart';
import '../data/reminder_repository.dart';

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
    );
    await _reload();
  }

  Future<void> _editReminder(Reminder item) async {
    final repo = widget.reminders;
    if (repo == null) return;
    final result = await _editDialog(existing: item);
    if (result == null) return;
    await repo.updateReminder(item.id!, title: result.title, detail: result.detail);
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
    final titleController = TextEditingController(text: existing?.title ?? '');
    final detailController = TextEditingController(text: existing?.detail ?? '');
    DateTime? dueAt = existing?.dueAt == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(existing!.dueAt!);
    return showDialog<_ReminderDraft>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          key: const Key('reminder_edit_dialog'),
          title: Text(existing == null ? '新增提醒' : '编辑提醒'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                key: const Key('reminder_title_field'),
                controller: titleController,
                decoration: const InputDecoration(labelText: '标题'),
              ),
              TextField(
                key: const Key('reminder_detail_field'),
                controller: detailController,
                decoration: const InputDecoration(labelText: '备注（可空）'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('reminder_due_pick'),
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: dueAt ?? DateTime.now(),
                    firstDate: DateTime.now().subtract(const Duration(days: 365)),
                    lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
                  );
                  if (picked == null) return;
                  setLocal(() {
                    dueAt = DateTime(picked.year, picked.month, picked.day, 9);
                  });
                },
                icon: const Icon(Icons.event),
                label: Text(dueAt == null
                    ? '选日期（可选）'
                    : '日期：${dueAt!.month}月${dueAt!.day}日'),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              key: const Key('reminder_save'),
              onPressed: () {
                final title = titleController.text.trim();
                if (title.isEmpty) return;
                Navigator.of(context).pop(_ReminderDraft(
                  title: title,
                  detail: detailController.text.trim().isEmpty
                      ? null
                      : detailController.text.trim(),
                  dueAt: dueAt,
                ));
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
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
                      subtitle: item.detail == null ? null : Text(item.detail!),
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
  });

  final String title;
  final String? detail;
  final DateTime? dueAt;
}

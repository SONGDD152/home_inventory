import 'package:flutter/material.dart';

import '../data/domain.dart';
import '../data/reminder.dart';
import '../data/todo_state.dart';
import '../domain/repeat_rule.dart';
import '../domain/todo_agenda.dart';
import '../domain/todo_state_writer.dart';
import 'reminder_edit_dialog.dart';

/// V4.1 批次 3：**跨域日程签**（月历缩略 + 时间轴 + 创建/编辑）。
///
/// ## 写能力为什么是「回调」而不是「写口」
///
/// 这个组件住在**概览页**里。元宝批过的写边界四锁之一是
/// 「概览页不持仓储类型」——概览区**任何文件**都不该持有写接口，
/// 否则「概览改不了账」就只剩约定、不剩编译期保证。
///
/// 所以这里**不持** `ReminderEditor`，只持三个**回调**：
/// 写操作由组合根（`home_page.dart`）去执行——
/// 那里的角色本来就是持有仓储并分发调用。
///
/// 这与概览页已有的 `onOpenReport` / `onOpenDomain` 是同一个模式：
/// 概览区负责**表达意图**，组合根负责**执行**。
///
/// ## 跨域，但写口按域走
///
/// 物理分库下 `reminders` 表**每库一张**。所以回调都带 `domain` 参数——
/// 写错库就是数据分裂。
///
/// ## 与日报签的关系
///
/// 日程签与日报签共用同一份**待办状态**（`todo_states`）：
/// 勾选状态在两个签之间双向同步（两边都从同一处读状态、
/// 都写同一个 `todo_states`）。
///
/// 但**提醒条目本身**（标题/日期/优先级/重复规则）只在日程签里可编辑——
/// 日报签是「看催办」的，不是「管日程」的。
class ScheduleTabView extends StatefulWidget {
  const ScheduleTabView({
    super.key,
    required this.entries,
    required this.todoWriters,
    required this.statesByKey,
    this.editableDomains = const <InventoryDomain>{},
    this.onCreateReminder,
    this.onEditReminder,
    this.onDeleteReminder,
    this.onChanged,
  });

  /// 两域聚合后的日程条目（每条带归属域）。
  final List<ScheduleTabEntry> entries;

  /// 各域的待办状态写口（key = 域）——勾选写 `todo_states`。
  ///
  /// **按域各给一个**：物理分库下 `todo_states` 每库一张，
  /// 只给当前域的话另一个域的勾选根本写不进去。
  final Map<InventoryDomain, TodoStateWriter> todoWriters;

  /// 待办状态：key = `'{domainId}:{sourceType}_{sourceId}'`。
  final Map<String, TodoState> statesByKey;

  /// **开放提醒的域**——只有这些域能新建/编辑/删除。
  ///
  /// 工作域本轮不开放（能力开关，非表缺失）→ 不在这个集合里，
  /// 它的条目只读展示。
  final Set<InventoryDomain> editableDomains;

  /// 新建提醒（组合根执行写操作）。
  final Future<void> Function(InventoryDomain domain, ReminderDraft draft)?
      onCreateReminder;

  /// 编辑提醒。
  final Future<void> Function(
          InventoryDomain domain, int reminderId, ReminderDraft draft)?
      onEditReminder;

  /// 删除提醒。
  final Future<void> Function(InventoryDomain domain, int reminderId)?
      onDeleteReminder;

  /// 状态/条目变化后回调（让父级刷新共享状态）。
  final Future<void> Function()? onChanged;

  @override
  State<ScheduleTabView> createState() => _ScheduleTabViewState();
}

class _ScheduleTabViewState extends State<ScheduleTabView> {
  /// 月历当前显示的月份。
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);

  /// 月历是否展开（默认收起，概览页空间宝贵）。
  bool _calendarExpanded = false;

  /// 选中的日期（null = 不筛选，显示全部）。
  DateTime? _selectedDay;

  /// 是否隐藏已完成条目（V4.1 批次 4 · 裁定②甲方案的配套）。
  ///
  /// **默认 false**（不隐藏）——批次 3 已交付的既有行为一个字没改，
  /// 用户想清爽时一键收起。
  bool _hideDone = false;

  /// 该条目的完成态（**`todo_states` 优先**——与日报签同源）。
  ///
  /// 状态行不存在时才回落到条目自带的 `done`
  /// （`reminders.status`；注意勾选流程维护的是 `todo_states`，
  /// 那一列目前不由勾选写）。
  bool _isDone(ScheduleTabEntry entry) {
    final state = widget.statesByKey[
        TodoAgenda.stateKeyOf(entry.domain, TodoState.entryKeyOf(
            TodoSourceType.scheduleReminder, entry.reminderId))];
    return state?.isDone ?? entry.done;
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const Key('overview_schedule_tab'),
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        _buildCalendarCard(),
        const SizedBox(height: 12),
        _buildAddButton(),
        _buildDoneToggle(),
        const SizedBox(height: 8),
        ..._buildTimeline(),
      ],
    );
  }

  // ─────────────────────── 月历缩略（可折叠）───────────────────────

  Widget _buildCalendarCard() {
    // 有日程的日期集合（按自然日）。
    final days = <DateTime>{};
    for (final entry in widget.entries) {
      if (entry.dueAt == null) continue;
      days.add(_dayOf(entry.dueAt!));
    }
    return Card(
      key: const Key('schedule_calendar_card'),
      child: Column(
        children: <Widget>[
          ListTile(
            key: const Key('schedule_calendar_header'),
            onTap: () => setState(() => _calendarExpanded = !_calendarExpanded),
            leading: const Icon(Icons.calendar_month_outlined),
            title: const Text('月历'),
            subtitle: Text('${_month.year} 年 ${_month.month} 月 · '
                '共 ${days.length} 天有日程'),
            trailing: Icon(
              _calendarExpanded ? Icons.expand_less : Icons.expand_more,
            ),
          ),
          if (_calendarExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: _buildCalendarGrid(days),
            ),
        ],
      ),
    );
  }

  Widget _buildCalendarGrid(Set<DateTime> days) {
    final first = DateTime(_month.year, _month.month, 1);
    // 周一为一周之首（国内习惯）。
    final leading = first.weekday - 1;
    final totalDays = DateTime(_month.year, _month.month + 1, 0).day;
    final cells = <Widget>[];
    for (final label in const <String>['一', '二', '三', '四', '五', '六', '日']) {
      cells.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ));
    }
    for (var i = 0; i < leading; i++) {
      cells.add(const SizedBox(height: 32));
    }
    for (var d = 1; d <= totalDays; d++) {
      final date = DateTime(_month.year, _month.month, d);
      final has = days.contains(date);
      final selected = _selectedDay != null &&
          _selectedDay!.year == date.year &&
          _selectedDay!.month == date.month &&
          _selectedDay!.day == date.day;
      cells.add(InkWell(
        key: Key('schedule_cal_day_$d'),
        onTap: () {
          setState(() {
            // 再点一次取消筛选。
            _selectedDay = selected ? null : date;
          });
        },
        child: Container(
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? Colors.blue.shade100 : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text('$d',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: has ? FontWeight.bold : FontWeight.normal,
                    color: has ? Colors.blue.shade900 : null,
                  )),
              if (has)
                Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.blue.shade700,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
            ],
          ),
        ),
      ));
    }
    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            IconButton(
              key: const Key('schedule_cal_prev'),
              onPressed: () => setState(() {
                _month = DateTime(_month.year, _month.month - 1);
              }),
              icon: const Icon(Icons.chevron_left),
              tooltip: '上个月',
            ),
            Expanded(
              child: Text('${_month.year} 年 ${_month.month} 月',
                  textAlign: TextAlign.center),
            ),
            IconButton(
              key: const Key('schedule_cal_next'),
              onPressed: () => setState(() {
                _month = DateTime(_month.year, _month.month + 1);
              }),
              icon: const Icon(Icons.chevron_right),
              tooltip: '下个月',
            ),
          ],
        ),
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 7,
          childAspectRatio: 1,
          children: cells,
        ),
      ],
    );
  }

  // ─────────────────────── 历史折叠开关（批次 4）───────────────────────

  /// 「隐藏已完成」开关。
  ///
  /// ## 为什么需要它（V4.1 批次 4 · 裁定②甲方案的配套）
  ///
  /// 甲方案（完成后自动新建下一实例、**保留历史**）会让 `reminders` 表
  /// 里**同时存在**当前实例与历史实例。一个「每天」的日程做一周，
  /// 时间轴上就有 7 条已完成的历史实例 + 1 条当前实例——
  /// 全铺开就没法看日程了。
  ///
  /// 所以给一个开关让用户自己收起。**默认不隐藏**（批次 3 的既有行为
  /// 一个字没改），想清爽时一键收起；历史**不会丢**，日报里照样看得到。
  Widget _buildDoneToggle() {
    if (widget.entries.isEmpty) return const SizedBox.shrink();
    final doneCount = widget.entries.where(_isDone).length;
    if (doneCount == 0) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: const Key('schedule_toggle_done'),
        onPressed: () => setState(() => _hideDone = !_hideDone),
        icon: Icon(
          _hideDone ? Icons.visibility_outlined : Icons.visibility_off_outlined,
          size: 18,
        ),
        label: Text(_hideDone ? '显示已完成（$doneCount）' : '隐藏已完成（$doneCount）'),
      ),
    );
  }

  // ─────────────────────── 新建 ───────────────────────

  /// 新建按钮。
  ///
  /// 只列**开放提醒的域**（工作域本轮不开放），
  /// 让用户建在能建的地方——不给一个点了就报错的入口。
  Widget _buildAddButton() {
    final domains = InventoryDomain.values
        .where((d) => widget.editableDomains.contains(d))
        .toList();
    if (domains.isEmpty || widget.onCreateReminder == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('暂无区域支持日程',
            key: Key('schedule_add_unsupported'),
            style: TextStyle(color: Colors.grey)),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: const Key('schedule_add'),
        onPressed: () => _addReminder(domains.first),
        icon: const Icon(Icons.add),
        label: Text(domains.length == 1
            ? '新建提醒'
            : '新建提醒（${domains.first.label}）'),
      ),
    );
  }

  Future<void> _addReminder(InventoryDomain domain) async {
    final draft = await ReminderEditDialog.show(context);
    if (draft == null) return;
    final handler = widget.onCreateReminder;
    if (handler == null) return;
    try {
      await handler(domain, draft);
      if (widget.onChanged != null) await widget.onChanged!();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('新建失败：$e')),
      );
    }
  }

  // ─────────────────────── 时间轴 ───────────────────────

  List<Widget> _buildTimeline() {
    // 按到期日分组（无期限的排最后）。
    final groups = <String, List<ScheduleTabEntry>>{};
    for (final entry in widget.entries) {
      // 「隐藏已完成」开关生效处（历史实例可折叠）。
      if (_hideDone && _isDone(entry)) continue;
      if (_selectedDay != null) {
        if (entry.dueAt == null) continue;
        final d = _dayOf(entry.dueAt!);
        if (d.year != _selectedDay!.year ||
            d.month != _selectedDay!.month ||
            d.day != _selectedDay!.day) {
          continue;
        }
      }
      final key = entry.dueAt == null
          ? '无期限'
          : _fmtDay(entry.dueAt!);
      groups.putIfAbsent(key, () => <ScheduleTabEntry>[]).add(entry);
    }
    final keys = groups.keys.toList()..sort();
    if (groups.isEmpty) {
      return <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            _selectedDay == null ? '还没有日程，点上方新建' : '这天没有日程',
            key: const Key('schedule_empty'),
            style: const TextStyle(color: Colors.grey),
          ),
        ),
      ];
    }
    return <Widget>[
      for (final key in keys) ...<Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 10, 0, 2),
          child: Row(
            children: <Widget>[
              const Icon(Icons.schedule, size: 14, color: Colors.grey),
              const SizedBox(width: 4),
              Text(key,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.grey)),
            ],
          ),
        ),
        for (final entry in groups[key]!) _buildEntryRow(entry),
      ],
    ];
  }

  Widget _buildEntryRow(ScheduleTabEntry entry) {
    final state = widget.statesByKey[
        TodoAgenda.stateKeyOf(entry.domain, TodoState.entryKeyOf(
            TodoSourceType.scheduleReminder, entry.reminderId))];
    final done = _isDone(entry);
    final deferred = !done && (state?.deferCount ?? 0) > 0;
    final editable = widget.editableDomains.contains(entry.domain);

    final tags = <String>[
      if (entry.priority != 1) '优先级${_priorityLabel(entry.priority)}',
      if (entry.repeatRule != null) RepeatRule.labelOf(entry.repeatRule),
      if (deferred) '已延期 ${state!.deferCount} 次',
      if (state?.handleNote != null && state!.handleNote!.isNotEmpty)
        '备注：${state.handleNote}',
    ];

    return Container(
      decoration: deferred
          ? const BoxDecoration(
              border: Border(left: BorderSide(color: Colors.orange, width: 3)),
            )
          : null,
      child: ListTile(
        key: Key('schedule_entry_${entry.id}'),
        dense: true,
        leading: Checkbox(
          key: Key('overview_check_${entry.id}'),
          value: done,
          onChanged: (v) => _toggle(entry, v ?? false),
        ),
        title: Row(
          children: <Widget>[
            // 跨域标识（批次 3 ②）：一眼看出这条属于哪个域。
            Container(
              key: Key('schedule_domain_tag_${entry.id}'),
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: entry.domain == InventoryDomain.life
                    ? Colors.teal.shade50
                    : Colors.indigo.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: entry.domain == InventoryDomain.life
                      ? Colors.teal.shade300
                      : Colors.indigo.shade300,
                ),
              ),
              child: Text(entry.domain.storageLabel,
                  style: const TextStyle(fontSize: 10)),
            ),
            Expanded(
              child: Text(
                entry.title,
                style: TextStyle(
                  decoration: done ? TextDecoration.lineThrough : null,
                  color: done ? Colors.grey : null,
                ),
              ),
            ),
          ],
        ),
        subtitle: tags.isEmpty ? null : Text(tags.join(' · ')),
        trailing: !editable
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  IconButton(
                    key: Key('schedule_edit_${entry.id}'),
                    tooltip: '编辑',
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    onPressed: () => _edit(entry),
                  ),
                  IconButton(
                    key: Key('schedule_delete_${entry.id}'),
                    tooltip: '删除',
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: () => _delete(entry),
                  ),
                ],
              ),
      ),
    );
  }

  Future<void> _toggle(ScheduleTabEntry entry, bool done) async {
    final writer = widget.todoWriters[entry.domain];
    if (writer == null) return;
    try {
      await writer.markDone(
        TodoSourceType.scheduleReminder,
        entry.reminderId,
        done: done,
      );
      if (widget.onChanged != null) await widget.onChanged!();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('更新失败：$e')),
      );
    }
  }

  Future<void> _edit(ScheduleTabEntry entry) async {
    final draft = await ReminderEditDialog.show(
      context,
      existing: Reminder(
        id: entry.reminderId,
        title: entry.title,
        detail: entry.detail,
        dueAt: entry.dueAt,
        status: entry.done ? 'done' : 'pending',
        repeatRule: entry.repeatRule,
        priority: entry.priority,
        createdAt: 0,
        updatedAt: 0,
      ),
    );
    if (draft == null) return;
    final handler = widget.onEditReminder;
    if (handler == null) return;
    try {
      await handler(entry.domain, entry.reminderId, draft);
      if (widget.onChanged != null) await widget.onChanged!();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$e')),
      );
    }
  }

  Future<void> _delete(ScheduleTabEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('schedule_delete_dialog'),
        title: const Text('删除提醒'),
        content: Text('确定删除「${entry.title}」？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('schedule_delete_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final handler = widget.onDeleteReminder;
    if (handler == null) return;
    try {
      await handler(entry.domain, entry.reminderId);
      if (widget.onChanged != null) await widget.onChanged!();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败：$e')),
      );
    }
  }

  static DateTime _dayOf(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return DateTime(d.year, d.month, d.day);
  }

  static String _fmtDay(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  static String _priorityLabel(int priority) {
    switch (priority) {
      case 2:
        return '高';
      case 0:
        return '低';
      default:
        return '中';
    }
  }
}

/// V4.1 批次 3：日程签里的一条条目。
class ScheduleTabEntry {
  const ScheduleTabEntry({
    required this.id,
    required this.title,
    required this.domain,
    required this.reminderId,
    this.detail,
    this.dueAt,
    this.priority = 1,
    this.repeatRule,
    this.done = false,
  });

  final String id;
  final String title;
  final InventoryDomain domain;

  /// 该域 `reminders` 表里的主键（勾选 / 编辑 / 删除都用它）。
  final int reminderId;

  final String? detail;
  final int? dueAt;
  final int priority;
  final String? repeatRule;
  final bool done;
}

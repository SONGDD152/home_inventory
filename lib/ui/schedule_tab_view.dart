import 'package:flutter/material.dart';

import '../data/domain.dart';
import '../data/reminder.dart';
import '../data/todo_state.dart';
import '../domain/lunar_label.dart';
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
    this.onListDeletedReminders,
    this.onRestoreReminder,
    this.onPurgeReminder,
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

  /// 删除提醒（软删进回收站）。
  final Future<void> Function(InventoryDomain domain, int reminderId)?
      onDeleteReminder;

  /// V4.1.3：回收站读写三回调（概览区仍不持仓储写口）。
  final Future<List<Reminder>> Function(InventoryDomain domain)?
      onListDeletedReminders;
  final Future<void> Function(InventoryDomain domain, int reminderId)?
      onRestoreReminder;
  final Future<void> Function(InventoryDomain domain, int reminderId)?
      onPurgeReminder;

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

  /// V4.1.4：是否显示农历/节日小字（默认开，可关避免格子过挤）。
  bool _showLunar = true;

  /// 选中的日期（null = 不筛选，显示全部）。
  DateTime? _selectedDay;

  /// 是否隐藏已完成条目（V4.1 批次 4 裁定② + V4.1.3 真机反馈）。
  ///
  /// **V4.1.3 改默认开**（`true`）：PM 真机反馈「已完成项天天挂着越累越多」。
  /// 这是**纯视图过滤**——不软删、不进回收站、不自动过期、数据一条不删，
  /// 随时点开关切回显示（v45 旧测试改断言保行数，语义由「默认显示」
  /// 改为「默认隐藏、一点即显示」）。
  bool _hideDone = true;

  /// 左滑确认后、滑出动画执行前暂存用户选的删除方式（按条目 id）。
  final Map<String, _DeleteChoice> _pendingDelete = <String, _DeleteChoice>{};

  /// 该条目的完成态（**`todo_states` 优先**——与日报签同源）。
  ///
  /// 状态行不存在时才回落到条目自带的 `done`
  /// （`reminders.status`；注意勾选流程维护的是 `todo_states`，
  /// 那一列目前不由勾选写）。
  /// 该条目的 `todo_states` 状态行（null = 从未处理过）。
  TodoState? _stateOf(ScheduleTabEntry entry) => widget.statesByKey[
      TodoAgenda.stateKeyOf(entry.domain, TodoState.entryKeyOf(
          TodoSourceType.scheduleReminder, entry.reminderId))];

  bool _isDone(ScheduleTabEntry entry) =>
      _stateOf(entry)?.isDone ?? entry.done;

  /// V4.1.4：三态当前值——空框 pending / 半框 in_progress / 满框 done。
  /// 状态行不存在时回落到条目自带的 done。
  String _statusOf(ScheduleTabEntry entry) {
    final state = _stateOf(entry);
    if (state == null) {
      return entry.done ? TodoStatus.done : TodoStatus.pending;
    }
    // 系统自动延期的 deferred 不参与三态勾选循环，展示为空框。
    return state.isDone
        ? TodoStatus.done
        : (state.isInProgress ? TodoStatus.inProgress : TodoStatus.pending);
  }

  @override
  Widget build(BuildContext context) {
    // V4.1.1 整改 2：**唯一滚动容器**。
    //
    // ## 之前的毛病（PM 2026-11-27 真机手点发现）
    //
    // 提醒超过一屏后**拖不动**，下方内容够不着。
    //
    // 根因有两层：
    // ① **摊平式 children**——`_buildTimeline()` 把所有条目摊平进
    //    `ListView.children`，条目一多就顶出一屏，而外层 `TabBarView`
    //    的 `PageView` 与内层 `ListView` **同时抢垂直拖动手势** →
    //    真机上 `PageView` 先赢下手势竞技场 → 拖不动。
    // ② **条目全量构建**——摊平的 children 无法回收。
    //
    // ## 现在的做法
    //
    // - 整个日程签**只有一个滚动容器**（这个 `ListView`），
    //   内部不再有第二个能抢手势的滚动视图；
    // - 时间轴改 `ListView.builder` **惰性构建**，只建可见的那些；
    // - 月历卡 / 新建按钮 / 隐藏开关用 `header` 参数挂上——
    //   它们随内容一起滚，但**不占用滚动容器之外的独立视口**。
    final timeline = _timelineSlots();
    return ListView.builder(
      key: const Key('overview_schedule_tab'),
      padding: const EdgeInsets.all(16),
      itemCount: timeline.length + 1,
      itemBuilder: (context, index) {
        // index 0 = 固定头部（月历卡 + 新建按钮 + 隐藏开关）。
        if (index == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _buildCalendarCard(),
              const SizedBox(height: 12),
              _buildAddButton(),
              _buildDoneToggle(),
              _buildTrashButton(),
              const SizedBox(height: 8),
            ],
          );
        }
        final slot = timeline[index - 1];
        switch (slot.kind) {
          case _TimelineKind.header:
            return _buildTimelineHeader(slot.label);
          case _TimelineKind.entry:
            return _buildEntryRow(slot.entry!);
          case _TimelineKind.empty:
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                _selectedDay == null ? '还没有日程，点上方新建' : '这天没有日程',
                key: const Key('schedule_empty'),
                style: const TextStyle(color: Colors.grey),
              ),
            );
        }
      },
    );
  }

  /// 时间轴的**扁平索引表**（只存索引，不存 Widget）。
  ///
  /// ## 为什么是「索引」而不是「Widget 列表」
  ///
  /// 惰性构建的前提是：**看不见的条目根本不构 Widget**。
  /// 所以这里只算出「第几组、第几条」这样的定位信息，
  /// 真正的 Widget 留给 [ListView.builder] 的 `itemBuilder` 现建。
  ///
  /// 摊平式 children 做不到这一点——所有条目在 `build` 时就全建好了。
  List<_TimelineSlot> _timelineSlots() {
    final groups = _timelineGroups();
    if (groups.isEmpty) {
      return <_TimelineSlot>[_TimelineSlot.empty()];
    }
    final slots = <_TimelineSlot>[];
    for (final g in groups) {
      slots.add(_TimelineSlot.header(g.label));
      for (final entry in g.entries) {
        slots.add(_TimelineSlot.entry(entry));
      }
    }
    return slots;
  }

  /// 按到期日分组的条目（不含 Widget，只做筛选与分组）。
  ///
  /// 「隐藏已完成」开关与月历选日筛选都在这里生效——
  /// **筛选口径与渲染分离**，所以惰性构建不会改变「哪些条目该出现」。
  List<_TimelineGroup> _timelineGroups() {
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
    return <_TimelineGroup>[
      for (final key in keys) _TimelineGroup(key, groups[key]!),
    ];
  }

  /// 时间轴的分组标题（到期日）。
  Widget _buildTimelineHeader(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 10, 0, 2),
      child: Row(
        children: <Widget>[
          const Icon(Icons.schedule, size: 14, color: Colors.grey),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(
                  fontWeight: FontWeight.bold, color: Colors.grey)),
        ],
      ),
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
    // V4.1.5：副标题只统计**当前显示月**的天数——
    // 翻到别的月份时数字跟着走，否则翻月后永远显示总数、自相矛盾。
    final monthDayCount = days
        .where((d) => d.year == _month.year && d.month == _month.month)
        .length;
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
                '共 $monthDayCount 天有日程'),
            trailing: Icon(
              _calendarExpanded ? Icons.expand_less : Icons.expand_more,
            ),
          ),
          if (_calendarExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Column(
                children: <Widget>[
                  // V4.1.4：农历/节日显示开关（默认开）。
                  Row(
                    children: <Widget>[
                      const Text('显示农历/节日',
                          style: TextStyle(fontSize: 12, color: Colors.grey)),
                      Switch(
                        key: const Key('schedule_lunar_toggle'),
                        value: _showLunar,
                        onChanged: (v) => setState(() => _showLunar = v),
                      ),
                    ],
                  ),
                  _buildCalendarGrid(days),
                ],
              ),
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
      cells.add(const SizedBox(height: 44));
    }
    for (var d = 1; d <= totalDays; d++) {
      final date = DateTime(_month.year, _month.month, d);
      final has = days.contains(date);
      final selected = _selectedDay != null &&
          _selectedDay!.year == date.year &&
          _selectedDay!.month == date.month &&
          _selectedDay!.day == date.day;
      // V4.1.4：农历/节日小字（关闭时不算、不渲染）。
      final lunarText = _showLunar ? LunarLabel.of(date) : null;
      cells.add(InkWell(
        key: Key('schedule_cal_day_$d'),
        onTap: () {
          setState(() {
            // 再点一次取消筛选。
            _selectedDay = selected ? null : date;
          });
        },
        child: Container(
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            // V4.1.5：选中高亮走主题绿（PM 拍板「全 APK 按钮颜色一致」）；
            // 「有日程」的蓝点/蓝字是数据标记，保持蓝色语义不动。
            color: selected
                ? Theme.of(context).colorScheme.primaryContainer
                : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('$d',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: has ? FontWeight.bold : FontWeight.normal,
                    color: has ? Colors.blue.shade900 : null,
                  )),
              // 小字一行：节日/节气/农历（字号 9，超长省略）。
              if (lunarText != null)
                Text(
                  lunarText,
                  key: Key('schedule_cal_lunar_$d'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 9,
                    color: (_showLunar &&
                            (lunarText == '元旦' ||
                                lunarText == '春节' ||
                                lunarText == '中秋' ||
                                lunarText == '劳动节' ||
                                lunarText == '国庆节'))
                        ? Colors.red.shade700
                        : Colors.grey.shade700,
                  ),
                ),
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
  /// 所以给一个开关让用户自己收起。**V4.1.3 起默认隐藏**（真机反馈：
  /// 已完成越挂越多），一点即可切回显示；历史**不会丢**，
  /// 纯视图过滤，不软删/不回收站/不自动过期。
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

  /// V4.1.3：提醒回收站入口（软删的提醒在这里恢复 / 彻底删除）。
  ///
  /// 仍只持回调，不持仓储；按域分别读，避免跨域混账。
  Widget _buildTrashButton() {
    if (widget.onListDeletedReminders == null) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: const Key('schedule_open_trash'),
        onPressed: _openTrash,
        icon: const Icon(Icons.delete_sweep_outlined, size: 18),
        label: const Text('提醒回收站'),
      ),
    );
  }

  // ─────────────────────── 新建 ───────────────────────

  /// 新建按钮。
  ///
  /// **整改 3：不再「默认落第一个域」**——
  /// 之前这里直接 `domains.first`（= 生活区），用户没有任何选择余地：
  /// 工作区无入口可选，新建的提醒**一律带「生活」标签**（分区破口）。
  ///
  /// 现在把**可选的域列表**交给弹窗，让用户在建的时候就明确表态
  /// 落哪本账；不选**不能存**。
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
        onPressed: () => _addReminder(domains),
        icon: const Icon(Icons.add),
        // 有多个可选区时，提示「建在哪由你选」——不给默认落区的错觉。
        label: Text(domains.length == 1 ? '新建提醒' : '新建提醒（选区域）'),
      ),
    );
  }

  /// 新建提醒（整改 3：区域由用户在弹窗里选）。
  ///
  /// [domains] = 可选的域（**开放提醒的域**）。
  /// 选中的域随 [ReminderDraft.domain] 回来，交给回调按域写库——
  /// 物理分库下 `reminders` 表每库一张，落错库就是数据分裂。
  Future<void> _addReminder(List<InventoryDomain> domains) async {
    final draft = await ReminderEditDialog.show(
      context,
      domainOptions: domains,
      // **不预选**（整改 3：去掉默认落区）。
    );
    if (draft == null) return;
    final handler = widget.onCreateReminder;
    if (handler == null) return;
    // 兜底：只有一个可选域时，它就是落区（用户没得选，不必再问）。
    final domain = draft.domain ??
        (domains.length == 1 ? domains.first : null);
    if (domain == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没选要放在哪个区')),
      );
      return;
    }
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

    final row = Container(
      decoration: deferred
          ? const BoxDecoration(
              border: Border(left: BorderSide(color: Colors.orange, width: 3)),
            )
          : null,
      child: ListTile(
        key: Key('schedule_entry_${entry.id}'),
        dense: true,
        // V4.1.3 真机反馈：原来只有右侧小图标能编辑，用户点条目没反应。
        // 现在整行可点进详情改标题；长按弹删除选择。
        onTap: editable ? () => _edit(entry) : null,
        onLongPress: editable ? () => _deleteFlow(entry) : null,
        leading: Checkbox(
          key: Key('overview_check_${entry.id}'),
          // V4.1.4 三态：tristate 的 null 态横线由 Flutter 绘制引擎画
          // （不依赖字体 glyph → 真机不会出「仑」状怪字）。
          tristate: true,
          value: _statusOf(entry) == TodoStatus.done
              ? true
              : (_statusOf(entry) == TodoStatus.inProgress ? null : false),
          // 循环由我们控制（空→半→满→空），忽略 Flutter 传入的 v。
          // 与原版一致无条件挂（_cycle 内部 writer 为 null 时自行返回）。
          onChanged: (_) => _cycle(entry),
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

    // V4.1.3：左滑删除（长按也可）。确认弹窗先问「回收站 / 彻底删除」，
    // 用户取消则 Dismissible 回弹、条目不动。
    return Dismissible(
      key: Key('schedule_dismiss_${entry.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red.shade200,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      confirmDismiss: (_) async {
        if (!editable) return false;
        final choice = await _askDelete(entry);
        if (choice == null) return false;
        _pendingDelete[entry.id] = choice;
        return true;
      },
      onDismissed: (_) {
        final choice = _pendingDelete.remove(entry.id);
        if (choice != null) _performDelete(entry, choice);
      },
      child: row,
    );
  }

  /// V4.1.4：三态循环——空框 → 半框(in_progress) → 满框(done) → 空框。
  /// 走 setTodoStatus 写口（UI 只持回调）；markDone 旧路径保留兼容。
  Future<void> _cycle(ScheduleTabEntry entry) async {
    final writer = widget.todoWriters[entry.domain];
    if (writer == null) return;
    final next = TodoStatus.next(_statusOf(entry));
    try {
      await writer.setTodoStatus(
        TodoSourceType.scheduleReminder,
        entry.reminderId,
        next,
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

  /// V4.1.3：删除方式选择——软删进回收站（可恢复）/ 彻底删除（二次确认）。
  Future<_DeleteChoice?> _askDelete(ScheduleTabEntry entry) async {
    final choice = await showDialog<_DeleteChoice>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('schedule_delete_dialog'),
        title: const Text('删除提醒'),
        content: Text('「${entry.title}」要怎么删？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('schedule_delete_trash'),
            onPressed: () => Navigator.of(context).pop(_DeleteChoice.trash),
            child: const Text('移到回收站'),
          ),
          TextButton(
            key: const Key('schedule_delete_purge'),
            onPressed: () => Navigator.of(context).pop(_DeleteChoice.purge),
            child: const Text('彻底删除'),
          ),
        ],
      ),
    );
    if (choice == _DeleteChoice.purge) {
      if (!mounted) return null;
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          key: const Key('schedule_purge_confirm'),
          title: const Text('彻底删除？'),
          content: const Text('这条提醒会被物理删除，不能恢复。确定吗？'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              key: const Key('schedule_purge_confirm_ok'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('彻底删除'),
            ),
          ],
        ),
      );
      if (ok != true) return null;
    }
    return choice;
  }

  /// 长按/旧删除按钮走的流程：先问方式，再执行（左滑走 confirmDismiss）。
  Future<void> _deleteFlow(ScheduleTabEntry entry) async {
    final choice = await _askDelete(entry);
    if (choice == null) return;
    await _performDelete(entry, choice);
  }

  Future<void> _delete(ScheduleTabEntry entry) => _deleteFlow(entry);

  Future<void> _performDelete(ScheduleTabEntry entry, _DeleteChoice choice) async {
    final handler = choice == _DeleteChoice.trash
        ? widget.onDeleteReminder
        : widget.onPurgeReminder;
    if (handler == null) return;
    try {
      await handler(entry.domain, entry.reminderId);
      if (widget.onChanged != null) await widget.onChanged!();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(choice == _DeleteChoice.trash
                ? '已移到提醒回收站，可以恢复'
                : '已彻底删除')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败：$e')),
      );
    }
  }

  /// V4.1.3：提醒回收站弹窗（按域分组，恢复 / 彻底删除都要二次确认）。
  Future<void> _openTrash() async {
    final listHandler = widget.onListDeletedReminders;
    if (listHandler == null) return;
    final rows = <({InventoryDomain domain, Reminder reminder})>[];
    for (final domain in widget.editableDomains) {
      for (final r in await listHandler(domain)) {
        rows.add((domain: domain, reminder: r));
      }
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('schedule_trash_dialog'),
        title: const Text('提醒回收站'),
        content: SizedBox(
          width: 320,
          child: rows.isEmpty
              ? const Text('回收站为空')
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: rows.length,
                  itemBuilder: (context, i) {
                    final row = rows[i];
                    final id = row.reminder.id;
                    return ListTile(
                      key: Key('schedule_trash_${row.domain.id}_$id'),
                      dense: true,
                      title: Text(row.reminder.title),
                      subtitle: Text(row.domain.label),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          TextButton(
                            key: Key('schedule_restore_${row.domain.id}_$id'),
                            onPressed: () async {
                              final h = widget.onRestoreReminder;
                              if (h == null || id == null) return;
                              await h(row.domain, id);
                              if (widget.onChanged != null) {
                                await widget.onChanged!();
                              }
                              if (context.mounted) Navigator.of(context).pop();
                            },
                            child: const Text('恢复'),
                          ),
                          TextButton(
                            key: Key('schedule_trash_purge_${row.domain.id}_$id'),
                            onPressed: () async {
                              final h = widget.onPurgeReminder;
                              if (h == null || id == null) return;
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text('彻底删除？'),
                                  content: Text('「${row.reminder.title}」删除后不能恢复。'),
                                  actions: <Widget>[
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.of(context).pop(false),
                                      child: const Text('取消'),
                                    ),
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.of(context).pop(true),
                                      child: const Text('彻底删除'),
                                    ),
                                  ],
                                ),
                              );
                              if (ok != true) return;
                              await h(row.domain, id);
                              if (widget.onChanged != null) {
                                await widget.onChanged!();
                              }
                              if (context.mounted) Navigator.of(context).pop();
                            },
                            child: const Text('彻底删除'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
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

/// V4.1.3：删除方式（软删可恢复 / 物理删除不可恢复）。
enum _DeleteChoice { trash, purge }

/// V4.1.1 整改 2：时间轴槽位的三种形态。
enum _TimelineKind {
  /// 分组标题（到期日）。
  header,

  /// 一条日程条目。
  entry,

  /// 空态提示（一条也没有时）。
  empty,
}

/// V4.1.1 整改 2：**时间轴的一个槽位**（惰性构建的最小单位）。
///
/// 只存定位信息（标题文字 / 条目引用），**不存 Widget**——
/// Widget 由 [ListView.builder] 的 `itemBuilder` 现建，
/// 看不见的槽位根本不构 Widget。
class _TimelineSlot {
  const _TimelineSlot.header(this.label)
      : kind = _TimelineKind.header,
        entry = null;

  const _TimelineSlot.entry(this.entry)
      : kind = _TimelineKind.entry,
        label = '';

  const _TimelineSlot.empty()
      : kind = _TimelineKind.empty,
        label = '',
        entry = null;

  final _TimelineKind kind;

  /// 分组标题文字（到期日 / 「无期限」）。
  final String label;

  /// 该槽位对应的日程条目（只有 [kind] 为 entry 时非空）。
  final ScheduleTabEntry? entry;
}

/// V4.1.1 整改 2：时间轴的一个分组（同一到期日的条目）。
class _TimelineGroup {
  const _TimelineGroup(this.label, this.entries);

  /// 分组标题（到期日 / 「无期限」）。
  final String label;

  /// 该组下的条目。
  final List<ScheduleTabEntry> entries;
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

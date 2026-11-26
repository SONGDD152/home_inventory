import 'package:flutter/material.dart';

import '../data/domain.dart';
import '../data/todo_state.dart';
import '../domain/overview_reader.dart';
import '../domain/reminder_source.dart';
import '../domain/reminder_sources.dart';
import '../domain/todo_state_writer.dart';

/// V4.1：概览页（**账目只读 + 待办可写**）。
///
/// 顶栏 [概览][生活][工作] 的第一项，与生活区/工作区**同级**（PM 拍板）。
///
/// ## 写边界的代码层落实（PM 拍板 + 元宝认可）
///
/// 本页只持有两个接口，**能力面完全隔离**：
/// - [OverviewReader]：**只读账目**（物品 / 在库 / 在借 / 守恒），无任何写方法；
/// - [TodoStateWriter]：**只写待办条目状态**（`todo_states` 表）。
///
/// `TodoStateWriter` 的方法入参只有 `sourceType`（字符串）+ `sourceId`（整数），
/// **拿不到任何仓储句柄**——所以「概览改不了账」在**编译期**成立，
/// 不是靠「UI 没放按钮」这种自觉。
class OverviewPage extends StatefulWidget {
  const OverviewPage({
    super.key,
    required this.reader,
    required this.sources,
    this.todoWriter,
    this.switchTimeoutCount = 0,
    this.onOpenDomain,
  });

  /// 两域账目快照的只读读取口。
  final OverviewReader reader;

  /// 提醒源注册表（统一接口，概览代码不因新增源而改）。
  final List<ReminderSource> sources;

  /// 待办状态写入口（null = 该环境不支持写待办状态，页面退化为只读展示）。
  final TodoStateWriter? todoWriter;

  /// 切库超时次数（**用户可见**：切库降级不是静默的）。
  final int switchTimeoutCount;

  /// 「去某域建首个位置」的跳转回调（空态引导用）。
  final Future<void> Function(InventoryDomain domain)? onOpenDomain;

  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage>
    with SingleTickerProviderStateMixin {
  List<DomainOverview>? _snapshots;
  /// **key 用 `source.id`（唯一标识），不再用 displayName**——
  /// V4.0 的 E1 bug 就是拿 displayName 当 key，生活区与工作区的同名源
  /// 互相覆盖，生活区的借出到期条目被工作区的空集整个吞掉。
  final Map<String, List<OverviewEntry>> _entriesBySource =
      <String, List<OverviewEntry>>{};
  /// 待办状态：key = `'{sourceType}_{sourceId}'`（与条目配对）。
  final Map<String, TodoState> _statesByKey = <String, TodoState>{};
  bool _loading = true;
  String? _error;
  late final TabController _tabController =
      TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snapshots = <DomainOverview>[
        await widget.reader.read(InventoryDomain.life),
        await widget.reader.read(InventoryDomain.work),
      ];
      final entries = <String, List<OverviewEntry>>{};
      for (final source in widget.sources) {
        entries[source.id] = await source.loadEntries();
      }
      // 待办状态与条目分属两表，这里按业务键配对（JOIN 读取）。
      final states = <String, TodoState>{};
      final writer = widget.todoWriter;
      if (writer != null) {
        for (final state in await writer.loadStates()) {
          states[state.entryKey] = state;
        }
        // 自动延期：把「到期当天未处理」的条目推进一天，延期次数 +1。
        // 每天最多 +1 次（幂等，重复调用不会重复加次）。
        await writer.syncOverdue(DateTime.now());
      }
      if (!mounted) return;
      setState(() {
        _snapshots = snapshots;
        _entriesBySource
          ..clear()
          ..addAll(entries);
        _statesByKey
          ..clear()
          ..addAll(states);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        // 双签：左【日报】右【日程】，默认选中日报签（PM 拍板）。
        TabBar(
          key: const Key('overview_tabs'),
          controller: _tabController,
          tabs: const <Widget>[
            Tab(key: Key('overview_tab_report'), text: '日报'),
            Tab(key: Key('overview_tab_schedule'), text: '日程'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: <Widget>[
              _buildReportTab(),
              _buildScheduleTab(),
            ],
          ),
        ),
      ],
    );
  }

  // ───────────────────────── 日报签 ─────────────────────────

  Widget _buildReportTab() {
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        key: const Key('overview_page'),
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          if (widget.switchTimeoutCount > 0)
            Card(
              key: const Key('overview_switch_timeout'),
              color: Colors.orange.shade50,
              child: ListTile(
                leading: const Icon(Icons.warning_amber_outlined),
                title: Text('切库超时 ${widget.switchTimeoutCount} 次'),
                subtitle: const Text('切换区域时旧账有操作未收尾，已自动修复连接。'),
              ),
            ),
          // 静态文字而不是持续转的 CircularProgressIndicator：
          // 持续动画会让 widget 测试的 pumpAndSettle 永远等不到静止帧。
          if (_loading) const Center(child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('加载中…'),
          )),
          if (_error != null)
            Text('读取失败：$_error', key: const Key('overview_error')),
          for (final snapshot in _snapshots ?? const <DomainOverview>[])
            _snapshotCard(snapshot),
          const SizedBox(height: 8),
          const Text('催办',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          // 催办区 = 日程类 + 系统类混排，用图标/标签区分（元宝 B5）。
          for (final source in widget.sources) ...<Widget>[
            const SizedBox(height: 8),
            Text(source.displayName,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            ..._entryWidgets(source),
          ],
        ],
      ),
    );
  }

  Widget _snapshotCard(DomainOverview snapshot) {
    // E3：工作区全 0 空态给引导，不再只印一行数字。
    final empty = snapshot.itemCount == 0 && snapshot.stock == 0 &&
        snapshot.lent == 0;
    return Card(
      key: Key('overview_domain_${snapshot.domain.id}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(snapshot.domain.label,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text('物品 ${snapshot.itemCount} 种｜在库 ${snapshot.stock}'
                '｜在借 ${snapshot.lent}｜废弃未恢复 ${snapshot.discardedPending}'),
            Text('总拥有 ${snapshot.totalOwned}'),
            Text(
              snapshot.isBalanced ? '账目平衡' : '账目不平，请检查',
              key: Key('overview_balance_${snapshot.domain.id}'),
              style: TextStyle(
                color: snapshot.isBalanced ? Colors.green : Colors.red,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (empty) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                snapshot.domain == InventoryDomain.work
                    ? '独立记账，与生活区互不相通。'
                    : '还没有记账，先建第一个位置。',
                key: Key('overview_empty_${snapshot.domain.id}'),
                style: const TextStyle(color: Colors.grey),
              ),
              if (snapshot.domain == InventoryDomain.work &&
                  widget.onOpenDomain != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const Key('overview_empty_goto_work'),
                    onPressed: () => widget.onOpenDomain!(InventoryDomain.work),
                    icon: const Icon(Icons.arrow_forward),
                    label: const Text('去工作区建首个位置'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// 单条独立成行的催办条目（元宝 E5 / B1）。
  List<Widget> _entryWidgets(ReminderSource source) {
    final entries = _entriesBySource[source.id] ?? const <OverviewEntry>[];
    if (entries.isEmpty) {
      return <Widget>[
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: Text('暂无待办', style: TextStyle(color: Colors.grey)),
        ),
      ];
    }
    return entries.map((entry) {
      final key = entry.stateKey;
      final state = key == null ? null : _statesByKey[key];
      return _TodoEntryRow(
        key: Key('overview_entry_${entry.id}'),
        entry: entry,
        state: state,
        writer: widget.todoWriter,
        // 系统类（借出到期）与日程类用图标区分（元宝 B5）。
        isSystemHint: source.id.startsWith('loan_due_'),
      );
    }).toList();
  }

  // ───────────────────────── 日程签 ─────────────────────────

  Widget _buildScheduleTab() {
    final snapshots = _snapshots ?? const <DomainOverview>[];
    if (snapshots.isEmpty && _loading) {
      return const Center(child: Text('加载中…'));
    }
    return ListView(
      key: const Key('overview_schedule_tab'),
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        for (final snapshot in snapshots) ...<Widget>[
          Text(snapshot.domain.label,
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          ..._scheduleRows(snapshot.domain),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  /// 某域的日程条目（复用 [ScheduleReminderSource]，不另开数据通道）。
  List<Widget> _scheduleRows(InventoryDomain domain) {
    ScheduleReminderSource? source;
    for (final s in widget.sources) {
      if (s is ScheduleReminderSource && s.domain == domain) {
        source = s;
        break;
      }
    }
    if (source == null) {
      // 工作区本轮不开放提醒（能力开关，不是表缺失）。
      return <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text('${domain.label}暂不支持提醒',
              key: Key('schedule_unsupported_${domain.id}'),
              style: const TextStyle(color: Colors.grey)),
        ),
      ];
    }
    final entries = _entriesBySource[source.id] ?? const <OverviewEntry>[];
    if (entries.isEmpty) {
      return <Widget>[
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: Text('暂无日程', style: TextStyle(color: Colors.grey)),
        ),
      ];
    }
    return entries.map((entry) {
      final key = entry.stateKey;
      final state = key == null ? null : _statesByKey[key];
      return _TodoEntryRow(
        key: Key('schedule_entry_${entry.id}'),
        entry: entry,
        state: state,
        writer: widget.todoWriter,
        isSystemHint: false,
      );
    }).toList();
  }
}

/// V4.1：催办条目行（**单条独立成行**）。
///
/// 独立 [StatefulWidget] 是为了「**勾选只刷单条**」（元宝 J 项）：
/// 勾选时只 `setState` 自己这一行，**不整页重建**。
class _TodoEntryRow extends StatefulWidget {
  const _TodoEntryRow({
    super.key,
    required this.entry,
    required this.state,
    required this.writer,
    required this.isSystemHint,
  });

  final OverviewEntry entry;
  final TodoState? state;
  final TodoStateWriter? writer;
  final bool isSystemHint;

  @override
  State<_TodoEntryRow> createState() => _TodoEntryRowState();
}

class _TodoEntryRowState extends State<_TodoEntryRow> {
  late bool _done = widget.state?.isDone ?? widget.entry.done;
  late int _deferCount = widget.state?.deferCount ?? 0;
  late String? _note = widget.state?.handleNote;

  @override
  void didUpdateWidget(covariant _TodoEntryRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final s = widget.state;
    if (s == null) return;
    _done = s.isDone;
    _deferCount = s.deferCount;
    _note = s.handleNote;
  }

  Future<void> _toggle() async {
    final writer = widget.writer;
    final entry = widget.entry;
    if (writer == null ||
        entry.sourceType == null ||
        entry.sourceId == null) {
      return;
    }
    final next = !_done;
    // 乐观更新：先改本地状态（只重建这一行），写库失败再回滚。
    setState(() {
      _done = next;
    });
    try {
      await writer.markDone(entry.sourceType!, entry.sourceId!, done: next);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _done = !next;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final dimmed = _done;
    final subtitleParts = <String>[
      if (entry.subtitle != null) entry.subtitle!,
      if (_deferCount > 0) '已延期 $_deferCount 次',
      if (_note != null && _note!.isNotEmpty) '备注：$_note',
    ];
    return ListTile(
      dense: true,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // 日程类 vs 系统类用图标区分（元宝 B5）。
          Icon(
            widget.isSystemHint ? Icons.inventory_2_outlined : Icons.event_note,
            size: 18,
            color: Colors.grey,
          ),
          Checkbox(
            key: Key('overview_check_${entry.id}'),
            value: _done,
            onChanged: (_) => _toggle(),
          ),
        ],
      ),
      title: Text(
        entry.title,
        style: TextStyle(
          decoration: dimmed ? TextDecoration.lineThrough : null,
          color: dimmed ? Colors.grey : null,
        ),
      ),
      subtitle: subtitleParts.isEmpty
          ? null
          : Text(subtitleParts.join(' · '),
              style: TextStyle(
                color: dimmed ? Colors.grey : null,
                decoration: dimmed ? TextDecoration.lineThrough : null,
              )),
    );
  }
}

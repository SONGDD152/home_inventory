import 'package:flutter/material.dart';

import '../data/domain.dart';
import '../data/todo_state.dart';
import '../domain/overview_reader.dart';
import '../domain/reminder_source.dart';
import '../domain/reminder_sources.dart';
import '../domain/todo_agenda.dart';
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
///
/// ## 批次 2：三态 + 完整交互
///
/// - 三态：未处理 / 已处理（划线灰化，可撤销）/ 已延期（独立视觉）；
/// - 延期按钮：每次 +1 次（按「次」累计，跨天不重置）；
/// - 备注编辑：处理备注 / 延期原因随条目保存，导出时一并带出；
/// - 催办区口径走 [TodoAgenda]（**界面与导出同源**，元宝 B6）。
class OverviewPage extends StatefulWidget {
  const OverviewPage({
    super.key,
    required this.reader,
    required this.sources,
    this.todoWriters = const <InventoryDomain, TodoStateWriter>{},
    this.switchTimeoutCount = 0,
    this.onOpenDomain,
    this.onOpenReport,
  });

  /// 两域账目快照的只读读取口。
  final OverviewReader reader;

  /// 提醒源注册表（统一接口，概览代码不因新增源而改）。
  final List<ReminderSource> sources;

  /// 各域的待办状态写入口（key = 域）。
  ///
  /// **为什么是 Map 而不是单个**：物理分库下 `todo_states` **每库一张表**，
  /// 概览催办区却同时展示生活域与工作域的条目——只拿一个写口，
  /// 另一个域的状态根本读不到（条目永远显示「未处理」）。
  /// 所以按域各拿一个，按条目所属域取用。
  ///
  /// **写边界不受影响**：每个写口的能力面仍然只有
  /// 「写 `todo_states` 这一张表」，入参仍然只有 sourceType + sourceId，
  /// **拿不到任何仓储句柄** → 「概览改不了账」在编译期依然成立。
  final Map<InventoryDomain, TodoStateWriter> todoWriters;

  /// 切库超时次数（**用户可见**：切库降级不是静默的）。
  final int switchTimeoutCount;

  /// 「去某域建首个位置」的跳转回调（空态引导用）。
  final Future<void> Function(InventoryDomain domain)? onOpenDomain;

  /// 「打开日报页」的跳转回调（V4.1 批次 2：补孤儿页入口）。
  final VoidCallback? onOpenReport;

  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage>
    with SingleTickerProviderStateMixin {
  List<DomainOverview>? _snapshots;

  /// key 用 `source.id`（唯一标识），不再用 displayName——
  /// V4.0 的 E1 bug 就是拿 displayName 当 key，生活区与工作区的同名源
  /// 互相覆盖，生活区的借出到期条目被工作区的空集整个吞掉。
  final Map<String, List<OverviewEntry>> _entriesBySource =
      <String, List<OverviewEntry>>{};

  /// 待办状态：key = `'{domainId}:{sourceType}_{sourceId}'`（与条目配对）。
  ///
  /// **带域前缀**是必须的——两库各有一张 `todo_states`，
  /// 生活区的 `loan_due_1` 与工作区的 `loan_due_1` 在存储层各自唯一，
  /// 合并进同一张 Map 时就会撞（E1 在状态层的翻版）。
  final Map<String, TodoState> _statesByKey = <String, TodoState>{};

  bool _loading = true;
  String? _error;

  late final TabController _tabController =
      TabController(length: 2, vsync: this);

  @override
  void initState() {
    super.initState();
    // **首帧之后**才去加载——`initState` 里直接调 `setState` 会触发断言
    // （"setState() called in constructor"），而 `_reload()` 开头就要
    // setState（把 _loading 置真、_error 清空）。
    //
    // V4.1 批次 2 修：这一行之前**根本不存在** → 概览页永远停在
    // 「加载中…」，一张卡、一条催办都不显示。
    // 之所以一直没被发现：概览页**从来没有 widget 测试**，
    // 数据层测试全绿也照样漏过去了。这条是 widget 测试的回归锁。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reload();
    });
  }

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
      // **逐域读**：每个域一张 todo_states，合并时 key 带域前缀。
      final states = <String, TodoState>{};
      for (final domain in InventoryDomain.values) {
        final writer = widget.todoWriters[domain];
        if (writer == null) continue;
        for (final state in await writer.loadStates()) {
          states[TodoAgenda.stateKeyOf(domain, state.entryKey)] = state;
        }
      }
      // 自动延期：把「到期当天未处理」的条目推进一天，延期次数 +1。
      // 每天最多 +1 次（幂等，重复调用不会重复加次）。
      for (final domain in InventoryDomain.values) {
        final writer = widget.todoWriters[domain];
        if (writer == null) continue;
        await writer.syncOverdue(DateTime.now());
      }
      // 自动延期会改状态行 → 重新读一次，界面才显示得到「已延期 N 次」。
      states.clear();
      for (final domain in InventoryDomain.values) {
        final writer = widget.todoWriters[domain];
        if (writer == null) continue;
        for (final state in await writer.loadStates()) {
          states[TodoAgenda.stateKeyOf(domain, state.entryKey)] = state;
        }
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
          Row(
            children: <Widget>[
              const Expanded(
                child: Text('催办',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              // V4.1 批次 2：日报入口（孤儿页修复）。
              // 之前 DailyReportPage 全仓无引用 → 用户根本进不去日报。
              if (widget.onOpenReport != null)
                TextButton.icon(
                  key: const Key('overview_open_report'),
                  onPressed: widget.onOpenReport,
                  icon: const Icon(Icons.description_outlined, size: 18),
                  label: const Text('日报'),
                ),
            ],
          ),
          const SizedBox(height: 4),
          // 催办区 = 日程类 + 系统类**分组**（元宝裁定④）：
          // 图标区分 + 可折叠；组内按优先级排序（裁定①）。
          for (final source in widget.sources) ...<Widget>[
            const SizedBox(height: 8),
            _buildAgendaGroup(source),
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

  /// 某源下的催办条目（今日到期 + 已延期未处理的）。
  ///
  /// 口径统一走 [TodoAgenda]——**与日报导出同源**（元宝 B6：
  /// 「未完成 = 提示框内未处理的条目」）。
  List<TodoAgendaItem> _agendaItems(ReminderSource source) {
    final entries = _entriesBySource[source.id] ?? const <OverviewEntry>[];
    final now = DateTime.now();
    final isSystem = source.id.startsWith('loan_due_');
    final items = <TodoAgendaItem>[];
    for (final entry in entries) {
      final state = _statesByKey[TodoAgenda.stateKeyOf(entry.domain, entry.stateKey)];
      final item = TodoAgendaItem(
        entry: entry,
        state: state,
        sourceDisplayName: source.displayName,
        isSystemHint: isSystem,
      );
      if (!item.isInAgenda(now)) continue;
      items.add(item);
    }
    // 裁定①：催办区按**优先级排序**（高 → 中 → 低）。
    // 排序口径放在 [TodoAgenda] 里（与「哪些条目进区」同一处口径）。
    TodoAgenda.sortByPriority(items);
    return items;
  }

  /// 取某个域的待办状态写入口（null = 该域没有该能力 → 该域条目只读展示）。
  TodoStateWriter? _writerOf(InventoryDomain? domain) {
    if (domain == null) return null;
    return widget.todoWriters[domain];
  }

  /// 催办区分组（元宝裁定④）：系统类 / 日程类**图标区分** + **可折叠**。
  ///
  /// 分组标题带图标：系统类（借出到期）= 箱子图标，日程类 = 日程图标。
  /// 默认展开（刚进来就能看见催办内容），但可以点标题折起来。
  Widget _buildAgendaGroup(ReminderSource source) {
    final items = _agendaItems(source);
    final isSystem = source.id.startsWith('loan_due_');
    return ExpansionTile(
      key: Key('overview_group_${source.id}'),
      initiallyExpanded: true,
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 4),
      leading: Icon(
        isSystem ? Icons.inventory_2_outlined : Icons.event_note,
        size: 20,
        color: Colors.grey,
      ),
      title: Text(source.displayName,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      subtitle: Text(items.isEmpty ? '暂无待办' : '共 ${items.length} 条待办',
          style: const TextStyle(fontSize: 12)),
      children: items.isEmpty
          ? const <Widget>[
              Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Text('暂无待办', style: TextStyle(color: Colors.grey)),
              ),
            ]
          : items
              .map((item) => _TodoEntryRow(
                    key: Key('overview_entry_${item.entry.id}'),
                    item: item,
                    // 按条目所属域取写口——物理分库下每库一张 todo_states。
                    writer: _writerOf(item.entry.domain),
                    onChanged: _onRowStateChanged,
                  ))
              .toList(),
    );
  }

  /// 某行状态变化后的回调（延期 / 备注 / 勾选后刷新共享状态）。
  Future<void> _onRowStateChanged() async {
    final states = <String, TodoState>{};
    for (final domain in InventoryDomain.values) {
      final writer = widget.todoWriters[domain];
      if (writer == null) continue;
      for (final state in await writer.loadStates()) {
        states[TodoAgenda.stateKeyOf(domain, state.entryKey)] = state;
      }
    }
    if (!mounted) return;
    setState(() {
      _statesByKey
        ..clear()
        ..addAll(states);
    });
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
    // 日程签与日报签**共用同一份状态**（元宝 B8 双向同步）：
    // 两边都是 _TodoEntryRow，都从 _statesByKey 取状态、都写同一个
    // todo_states —— 所以在任一边勾选，另一边刷新后立刻同步。
    // 先把 displayName 取出来：闭包里 Dart 的类型提升会失效。
    final displayName = source.displayName;
    // 纵览排序：到期日近的在前；没到期日的排最后。
    final sorted = entries.toList()
      ..sort((a, b) {
        const far = 1 << 62;
        final da = a.dueAt ?? far;
        final db2 = b.dueAt ?? far;
        final byDue = da.compareTo(db2);
        if (byDue != 0) return byDue;
        return a.title.compareTo(b.title);
      });
    return sorted.map((entry) {
      final state =
          _statesByKey[TodoAgenda.stateKeyOf(entry.domain, entry.stateKey)];
      final item = TodoAgendaItem(
        entry: entry,
        state: state,
        sourceDisplayName: displayName,
        isSystemHint: false,
      );
      return _TodoEntryRow(
        key: Key('schedule_entry_${entry.id}'),
        item: item,
        writer: _writerOf(entry.domain),
        onChanged: _onRowStateChanged,
        // 裁定⑤：日程签**只管纵览 + 状态展示**，不碰提醒交互
        // → 延期 / 备注两个按钮不出现（勾选保留，那是待办状态本身，
        // 也是元宝 B8「双向同步」的落点）。
        showActions: false,
      );
    }).toList();
  }
}

/// V4.1 批次 2：催办条目行（三态 + 延期 + 备注）。
///
/// 独立 [StatefulWidget] 是为了「**勾选只刷单条**」（元宝 J 项）：
/// 勾选时只 `setState` 自己这一行，**不整页重建**。
///
/// ## 三态视觉（元宝 B2）
///
/// - **未处理**（pending）：常态，勾选框未勾，标题无删除线；
/// - **已处理**（done）：标题与副标题**划线 + 灰化**，可撤销；
/// - **已延期**（deferred）：**独立视觉**——橙色左边条 + 延期角标
///   「已延期 N 次」，与前两态一眼可分。
class _TodoEntryRow extends StatefulWidget {
  const _TodoEntryRow({
    super.key,
    required this.item,
    required this.writer,
    required this.onChanged,
    this.showActions = true,
  });

  final TodoAgendaItem item;
  final TodoStateWriter? writer;

  /// 状态变化后通知父级刷新共享状态（让另一个签同步）。
  final Future<void> Function() onChanged;

  /// 是否显示「延期 / 备注」两个提醒交互按钮。
  ///
  /// **false = 只读纵览**（元宝裁定⑤：日程签只管纵览 + 状态展示，
  /// 不碰提醒交互）。日报签传 true。
  final bool showActions;

  @override
  State<_TodoEntryRow> createState() => _TodoEntryRowState();
}

class _TodoEntryRowState extends State<_TodoEntryRow> {
  late bool _done = widget.item.isDone;
  late int _deferCount = widget.item.deferCount;
  late String? _note = widget.item.handleNote;

  @override
  void didUpdateWidget(covariant _TodoEntryRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final s = widget.item.state;
    if (s == null) return;
    _done = s.isDone;
    _deferCount = s.deferCount;
    _note = s.handleNote;
  }

  TodoAgendaItem get _item => widget.item;

  /// 是否处于「已延期」态（已延期且未完成）。
  ///
  /// 已完成的条目即使延过次，也按「已处理」态显示（划线灰化），
  /// 延期次数仍在副标题里带出（历史不丢）。
  bool get _isDeferred => !_done && _deferCount > 0;

  bool get _writable =>
      widget.writer != null &&
      _item.entry.sourceType != null &&
      _item.entry.sourceId != null;

  Future<void> _toggle() async {
    final writer = widget.writer;
    final entry = _item.entry;
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
      await widget.onChanged();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _done = !next;
      });
    }
  }

  /// 延期：每次 +1 次（按「次」累计，跨天不重置）。
  ///
  /// **交互按元宝裁定③**：点延期让用户在「**延到明天**」与
  /// 「**延到具体日期**」之间选，再填一个延期原因（可留空）。
  ///
  /// 两种选择都写 `next_due_at`（绝对日期），延期次数 +1，
  /// 原因与处理备注同栏（`handle_note`），导出时一并带出（元宝 B3 / B7）。
  Future<void> _defer() async {
    final writer = widget.writer;
    final entry = _item.entry;
    if (writer == null ||
        entry.sourceType == null ||
        entry.sourceId == null) {
      return;
    }
    final choice = await _askDefer();
    if (choice == null) return;
    try {
      await writer.defer(
        entry.sourceType!,
        entry.sourceId!,
        reason: choice.reason.isEmpty ? null : choice.reason,
        dueOn: choice.dueOn,
      );
      await widget.onChanged();
      if (!mounted) return;
      // 明确回显「下一次提示时间」——延期是绝对日期写入，
      // 用户得看见到底推到哪天，不能只看到一个「已延期 N 次」。
      final label = _fmtDay(choice.dueOn);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已延期，下一次提示：$label')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('延期失败：$e')),
      );
    }
  }

  /// `yyyy-MM-dd`。
  static String _fmtDay(DateTime d) {
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  /// 延期弹窗（裁定③）。
  ///
  /// 两种方式：
  /// - **延到明天**（默认）：`next_due_at` = 明天 09:00；
  /// - **延到具体日期**：用户从日期选择器挑一天 → 当天 09:00。
  ///
  /// 09:00 是「当天上午九点」——与日程签新建提醒的默认时刻一致，
  /// 也保证「下一次提示」落在**那一天之内**而不是前一天晚上。
  Future<_DeferChoice?> _askDefer() async {
    final reasonController = TextEditingController(text: '');
    var pickedDate = DateTime.now().add(const Duration(days: 1));
    var useSpecificDate = false;
    return showDialog<_DeferChoice>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          key: const Key('overview_defer_dialog'),
          title: const Text('延期'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ListTile(
                key: const Key('overview_defer_opt_tomorrow'),
                onTap: () => setLocal(() => useSpecificDate = false),
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  useSpecificDate
                      ? Icons.radio_button_unchecked
                      : Icons.radio_button_checked,
                  size: 18,
                ),
                title: const Text('延到明天'),
              ),
              ListTile(
                key: const Key('overview_defer_opt_date'),
                onTap: () => setLocal(() => useSpecificDate = true),
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  useSpecificDate
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                ),
                title: const Text('延到具体日期'),
              ),
              if (useSpecificDate)
                OutlinedButton.icon(
                  key: const Key('overview_defer_pick_date'),
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: pickedDate,
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
                    );
                    if (picked == null) return;
                    setLocal(() => pickedDate = picked);
                  },
                  icon: const Icon(Icons.event),
                  label: Text('延期到 ${_fmtDay(pickedDate)}'),
                ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('overview_defer_reason_field'),
                controller: reasonController,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: '延期原因（可留空）',
                ),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('overview_defer_confirm'),
              onPressed: () {
                final target = useSpecificDate
                    ? pickedDate
                    : DateTime.now().add(const Duration(days: 1));
                Navigator.of(ctx).pop(_DeferChoice(
                  dueOn: DateTime(target.year, target.month, target.day, 9),
                  reason: reasonController.text.trim(),
                ));
              },
              child: const Text('延期'),
            ),
          ],
        ),
      ),
    );
  }

  /// 备注：写「处理备注 / 延期原因」，随条目保存，导出时带出。
  Future<void> _editNote() async {
    final writer = widget.writer;
    final entry = _item.entry;
    if (writer == null ||
        entry.sourceType == null ||
        entry.sourceId == null) {
      return;
    }
    final note = await _askReason(
      title: '备注',
      hint: '处理备注 / 延期原因',
      confirmLabel: '保存',
      initial: _note ?? '',
    );
    if (note == null) return;
    try {
      await writer.setNote(entry.sourceType!, entry.sourceId!, note);
      await widget.onChanged();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$e')),
      );
    }
  }

  /// 弹窗收一条文字（返回 null = 取消）。
  Future<String?> _askReason({
    required String title,
    required String hint,
    required String confirmLabel,
    String initial = '',
  }) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: Key('overview_dialog_$title'),
        title: Text(title),
        content: TextField(
          key: Key('overview_note_field_$title'),
          controller: controller,
          autofocus: true,
          maxLines: 3,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: Key('overview_confirm_$title'),
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entry = _item.entry;
    final dimmed = _done;
    final deferred = _isDeferred;

    final subtitleParts = <String>[
      if (entry.subtitle != null) entry.subtitle!,
      if (_deferCount > 0) '已延期 $_deferCount 次',
      if (_note != null && _note!.isNotEmpty) '备注：$_note',
    ];

    // 已延期态：独立视觉（左侧橙色条 + 角标），与已处理的划线灰化区分开。
    final badge = deferred
        ? Container(
            key: const Key('overview_deferred_badge'),
            margin: const EdgeInsets.only(right: 6),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.orange.shade100,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.orange.shade700),
            ),
            child: Text('已延期 $_deferCount 次',
                style: TextStyle(
                    fontSize: 11, color: Colors.orange.shade900)),
          )
        : null;

    return Container(
      // 已延期的行给一条橙色左边条（独立视觉）。
      decoration: deferred
          ? const BoxDecoration(
              border: Border(
                left: BorderSide(color: Colors.orange, width: 3),
              ),
            )
          : null,
      child: ListTile(
        dense: true,
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
          // 日程类 vs 系统类用图标区分（元宝 B5）。
          Icon(
            widget.item.isSystemHint
                ? Icons.inventory_2_outlined
                : Icons.event_note,
            size: 18,
            color: Colors.grey,
          ),
          Checkbox(
            key: Key('overview_check_${entry.id}'),
            value: _done,
            onChanged: _writable ? (_) => _toggle() : null,
          ),
        ],
        ),
        title: Row(
          children: <Widget>[
            if (badge != null) badge,
            Expanded(
              child: Text(
                entry.title,
                style: TextStyle(
                  decoration: dimmed ? TextDecoration.lineThrough : null,
                  color: dimmed ? Colors.grey : null,
                ),
              ),
            ),
          ],
        ),
        subtitle: subtitleParts.isEmpty
            ? null
            : Text(subtitleParts.join(' · '),
                style: TextStyle(
                  color: dimmed ? Colors.grey : null,
                  decoration: dimmed ? TextDecoration.lineThrough : null,
                )),
        trailing: (_writable && widget.showActions)
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  IconButton(
                    key: Key('overview_defer_${entry.id}'),
                    tooltip: '延期',
                    icon: const Icon(Icons.more_time, size: 20),
                    onPressed: _defer,
                  ),
                  IconButton(
                    key: Key('overview_note_${entry.id}'),
                    tooltip: '备注',
                    icon: const Icon(Icons.sticky_note_2_outlined, size: 20),
                    onPressed: _editNote,
                  ),
                ],
              )
            : null,
      ),
    );
  }
}

/// V4.1 批次 2：**延期选择**（元宝裁定③）。
///
/// 只带两个字段：延到哪天（绝对日期）+ 延期原因。
/// 不给「往后推几天」的相对参数——裁定③要的就是**绝对日期**，
/// 「延到明天」和「延到具体日期」都落到 `next_due_at`。
class _DeferChoice {
  const _DeferChoice({required this.dueOn, required this.reason});

  /// 下一次提示时间（绝对日期，当天 09:00）。
  final DateTime dueOn;

  /// 延期原因（可空，存进 `handle_note`）。
  final String reason;
}

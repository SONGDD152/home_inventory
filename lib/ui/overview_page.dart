import 'package:flutter/material.dart';

import '../data/domain.dart';
import '../data/reminder.dart';
import '../data/todo_state.dart';
import '../domain/overview_reader.dart';
import '../domain/reminder_source.dart';
import '../domain/reminder_sources.dart';
import '../domain/todo_agenda.dart';
import '../domain/todo_state_writer.dart';
import 'reminder_edit_dialog.dart';
import 'schedule_tab_view.dart';

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
    this.editableScheduleDomains = const <InventoryDomain>{},
    this.onCreateReminder,
    this.onEditReminder,
    this.onDeleteReminder,
    this.onListDeletedReminders,
    this.onRestoreReminder,
    this.onPurgeReminder,
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

  /// **开放提醒的域**（批次 3）——只有这些域的日程能新建/编辑/删除。
  ///
  /// 工作域本轮不开放提醒（**能力开关**，不是表缺失），
  /// 所以它不在这个集合里，它的日程条目只读展示。
  final Set<InventoryDomain> editableScheduleDomains;

  /// 新建提醒（由组合根执行写操作）。
  ///
  /// ## 为什么是回调而不是写口
  ///
  /// 元宝批过的写边界四锁之一是「概览页不持仓储类型」。
  /// 如果概览页持一个提醒写接口，就等于**概览区拿到了写能力**——
  /// 「概览改不了账」就只剩约定、不剩编译期保证。
  ///
  /// 所以概览区只**表达意图**（回调），写操作交给组合根
  /// （`home_page.dart`）执行——那里的角色本来就是持有仓储并分发调用。
  /// 这与概览页已有的 `onOpenReport` / `onOpenDomain` 是同一个模式。
  ///
  /// 回调都带 [InventoryDomain] 参数：物理分库下 `reminders` 表每库一张，
  /// 写错库就是数据分裂。
  final Future<void> Function(InventoryDomain domain, ReminderDraft draft)?
      onCreateReminder;

  /// 编辑提醒（组合根执行写操作）。
  final Future<void> Function(
          InventoryDomain domain, int reminderId, ReminderDraft draft)?
      onEditReminder;

  /// 删除提醒（组合根执行写操作；软删进回收站）。
  final Future<void> Function(InventoryDomain domain, int reminderId)?
      onDeleteReminder;

  /// V4.1.3：读某域回收站里的提醒（概览仍只持回调，不持仓储）。
  final Future<List<Reminder>> Function(InventoryDomain domain)?
      onListDeletedReminders;

  /// V4.1.3：从回收站恢复提醒（组合根执行写操作）。
  final Future<void> Function(InventoryDomain domain, int reminderId)?
      onRestoreReminder;

  /// V4.1.3：彻底删除回收站里的提醒（组合根执行写操作）。
  final Future<void> Function(InventoryDomain domain, int reminderId)?
      onPurgeReminder;

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
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: <Widget>[
              _buildReportTab(),
              _buildScheduleTab(),
            ],
          ),
        ),
        // V4.1 批次 4：双签移到**页面底部**（PM 拍板「概览页底栏改双簽」）。
        _buildBottomTabs(),
      ],
    );
  }

  /// V4.1 批次 4：概览页底部的双签（日报 / 日程）。
  ///
  /// ## 为什么签条在概览页内部，而不在 HomePage 的 Scaffold 底栏槽
  ///
  /// HomePage 的 `Scaffold.bottomNavigationBar` 是给「域内一级模块」用的
  /// （生活区四模块 / 工作区一模块），概览分区时它是空的。
  /// 若把双签提到那个槽位，概览页的 [TabBarView] 就得由外部驱动
  /// → 要改 [OverviewPage] 的公开构造 → 批次 2/3 已交付的
  /// v43/v44 专项（107 条）里直接 `OverviewPage(...)` 的构造方式全部要改。
  ///
  /// 所以双签留在概览页内部、但**位置改到页面底部**：
  /// - 观感上就是「页面底部一排签」，与生活区底栏同一层；
  /// - [TabBar] 的 key（`overview_tab_report` / `overview_tab_schedule`）
  ///   一字不变 → 已交付专项测试的点击路径不受影响；
  /// - 底部安全区由 [SafeArea] 处理，不依赖外层 Scaffold。
  ///
  /// 指示线手绘成**顶部**横线：TabBar 默认把指示线画在 tab 下边缘，
  /// 移到页面底部后那条线会贴着屏幕底边，不像「选中标记」，
  /// 反而像误画的边框。
  Widget _buildBottomTabs() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: SafeArea(
        top: false,
        child: TabBar(
          key: const Key('overview_tabs'),
          controller: _tabController,
          indicator: BoxDecoration(
            border: Border(top: BorderSide(color: scheme.primary, width: 3)),
          ),
          indicatorSize: TabBarIndicatorSize.tab,
          labelColor: scheme.primary,
          unselectedLabelColor: scheme.onSurfaceVariant,
          tabs: const <Widget>[
            Tab(
              key: Key('overview_tab_report'),
              icon: Icon(Icons.description_outlined),
              text: '日报',
            ),
            Tab(
              key: Key('overview_tab_schedule'),
              icon: Icon(Icons.event_note_outlined),
              text: '日程',
            ),
          ],
        ),
      ),
    );
  }

  // ───────────────────────── 日报签 ─────────────────────────

  /// V4.1.1 整改 1：**日报签只展示催办**。
  ///
  /// ## 撤掉了什么
  ///
  /// 原来日报签顶部有「生活区 / 工作区」**两张统计卡**
  /// （物品 X 种｜在库｜在借｜废弃未恢复｜总拥有｜账目平衡｜引导语）。
  /// PM 2026-11-27 真机手点红框指定：**整块删除**——
  /// 日报签是「看催办」的，不是「看账目」的，账目数字挤在催办上方
  /// 把真正要处理的事推到了屏幕下面。
  ///
  /// ## 没撤掉什么（重要）
  ///
  /// **概览统计数据的数据来源一个字没删**：
  /// - [OverviewReader] 仍然持有、仍然被调用（[reader] 仍然读两域快照）；
  /// - [_snapshots] 仍然照常填充。
  ///
  /// 撤掉的**只是日报签这一屏的展示**——
  /// 账目快照在**日报导出**里照常出现（`DailyReportService` 独立读快照，
  /// 不经过本页）。
  ///
  /// 催办区因此**上移铺满**腾出的空间。
  Widget _buildReportTab() {
    // ── V4.1.2 真机复验整改：日报签拆成「生活区 / 工作区」**两个独立滚动框** ──
    //
    // ## 产品口径（元宝 2026-11-27 需求澄清，PM 转发确认）
    //
    // 「像聊天框一样滑动」= 两块**各有滚动边界、各滑各的**：
    // 手指在生活区框内上滑只翻生活区条目，在工作区框内上滑只翻工作区条目，
    // 互不带动，**不是整页统一滚到底**。
    //
    // ## 原来为什么错
    //
    // 整页一个 `ListView` 包住两块 → 一屏装不下时只滚整页，
    // 工作区 3 条被截在屏外、拖不到；PM 真机判定不通过。
    //
    // ## 现在的结构
    //
    // 顶部固定（超时卡/加载/错误/「催办」标题行）不滚；
    // 下面两块各拿一半剩余高度（`Expanded` 提供**有界高度**），
    // 每块内部自带独立 `ListView` → 各自可滚、互不干扰。
    // **`Expanded` 是关键**：没有有界高度，内层 ListView 会无限高、滚不起来。
    final blocks = _agendaBlocks();
    return Column(
      key: const Key('overview_page'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
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
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
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
        ),
        const SizedBox(height: 4),
        // 催办区 = 按**区域**分块（整改 4：只分生活区/工作区两块，恒为 2）。
        // 每块 Expanded → 有界高度 → 块内 ListView 各自滚动。
        for (final block in blocks) ...<Widget>[
          Expanded(child: _buildAgendaBox(block)),
        ],
      ],
    );
  }

  /// 单个区域的**独立滚动框**（聊天框式，各滑各的）。
  ///
  /// 只有标题行固定在框顶，条目区是一块 `ListView`：
  /// 本框内容超出框高时在本框内上翻，不带动另一框、也不整页滚动。
  Widget _buildAgendaBox(_AgendaBlock block) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: _buildAgendaBlock(block),
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

  /// V4.1.1 整改 4：**催办块**（按区域分块，**恒为 2 块**）。
  ///
  /// ## PM 拍板的口径（2026-11-27）
  ///
  /// 催办列表**只按区域分成两块**——「生活区」和「工作区」。
  /// **不要拆成四块**（不要「生活区·仓储借出到期 / 工作区·仓储借出到期 /
  /// 生活区·日程提醒 / 工作区·日程提醒」），
  /// **不要任何三级分类、子标签、额外筛选**。
  ///
  /// 生活区集中显示**该区域的**到期与提醒事项，工作区同理——
  /// 同一个区域里，借出到期和日程提醒**混在一起**，用**图标**区分
  /// （借出=箱子，日程=本子），**不再拆成两个分组**。
  ///
  /// ## 为什么这是「结构」而不是「外观」
  ///
  /// 分组是**用户能看见的分类结构**。拆成四块 = 给用户四层心智模型；
  /// 只分两块 = 「我的事」和「公司的事」两堆，符合直觉。
  /// 所以这块的**块数是固定的 2**，不随源数量变化——
  /// 以后再加新源（第三类事项），它落进所属区域，**不新增块**。
  List<_AgendaBlock> _agendaBlocks() {
    final blocks = <_AgendaBlock>[];
    for (final domain in InventoryDomain.values) {
      // V4.2.0 三域骨架：**概览只聚合生活+工作两本账**（PM 2026-11-28
      // 终审拍板「概览不展示知识系统的任何信息」）。知识域能力开关全空，
      // 不开仓储的域不进概览——按能力开关过滤（地基口径，不是 if 补丁），
      // 将来新域开放仓储时自动进入概览，知识域永远不进。
      if (!domainSupports(domain, DomainCapability.storage)) continue;
      final items = <TodoAgendaItem>[];
      // **按条目 id 去重**——同一个条目只渲染一次。
      //
      // ## 为什么必须去重
      //
      // 催办块是**按区域**聚合的（整改 4），一个区域的条目来自**多个源**
      // （借出到期 + 日程提醒…）。如果两个源给出了**同一条目 id**
      // （比如两个源都注册了 `loan_due_life`），
      // 聚合后同一个 key 会出现两次 → Flutter 抛
      // 「Duplicate keys found」→ **整页 build 崩掉**。
      //
      // 这正是 E1（源 id 撞车）的**聚合层翻版**：
      // 单看每个源都正常，**一聚到一块就炸**。
      //
      // 所以这里按 `entry.id` 去重（先到先得）——
      // 与概览 Map 用 `source.id` 作 key 是同一个防撞思路。
      final seen = <String>{};
      for (final source in widget.sources) {
        // 只收属于该区域的源（条目本身也带域，这里再按源 id 判一次）。
        if (!_sourceBelongsToDomain(source, domain)) continue;
        for (final item in _agendaItems(source)) {
          if (!seen.add(item.entry.id)) continue;
          items.add(item);
        }
      }
      // 块内排序：按优先级（裁定①）——借出到期（高）在前。
      TodoAgenda.sortByPriority(items);
      blocks.add(_AgendaBlock(domain, items));
    }
    return blocks;
  }

  /// 某个源是否属于该区域。
  ///
  /// 源 id 一律带域（`loan_due_life` / `schedule_reminders_work`…），
  /// 所以直接看后缀即可——不靠解析 displayName（那是给人看的文案）。
  bool _sourceBelongsToDomain(ReminderSource source, InventoryDomain domain) {
    final entries = _entriesBySource[source.id] ?? const <OverviewEntry>[];
    // 源里一条条目都没有 → 它不贡献这个区域（空块就不该出现）。
    if (entries.isEmpty) return false;
    return entries.any((e) => e.domain == domain);
  }

  /// 取某个域的待办状态写入口（null = 该域没有该能力 → 该域条目只读展示）。
  TodoStateWriter? _writerOf(InventoryDomain? domain) {
    if (domain == null) return null;
    return widget.todoWriters[domain];
  }

  /// 催办块（整改 4：**按区域**，恒为「生活区 / 工作区」两块）。
  ///
  /// 块内**混合**该区域的到期与提醒事项，用图标区分类型
  /// （元宝裁定⑤的图标区分保留，但**不再作为分组依据**）。
  Widget _buildAgendaBlock(_AgendaBlock block) {
    final items = block.items;
    final domain = block.domain;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 本框高度由外层 `Expanded` 给定（有界）。标题行（icon + 标题 +
        // 副标题 + childrenPadding）约占 84px，剩下的高度才是条目滚动区。
        // **`ListView` 必须有有界高度才会滚**——无界时它会撑到内容那么高，
        // 表现为「截在屏外、拖不动」，正是真机复验的不通过现象。
        // 标题行用 dense ListTile（约 64px）+ childrenPadding 4 → 预留 72px。
        const headerReserve = 72.0;
        final listHeight =
            (constraints.maxHeight - headerReserve).clamp(0.0, double.infinity);
        return ExpansionTile(
          key: Key('overview_block_${domain.id}'),
          initiallyExpanded: true,
          tilePadding: EdgeInsets.zero,
          dense: true,
          childrenPadding: const EdgeInsets.only(bottom: 4),
          leading: Icon(
            domain == InventoryDomain.life
                ? Icons.home_outlined
                : Icons.business_outlined,
            size: 20,
            color: Colors.grey,
          ),
          title: Text(domain.label,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          subtitle: Text(items.isEmpty ? '暂无待办' : '共 ${items.length} 条待办',
              style: const TextStyle(fontSize: 12)),
          children: items.isEmpty
              ? <Widget>[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text('暂无待办', style: TextStyle(color: Colors.grey)),
                  ),
                  // 整改 1：统计卡整块撤掉后，原先挂在卡里的
                  // 「去工作区建首个位置」引导改挂到**工作区的空催办块**上——
                  // 引导语还在（不丢入口），但它现在属于「催办」这一屏，
                  // 而不是混在账目数字里。
                  if (domain == InventoryDomain.work &&
                      widget.onOpenDomain != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const Key('overview_empty_goto_work'),
                        onPressed: () =>
                            widget.onOpenDomain!(InventoryDomain.work),
                        icon: const Icon(Icons.arrow_forward),
                        label: const Text('去工作区建首个位置'),
                      ),
                    ),
                ]
              : <Widget>[
                  SizedBox(
                    // V4.1.3 真机排版整改：ExpansionTile 的子列用松约束，
                    // 只给高度时子项会「缩到内容宽再居中」→ 文字列只剩两字宽、
                    // 整行看着居中、右侧大片留白。钉死 width: double.infinity
                    // 让滚动框铺满本域块的横向空间，条目从左往右排。
                    width: double.infinity,
                    height: listHeight,
                    child: ListView(
                      key: Key('overview_block_list_${domain.id}'),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      // 非懒加载：所有条目都在 widget 树上（折叠/查找断言依赖），
                      // 但 scrollable 有界 → 超出框高的部分可在框内上翻。
                      children: items
                          .map((item) => _TodoEntryRow(
                                key: Key('overview_entry_${item.entry.id}'),
                                item: item,
                                // 按条目所属域取写口——物理分库下每库一张 todo_states。
                                writer: _writerOf(item.entry.domain),
                                onChanged: _onRowStateChanged,
                              ))
                          .toList(),
                    ),
                  ),
                ],
        );
      },
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
    return ScheduleTabView(
      entries: _scheduleEntries(),
      todoWriters: widget.todoWriters,
      statesByKey: _statesByKey,
      editableDomains: widget.editableScheduleDomains,
      onCreateReminder: widget.onCreateReminder,
      onEditReminder: widget.onEditReminder,
      onDeleteReminder: widget.onDeleteReminder,
      onListDeletedReminders: widget.onListDeletedReminders,
      onRestoreReminder: widget.onRestoreReminder,
      onPurgeReminder: widget.onPurgeReminder,
      onChanged: _reload,
    );
  }

  /// 跨域聚合的日程条目（两域排在一起，每条带域标识）。
  ///
  /// **只收日程类**（`reminders` 表），不收借出到期——那是系统类，
  /// 归日报签的催办区管。
  ///
  /// 跨域展示（批次 3 ②）：工作域的 `reminders` 表**建齐但永远为空**
  /// （能力开关，本轮不开放提醒），所以工作域那组会显示「暂无日程」
  /// 或「该区域暂不支持提醒」——**能看、能区分，但没有可看的内容**。
  List<ScheduleTabEntry> _scheduleEntries() {
    final entries = <ScheduleTabEntry>[];
    for (final domain in InventoryDomain.values) {
      for (final source in widget.sources) {
        if (source is! ScheduleReminderSource) continue;
        if (source.domain != domain) continue;
        for (final entry in _entriesBySource[source.id] ?? const <OverviewEntry>[]) {
          if (entry.sourceId == null) continue;
          entries.add(ScheduleTabEntry(
            id: entry.id,
            title: entry.title,
            domain: domain,
            reminderId: entry.sourceId!,
            dueAt: entry.dueAt,
            priority: entry.priority,
            repeatRule: entry.repeatRule,
            done: entry.done,
          ));
        }
      }
    }
    // 排序：到期日近的在前；同一天按域 + 标题。
    entries.sort((a, b) {
      const far = 1 << 62;
      final byDue = (a.dueAt ?? far).compareTo(b.dueAt ?? far);
      if (byDue != 0) return byDue;
      final byDomain = a.domain.id.compareTo(b.domain.id);
      if (byDomain != 0) return byDomain;
      return a.title.compareTo(b.title);
    });
    return entries;
  }
}

/// V4.1.1 整改 4：**一个催办块**（= 一个区域的生活/工作）。
///
/// ## 块数恒为 2（PM 拍板）
///
/// 催办列表**只按区域分块**——生活区一块、工作区一块。
/// 块内**混合**该区域的到期与提醒事项（用图标区分类型），
/// **不设三级分类、子标签、额外筛选**。
///
/// 以后加新源（第三类事项），它落进所属区域，**不新增块**。
class _AgendaBlock {
  const _AgendaBlock(this.domain, this.items);

  /// 这一块属于哪个区域。
  final InventoryDomain domain;

  /// 这一块里的催办条目（按优先级排好序）。
  final List<TodoAgendaItem> items;
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
  });

  final TodoAgendaItem item;
  final TodoStateWriter? writer;

  /// 状态变化后通知父级刷新共享状态（让另一个签同步）。
  final Future<void> Function() onChanged;

  @override
  State<_TodoEntryRow> createState() => _TodoEntryRowState();
}

class _TodoEntryRowState extends State<_TodoEntryRow> {
  // V4.1.4 三态：pending 空框 / in_progress 半框 / done 满框。
  late String _status = widget.item.isDone
      ? TodoStatus.done
      : (widget.item.isInProgress ? TodoStatus.inProgress : TodoStatus.pending);
  late int _deferCount = widget.item.deferCount;
  late String? _note = widget.item.handleNote;

  /// 完成态（下游划线灰化 / 延期视觉沿用）。
  bool get _done => _status == TodoStatus.done;

  @override
  void didUpdateWidget(covariant _TodoEntryRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final s = widget.item.state;
    if (s == null) return;
    _status = s.isDone
        ? TodoStatus.done
        : (s.isInProgress ? TodoStatus.inProgress : TodoStatus.pending);
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

  /// V4.1.4：三态循环——空→半→满→空；走 setTodoStatus（UI 只持回调）。
  Future<void> _toggle() async {
    final writer = widget.writer;
    final entry = _item.entry;
    if (writer == null ||
        entry.sourceType == null ||
        entry.sourceId == null) {
      return;
    }
    final next = TodoStatus.next(_status);
    final prev = _status;
    // 乐观更新：先改本地状态（只重建这一行），写库失败再回滚。
    setState(() {
      _status = next;
    });
    try {
      await writer.setTodoStatus(
          entry.sourceType!, entry.sourceId!, next);
      await widget.onChanged();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _status = prev;
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
    } on ArgumentError catch (e) {
      // 裁定④：选了早于当前提示日的日子 → 这次延期被忽略。
      // 说清为什么没成，别让用户以为延期成功了。
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message?.toString() ?? '延期失败')),
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

  /// 延期弹窗（裁定③ + 裁定④修订）。
  ///
  /// 两种方式：
  /// - **延到明天**（默认）：`next_due_at` = 明天 09:00；
  /// - **延到具体日期**：用户从日期选择器挑一天 → 当天 09:00。
  ///
  /// 09:00 是「当天上午九点」——与日程签新建提醒的默认时刻一致，
  /// 也保证「下一次提示」落在**那一天之内**而不是前一天晚上。
  ///
  /// ## 裁定④：只往后推，不许回拉
  ///
  /// 日期选择器的 `firstDate` 直接设在「当前下一次提示日」——
  /// 用户**挑不到**更早的日子，不是挑完再被驳回。
  /// 边界是硬的：数据层还会再校验一次（见 `InventoryDatabase.defer`）。
  Future<_DeferChoice?> _askDefer() async {
    final reasonController = TextEditingController(text: '');
    // 当前下一次提示日 = next_due_at 优先，否则源条目原到期日，
    // 再没有就以「今天」为基准（只能往后推）。
    final now = DateTime.now();
    final anchorMs = _item.nextDueAt ?? _item.sourceDueAt;
    final anchorDay = anchorMs == null
        ? DateTime(now.year, now.month, now.day)
        : DateTime.fromMillisecondsSinceEpoch(anchorMs);
    // 最早可选日 = 基准日当天（当天不算回拉，往后推就行）。
    final minDay = DateTime(anchorDay.year, anchorDay.month, anchorDay.day);
    var pickedDate = DateTime(now.year, now.month, now.day)
        .add(const Duration(days: 1));
    if (pickedDate.isBefore(minDay)) pickedDate = minDay;
    // 「延到明天」是否合法：明天必须不早于基准日。
    final tomorrow = DateTime(now.year, now.month, now.day)
        .add(const Duration(days: 1));
    final tomorrowIsValid = !tomorrow.isBefore(minDay);
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
                // 裁定④：「延到明天」也可能是**回拉**——条目已经延到 3 天后，
                // 再延到明天就是往前拉。所以这一步先算出「明天」相对
                // 基准日的位置，不合法就把这个选项禁用。
                title: Text(
                  tomorrowIsValid ? '延到明天' : '延到明天（早于当前提示日）',
                  key: const Key('overview_defer_opt_tomorrow_text'),
                  style: TextStyle(
                    color: tomorrowIsValid ? null : Colors.grey,
                  ),
                ),
                enabled: tomorrowIsValid,
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
              if (useSpecificDate) ...<Widget>[
                OutlinedButton.icon(
                  key: const Key('overview_defer_pick_date'),
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: pickedDate,
                      // 裁定④：只往后推 → 早于当前提示日的日子**挑不到**。
                      firstDate: minDay,
                      lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
                    );
                    if (picked == null) return;
                    setLocal(() => pickedDate = picked);
                  },
                  icon: const Icon(Icons.event),
                  label: Text('延期到 ${_fmtDay(pickedDate)}'),
                ),
                const SizedBox(height: 4),
                // 明说规矩，别让用户以为是自己选错了。
                Text(
                  '只能往后推，最早 ${_fmtDay(minDay)}',
                  key: const Key('overview_defer_min_hint'),
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
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
                    : tomorrow;
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
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        // V4.1.3 真机排版整改：勾选框在最前，标题/副标题从它右边起
        // 一整行从左往右排；文字区 Expanded 占满剩余宽度、单行不折字。
        leading: Checkbox(
          key: Key('overview_check_${entry.id}'),
          // V4.1.4 三态：tristate 的 null 横线由绘制引擎画，避开 M3 glyph 坑。
          tristate: true,
          value: _status == TodoStatus.done
              ? true
              : (_status == TodoStatus.inProgress ? null : false),
          onChanged: _writable ? (_) => _toggle() : null,
        ),
        title: Row(
          children: <Widget>[
            if (badge != null) badge,
            Expanded(
              child: Text(
                entry.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
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
            : Row(
                children: <Widget>[
                  // 元宝 B5 的类型图标保留（源码级测试锁着），但挪到
                  // 信息行首，不再挡在勾选框与标题之间。
                  Icon(
                    widget.item.isSystemHint
                        ? Icons.inventory_2_outlined
                        : Icons.event_note,
                    size: 16,
                    color: Colors.grey,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      subtitleParts.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: dimmed ? Colors.grey : null,
                        decoration: dimmed ? TextDecoration.lineThrough : null,
                      ),
                    ),
                  ),
                ],
              ),
        trailing: _writable
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  // V4.1.2 真机整改：原用 `Icons.more_time` /
                  // `Icons.sticky_note_2_outlined`（较新的 M3 glyph），
                  // 真机上字体回退成竖排「仑」状怪字（PM 2026-11-27 截图）。
                  // 换成 MaterialIcons 经典 glyph：access_time / comment，
                  // 与项目 V3.5「M3 图标真机不渲染」教训同类处置。
                  IconButton(
                    key: Key('overview_defer_${entry.id}'),
                    tooltip: '延期',
                    icon: const Icon(Icons.access_time, size: 20),
                    onPressed: _defer,
                  ),
                  IconButton(
                    key: Key('overview_note_${entry.id}'),
                    tooltip: '备注',
                    icon: const Icon(Icons.comment, size: 20),
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

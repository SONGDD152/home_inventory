import 'package:flutter/material.dart';

import '../data/domain.dart';
import '../domain/overview_reader.dart';
import '../domain/reminder_source.dart';

/// V4.0：概览页（**只读**）。
///
/// 顶栏 [概览][生活][工作] 的第一项，与生活区/工作区**同级**（PM 拍板）。
///
/// 只读在**代码层**落实：本页只持有 [OverviewReader]（只读查询口）
/// 与 [ReminderSource]（只给条目列表），**拿不到任何可写仓库实例**——
/// 想在概览里改数据，编译期就做不到。
class OverviewPage extends StatefulWidget {
  const OverviewPage({
    super.key,
    required this.reader,
    required this.sources,
    this.switchTimeoutCount = 0,
  });

  /// 两域账目快照的只读读取口。
  final OverviewReader reader;

  /// 提醒源注册表（统一接口，概览代码不因新增源而改）。
  final List<ReminderSource> sources;

  /// 切库超时次数（**用户可见**：切库降级不是静默的）。
  final int switchTimeoutCount;

  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage> {
  List<DomainOverview>? _snapshots;
  final Map<String, List<OverviewEntry>> _entriesBySource =
      <String, List<OverviewEntry>>{};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
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
        entries[source.displayName] = await source.loadEntries();
      }
      if (!mounted) return;
      setState(() {
        _snapshots = snapshots;
        _entriesBySource
          ..clear()
          ..addAll(entries);
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
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        key: const Key('overview_page'),
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          const Text('概览',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
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
          for (final source in widget.sources) ...<Widget>[
            const SizedBox(height: 8),
            Text(source.displayName,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            ..._entryWidgets(source.displayName),
          ],
        ],
      ),
    );
  }

  Widget _snapshotCard(DomainOverview snapshot) {
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
          ],
        ),
      ),
    );
  }

  List<Widget> _entryWidgets(String sourceName) {
    final entries = _entriesBySource[sourceName] ?? const <OverviewEntry>[];
    if (entries.isEmpty) {
      return <Widget>[
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: Text('暂无待办', style: TextStyle(color: Colors.grey)),
        ),
      ];
    }
    return entries.map((entry) {
      return ListTile(
        key: Key('overview_entry_${entry.id}'),
        dense: true,
        leading: Icon(entry.done ? Icons.check_circle : Icons.radio_button_unchecked,
            color: entry.done ? Colors.green : null),
        title: Text(entry.title),
        subtitle: entry.subtitle == null ? null : Text(entry.subtitle!),
      );
    }).toList();
  }
}

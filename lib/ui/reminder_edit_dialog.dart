import 'package:flutter/material.dart';

import '../data/domain.dart';
import '../data/reminder.dart';
import '../domain/repeat_rule.dart';

/// V4.1 批次 3：**提醒编辑弹窗**（新建 / 编辑共用）。
///
/// ## 为什么抽出来
///
/// V4.0 的提醒编辑弹窗长在已删除的 `schedule_page.dart` 里。批次 3 要让
/// **概览页的日程签**也能新建 / 编辑提醒——如果各写一份，
/// 迟早两处字段漂移（一边有优先级一边没有、一边能设重复一边不能）。
///
/// 所以抽成共用的一份：**两处入口，同一套字段**。
///
/// V4.1 批次 4：日程上移概览层后，**唯一入口是概览页的日程签**
/// （旧生活区日程页已删，见 `home_module.dart` 的说明）。
/// 本弹窗现在只服务概览页日程签一处，但**保留共用形态**——
/// 将来若再长出第二个提醒入口，不必再抽一次。
///
/// ## V4.1.1 整改 2：为什么改成 StatefulWidget（而不是静态方法 + 局部 controller）
///
/// **原实现有个真机级缺陷**：静态 `show()` 里 `await showDialog(...)` 返回后
/// **立刻 `dispose()` 两个 TextEditingController**。
///
/// 但 `showDialog` 返回时，弹窗的**退出动画还没播完**——对话框还在
/// `Overlay` 里做反向动画，它的 `TextField` 会在这段时间继续 rebuild，
/// 一 rebuild 就撞上「controller 已被 dispose」→
/// 抛 `A TextEditingController was used after being disposed` →
///
/// **整个页面的 build 被打断**（后面还跟着
/// `'_dependents.isEmpty': is not true` 与
/// `Tried to build dirty widget in the wrong build scope`）。
///
/// 用户看到的就是：**新建完提醒之后页面状态就废了，日程列表再也拖不动**
/// （PM 2026-11-27 真机手点报「日程提醒列表不可滚动」——真因在此，
/// 不是手势被抢）。
///
/// 修法：把弹窗改成 `StatefulWidget`，controller 随 `State` 生命周期，
/// **`dispose` 由框架在组件真正卸载时调用**——那时动画早已结束。
class ReminderEditDialog extends StatefulWidget {
  const ReminderEditDialog({
    super.key,
    this.existing,
    this.domainOptions = const <InventoryDomain>[],
    this.initialDomain,
  });

  /// 正在编辑的那条（null = 新建）。
  final Reminder? existing;

  /// **可选区域**（整改 3：新建时必选生活区/工作区，二选一）。
  ///
  /// 空 = 不显示区域选择（编辑时用——一条提醒已经属于某本账，不改归属）。
  final List<InventoryDomain> domainOptions;

  /// 新建时的**预选区域**（null = 不预选，用户必须自己选）。
  ///
  /// **整改 3：去掉默认落区**——不预选，逼用户明确表态落哪本账。
  final InventoryDomain? initialDomain;

  /// 打开编辑弹窗；返回 null = 用户取消。
  static Future<ReminderDraft?> show(
    BuildContext context, {
    Reminder? existing,
    List<InventoryDomain> domainOptions = const <InventoryDomain>[],
    InventoryDomain? initialDomain,
  }) {
    return showDialog<ReminderDraft>(
      context: context,
      builder: (_) => ReminderEditDialog(
        existing: existing,
        domainOptions: domainOptions,
        initialDomain: initialDomain,
      ),
    );
  }

  @override
  State<ReminderEditDialog> createState() => _ReminderEditDialogState();
}

class _ReminderEditDialogState extends State<ReminderEditDialog> {
  late final TextEditingController _titleController =
      TextEditingController(text: widget.existing?.title ?? '');
  late final TextEditingController _detailController =
      TextEditingController(text: widget.existing?.detail ?? '');

  late DateTime? _dueAt = widget.existing?.dueAt == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(widget.existing!.dueAt!);

  /// 优先级（裁定①）：高 / 中 / 低，默认中。
  late int _priority = ReminderPriority.normalize(widget.existing?.priority);

  /// 重复规则（批次 3）：不重复 / 每天 / 每周 / 每月 / 每年。
  late String? _repeatRule = RepeatRule.normalize(widget.existing?.repeatRule);

  /// **整改 3：新建时的区域选择**（null = 还没选）。
  ///
  /// 默认 null —— **不预选**，用户必须自己选；
  /// 不选时「保存」按钮不可用（不能存）。
  late InventoryDomain? _domain = widget.initialDomain;

  /// 是否处于「新建」模式。
  bool get _isNew => widget.existing == null;

  /// 是否必须选区域（新建 + 提供了选项）。
  bool get _requiresDomain =>
      _isNew && widget.domainOptions.length > 1;

  /// 「保存」按钮是否可用。
  ///
  /// 标题为空不行；**整改 3：新建时没选区域也不行**。
  bool get _canSave {
    if (_titleController.text.trim().isEmpty) return false;
    if (_requiresDomain && _domain == null) return false;
    return true;
  }

  @override
  void dispose() {
    // 组件真正卸载时才 dispose —— 退出动画早已结束，不会再有人用它。
    _titleController.dispose();
    _detailController.dispose();
    super.dispose();
  }

  void _save() {
    if (!_canSave) return;
    final title = _titleController.text.trim();
    Navigator.of(context).pop(ReminderDraft(
      title: title,
      detail: _detailController.text.trim().isEmpty
          ? null
          : _detailController.text.trim(),
      dueAt: _dueAt,
      priority: _priority,
      repeatRule: _repeatRule,
      domain: _domain,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('reminder_edit_dialog'),
      title: Text(_isNew ? '新增提醒' : '编辑提醒'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              key: const Key('reminder_title_field'),
              controller: _titleController,
              decoration: const InputDecoration(labelText: '标题'),
              // 标题变了要重算「保存」能不能点。
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              key: const Key('reminder_detail_field'),
              controller: _detailController,
              decoration: const InputDecoration(labelText: '备注（可空）'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('reminder_due_pick'),
              onPressed: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _dueAt ?? DateTime.now(),
                  firstDate: DateTime.now().subtract(const Duration(days: 365)),
                  lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
                );
                if (picked == null) return;
                setState(() {
                  _dueAt = DateTime(picked.year, picked.month, picked.day, 9);
                });
              },
              icon: const Icon(Icons.event),
              label: Text(_dueAt == null
                  ? '选日期（可选）'
                  : '日期：${_dueAt!.month}月${_dueAt!.day}日'),
            ),
            // ── 整改 3：新建时**必选区域**（二选一，不选不能存）────────
            if (_requiresDomain) ...<Widget>[
              const SizedBox(height: 12),
              _SectionLabel('放在哪个区'),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                children: <Widget>[
                  for (final d in widget.domainOptions)
                    ChoiceChip(
                      key: Key('reminder_domain_${d.id}'),
                      label: Text(d.label),
                      selected: _domain == d,
                      onSelected: (_) => setState(() => _domain = d),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                _domain == null
                    ? '请选择要放在生活区还是工作区'
                    : '将存进${_domain!.label}',
                key: const Key('reminder_domain_hint'),
                style: TextStyle(
                  fontSize: 11,
                  color: _domain == null ? Colors.red : Colors.grey,
                ),
              ),
            ],
            const SizedBox(height: 12),
            _SectionLabel('优先级'),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: <Widget>[
                for (final p in ReminderPriority.all)
                  ChoiceChip(
                    key: Key('reminder_priority_$p'),
                    label: Text(ReminderPriority.labelOf(p)),
                    selected: _priority == p,
                    onSelected: (_) => setState(() => _priority = p),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              priorityHint(_priority),
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            _SectionLabel('重复'),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: <Widget>[
                for (final r in <String?>[null, ...RepeatRule.all])
                  ChoiceChip(
                    key: Key('reminder_repeat_${r ?? 'none'}'),
                    label: Text(RepeatRule.labelOf(r)),
                    selected: _repeatRule == r,
                    onSelected: (_) => setState(() => _repeatRule = r),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          key: const Key('reminder_save'),
          // 整改 3：没选区域时**不能存**（按钮置灰）。
          onPressed: _canSave ? _save : null,
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 优先级提示文案（把「提前几天进催办区」讲明白）。
String priorityHint(int priority) {
  final days = ReminderPriority.leadDaysOf(priority);
  if (days <= 0) return '到期当天才进催办区';
  return '到期前 $days 天进催办区';
}

/// 弹窗里的小节标题。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 13,
        color: Theme.of(context).colorScheme.outline,
      ),
    );
  }
}

/// V4.1 批次 3：提醒编辑弹窗的返回值。
class ReminderDraft {
  const ReminderDraft({
    required this.title,
    this.detail,
    this.dueAt,
    this.priority = ReminderPriority.normal,
    this.repeatRule,
    this.domain,
  });

  final String title;
  final String? detail;
  final DateTime? dueAt;

  /// 优先级（0 低 / 1 中 / 2 高）——元宝裁定①。
  final int priority;

  /// 重复规则（null = 不重复）——批次 3。
  final String? repeatRule;

  /// **整改 3：这条提醒落在哪个区**（null = 未指定 / 编辑既有条目）。
  ///
  /// 物理分库下 `reminders` 表**每库一张**——落错库就是数据分裂，
  /// 所以新建时**必须**明确（界面不预选，用户自己选）。
  final InventoryDomain? domain;
}

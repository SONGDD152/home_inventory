import 'package:flutter/material.dart';

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
class ReminderEditDialog {
  const ReminderEditDialog._();

  /// 打开编辑弹窗；返回 null = 用户取消。
  ///
  /// [existing] = null 表示新建，否则是正在编辑的那条。
  static Future<ReminderDraft?> show(
    BuildContext context, {
    Reminder? existing,
  }) async {
    final titleController = TextEditingController(text: existing?.title ?? '');
    final detailController = TextEditingController(text: existing?.detail ?? '');
    DateTime? dueAt = existing?.dueAt == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(existing!.dueAt!);
    // 优先级（裁定①）：高 / 中 / 低，默认中。
    var priority = ReminderPriority.normalize(existing?.priority);
    // 重复规则（批次 3）：不重复 / 每天 / 每周 / 每月 / 每年。
    var repeatRule = RepeatRule.normalize(existing?.repeatRule);

    final result = await showDialog<ReminderDraft>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          key: const Key('reminder_edit_dialog'),
          title: Text(existing == null ? '新增提醒' : '编辑提醒'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
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
                        selected: priority == p,
                        onSelected: (_) => setLocal(() => priority = p),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  priorityHint(priority),
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
                        selected: repeatRule == r,
                        onSelected: (_) => setLocal(() => repeatRule = r),
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
              onPressed: () {
                final title = titleController.text.trim();
                if (title.isEmpty) return;
                Navigator.of(context).pop(ReminderDraft(
                  title: title,
                  detail: detailController.text.trim().isEmpty
                      ? null
                      : detailController.text.trim(),
                  dueAt: dueAt,
                  priority: priority,
                  repeatRule: repeatRule,
                ));
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    titleController.dispose();
    detailController.dispose();
    return result;
  }

  /// 优先级提示文案（把「提前几天进催办区」讲明白）。
  static String priorityHint(int priority) {
    final days = ReminderPriority.leadDaysOf(priority);
    if (days <= 0) return '到期当天才进催办区';
    return '到期前 $days 天进催办区';
  }
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
  });

  final String title;
  final String? detail;
  final DateTime? dueAt;

  /// 优先级（0 低 / 1 中 / 2 高）——元宝裁定①。
  final int priority;

  /// 重复规则（null = 不重复）——批次 3。
  final String? repeatRule;
}

import 'package:flutter/material.dart';

import '../data/backup_gateway.dart';
import '../data/daily_report_service.dart';

/// V4.0：日报页（查看 / 编辑 / 导出）。
///
/// 导出两种格式：
///  * `.md` —— 零新增依赖（复用 [BackupGateway.saveBytesToDevice]）；
///  * `.docx` —— 自研最小 OOXML 生成器（**不引任何原生插件**）。
class DailyReportPage extends StatefulWidget {
  const DailyReportPage({
    super.key,
    required this.service,
    this.gateway,
    this.date,
  });

  /// 日报服务（生成内容 + 导出字节）。
  final DailyReportService service;

  /// 备份网关（保存到手机 / 分享）。
  final BackupGateway? gateway;

  /// 报告日期（默认今天）。
  final DateTime? date;

  @override
  State<DailyReportPage> createState() => _DailyReportPageState();
}

class _DailyReportPageState extends State<DailyReportPage> {
  late DateTime _date = widget.date ?? DateTime.now();
  final TextEditingController _controller = TextEditingController();
  bool _loading = true;
  bool _busy = false;

  BackupGateway get _gateway => widget.gateway ?? SystemBackupGateway();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final key = DailyReportService.formatDate(_date);
    var content = '';
    final existing = await widget.service.reminders.getDailyReport(key);
    if (existing != null) {
      content = existing.contentMd;
    } else {
      content = await widget.service.buildContent(_date);
    }
    if (!mounted) return;
    setState(() {
      _controller.text = content;
      _loading = false;
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 30)),
    );
    if (picked == null) return;
    setState(() => _date = picked);
    await _load();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    await widget.service.reminders.saveDailyReport(
      DailyReportService.formatDate(_date),
      _controller.text,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('日报已保存。')),
    );
  }

  Future<void> _exportMarkdown() async {
    setState(() => _busy = true);
    try {
      final bytes = await widget.service.buildMarkdown(_date);
      final name =
          '家庭仓储日报-${DailyReportService.formatDate(_date)}.md';
      final saved = await _gateway.saveBytesToDevice(name, bytes);
      if (!mounted) return;
      if (saved != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已保存：$name')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败：$e')),
      );
    }
    if (!mounted) return;
    setState(() => _busy = false);
  }

  Future<void> _exportDocx() async {
    setState(() => _busy = true);
    try {
      final bytes = await widget.service.buildDocx(_date);
      final name =
          '家庭仓储日报-${DailyReportService.formatDate(_date)}.docx';
      final saved = await _gateway.saveBytesToDevice(name, bytes);
      if (!mounted) return;
      if (saved != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已保存：$name')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败：$e')),
      );
    }
    if (!mounted) return;
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('日报'),
        actions: <Widget>[
          IconButton(
            key: const Key('report_pick_date'),
            tooltip: '选日期',
            onPressed: _loading ? null : _pickDate,
            icon: const Icon(Icons.event),
          ),
        ],
      ),
      body: _loading
          // 静态文字而不是持续转的 CircularProgressIndicator：
          // 持续动画会让 widget 测试的 pumpAndSettle 永远等不到静止帧
          // （V4.1 批次 1 踩过的坑：概览页测试卡死 16 分钟）。
          ? const Center(child: Text('加载中…'))
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: <Widget>[
                  Text('日期：${DailyReportService.formatDate(_date)}',
                      key: const Key('report_date_label')),
                  const SizedBox(height: 8),
                  Expanded(
                    child: TextField(
                      key: const Key('report_content'),
                      controller: _controller,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: '日报内容（可编辑）',
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: <Widget>[
                      FilledButton(
                        key: const Key('report_save'),
                        onPressed: _busy ? null : _save,
                        child: const Text('保存'),
                      ),
                      OutlinedButton(
                        key: const Key('report_export_md'),
                        onPressed: _busy ? null : _exportMarkdown,
                        child: const Text('导出 .md'),
                      ),
                      OutlinedButton(
                        key: const Key('report_export_docx'),
                        onPressed: _busy ? null : _exportDocx,
                        child: const Text('导出 .docx'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
    );
  }
}

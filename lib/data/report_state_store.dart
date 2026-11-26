import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// V4.0：日报「每日一次」判据的持久化口。
///
/// 为什么要存状态：日报是"每天第一次打开 App 时补生成昨天"，
/// **不做后台定时**（纯单机没有后台常驻能力）。
/// 判据必须跨启动记住，否则每次冷启动都会重复补生成。
///
/// 这里只存"已处理过的日期集合"——不是"上次检查日期"：
/// 只记上次日期的话，手机时间被调回昨天，跨日判据会失效、
/// 重复补生成（元宝第三轮点名要求）。
abstract class ReportStateStore {
  /// 已处理过的日期集合（`yyyy-MM-dd`）。
  Future<List<String>> handledDates();

  /// 记下一个已处理的日期。
  Future<void> markHandled(String date);
}

/// 内存实现（测试用）。
class InMemoryReportStateStore implements ReportStateStore {
  final Set<String> _dates = <String>{};

  @override
  Future<List<String>> handledDates() async => _dates.toList();

  @override
  Future<void> markHandled(String date) async {
    _dates.add(date);
  }
}

/// 生产实现：应用私有目录下一个 JSON 文件。
class FileReportStateStore implements ReportStateStore {
  FileReportStateStore({this.fileName = 'daily_report_state.json'});

  final String fileName;

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, fileName));
  }

  @override
  Future<List<String>> handledDates() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return <String>[];
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <String>[];
      return decoded.whereType<String>().toList();
    } catch (_) {
      // 状态文件损坏/读不到 → 当作"没处理过"，宁可多补一次也不崩。
      return <String>[];
    }
  }

  @override
  Future<void> markHandled(String date) async {
    try {
      final file = await _file();
      final dates = await handledDates();
      if (dates.contains(date)) return;
      dates.add(date);
      await file.writeAsString(jsonEncode(dates), encoding: utf8);
    } catch (_) {
      // 写不进去也不能影响主流程（日报只是附加功能）。
    }
  }
}

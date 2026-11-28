/// V4.3.1（+38 P0-1）全系统备份内档自动轮转。
///
/// PM 口径：全系统备份本地保留最近 3 份，不无限堆积；
/// 超 3 份时最旧一份自动覆盖删除（物理删，不进回收站——
/// 备份内档不是业务数据，不适用「软删留底」红线）；
/// 轮转发生时记一行「备份轮转，删除 xxx.json」。
///
/// 红线：轮转只删**备份文件**（内档目录里的 .json），不碰任何业务数据。
/// 纯本地、不联网。
///
/// 为什么要有内档目录：用户经系统分享/SAF 保存的文件散落在用户自己选的位置，
/// App 无权枚举清理；内档目录（应用私有文档目录/backups）才是 App 能
/// 自主管理的「本地最近 3 份」。每次导出成功后同步留一份内档。
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

class BackupArchiver {
  BackupArchiver({Future<Directory> Function()? directoryResolver, int? keepCount})
      : _directoryResolver = directoryResolver,
        keepCount = keepCount ?? 3;

  /// 本地保留份数（PM 口径：最近 3 份）。
  final int keepCount;

  final Future<Directory> Function()? _directoryResolver;

  Future<Directory> _dir() async {
    final resolver = _directoryResolver;
    if (resolver != null) return resolver();
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}${Platform.pathSeparator}backups');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// 写入一份内档并按份数轮转。
  ///
  /// 返回被删除的最旧备份文件名（用于轮转日志；未发生删除返回 null）。
  /// 删除失败（文件被占用等）不阻断导出——轮转是保险措施，不是关键路径。
  Future<String?> archiveAndRotate(String json, {DateTime? now}) async {
    final dir = await _dir();
    final t = now ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final name = '小本本-全系统-'
        '${t.year}${two(t.month)}${two(t.day)}_'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}.json';
    File('${dir.path}${Platform.pathSeparator}$name')
        .writeAsStringSync(json, flush: true);

    // 文件名带秒级时间戳，名字倒序 = 新→旧；保留最近 keepCount 份。
    final jsonFiles = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));

    String? deletedName;
    for (final f in jsonFiles.skip(keepCount)) {
      deletedName ??= f.uri.pathSegments.last;
      try {
        f.deleteSync();
      } catch (_) {
        // 单个删除失败不阻断：下次导出会再尝试轮转。
      }
    }
    return deletedName;
  }

  /// 内档目录里现存备份份数（数据概况页/测试用）。
  Future<int> archivedCount() async {
    final dir = await _dir();
    return dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .length;
  }
}

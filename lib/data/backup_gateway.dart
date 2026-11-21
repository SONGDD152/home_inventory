import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// 备份文件读写与系统交互的抽象边界。
///
/// UI 层只依赖本接口：导出 = 生成 JSON 文件路径并唤起系统分享；
/// 恢复 = 用户经系统文件选择器挑一个 .json 路径，UI 读出内容。
/// 测试注入假网关，不触碰分享面板与文件系统。
abstract class BackupGateway {
  /// 把备份 JSON 写入可分享的临时文件，返回文件绝对路径。
  Future<String> writeBackupFile(String json);

  /// 唤起系统分享面板（保存到文件 / 发微信 / 发邮箱等由用户选）。
  Future<void> shareFile(String path);

  /// 唤起系统文件选择器，返回用户选中的备份文件路径；取消返回 null。
  Future<String?> pickBackupFile();

  /// 读取备份文件内容（与 [pickBackupFile] 返回的路径配对）。
  Future<String> readBackupFile(String path);
}

/// 生产实现：path_provider + share_plus + file_picker。
class SystemBackupGateway implements BackupGateway {
  @override
  Future<String> writeBackupFile(String json) async {
    final dir = await getTemporaryDirectory();
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final name = 'home_inventory_backup_'
        '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}.json';
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.writeAsString(json, encoding: utf8);
    return file.path;
  }

  @override
  Future<void> shareFile(String path) async {
    await Share.shareXFiles(<XFile>[XFile(path)]);
  }

  @override
  Future<String?> pickBackupFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['json'],
    );
    return result?.files.single.path;
  }

  @override
  Future<String> readBackupFile(String path) async {
    return File(path).readAsString(encoding: utf8);
  }
}

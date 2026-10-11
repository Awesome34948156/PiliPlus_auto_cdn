import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 把 [debugPrint] 的每一行同时落到应用文档目录的 `pili-console.log`。
///
/// 为什么需要：播放诊断（`CDN 看门狗` / `CDN 自动切换` / `CDN 遥测失真`、
/// mpv 的 `Stream ends prematurely` 等）全部只走 [debugPrint]，也就是 stdout。
/// 桌面端从终端启动还能重定向，但 **iOS 上 release 包没有 stdout 可看** ——
/// 从桌面图标启动、`devicectl --console` 附加、统一日志（`idevicesyslog`）
/// 三条路都拿不到（实测：进程活着，日志里 0 行）。于是最快的办法就是让 app
/// 自己写文件，再把这个文件取出来。
///
/// iOS 端配合 Info.plist 的 `UIFileSharingEnabled` +
/// `LSSupportsOpeningDocumentsInPlace`，文档目录会出现在「文件」App 里，
/// 也能被 `ifuse` 之类的 AFC 工具直接读到。每次启动截断，避免无限增长。
///
/// 失败一律静默：日志写不进去绝不能影响播放。
const String _kConsoleLogName = 'pili-console.log';

/// 文件句柄还没就绪时先攒在内存里。上限只为兜底——万一
/// [getApplicationDocumentsDirectory] 一直失败，不能让这里无界增长。
const int _kPendingLimit = 2000;

File? _consoleLogFile;
final List<String> _pendingLines = [];

/// 安装落盘钩子。必须在 binding 初始化之后、`runApp` 之前调用一次。
Future<void> installConsoleLogCapture() async {
  final original = debugPrint;

  File? file;
  try {
    final dir = (await getApplicationDocumentsDirectory()).path;
    file = File(p.join(dir, _kConsoleLogName));
    await file.writeAsString('', flush: true); // 每次启动截断
  } catch (e) {
    original('console log: 无法打开日志文件 ($e)，本次只写 stdout');
  }
  _consoleLogFile = file;

  // 钩子安装前（binding 初始化阶段）打过的行，这时补写进去。
  if (_pendingLines.isNotEmpty && file != null) {
    _append('${_pendingLines.join('\n')}\n');
    _pendingLines.clear();
  }

  debugPrint = (String? message, {int? wrapWidth}) {
    original(message, wrapWidth: wrapWidth);
    if (message == null) return;
    if (_consoleLogFile == null) {
      if (_pendingLines.length < _kPendingLimit) _pendingLines.add(message);
      return;
    }
    _append('$message\n');
  };
}

void _append(String text) {
  try {
    _consoleLogFile?.writeAsStringSync(text, mode: FileMode.append);
  } catch (_) {
    // 见上：写失败不影响播放
  }
}

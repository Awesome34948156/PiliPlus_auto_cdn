import 'dart:io';

import 'package:PiliPlus/services/console_log.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// console_log 的测试。
///
/// 这个模块的失败模式是无声的 —— 写不进去就静默放弃，日志看起来"什么都没
/// 发生"，所以它必须被真的跑一遍，不能靠读代码。
///
/// 注意：仓库的 .gitignore 里 `test*` 是整片忽略的，这个文件默认**不会**被
/// git 看到。要纳入版本管理得 `git add -f test/console_log_test.dart`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late File logFile;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pili-console-');
    logFile = File(p.join(tmp.path, 'pili-console.log'));
  });

  tearDown(() async {
    await resetConsoleLogCaptureForTest();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('装好之后打的日志会落盘', () async {
    await installConsoleLogCapture(logFile: logFile);
    expect(consoleLogActive, isTrue);

    debugPrint('落盘检查点');
    await flushConsoleLogForTest();

    expect(logFile.readAsStringSync(), contains('落盘检查点'));
  });

  test('开档期间打的日志不会被丢掉', () async {
    // 装钩子和开档之间隔着一个 await，那期间打的日志原来会直接消失 ——
    // 这正是 _pendingLines 存在的理由（原先它是死码，永远不会被写进去）。
    final installing = installConsoleLogCapture(logFile: logFile);
    debugPrint('开档期间');
    expect(consoleLogActive, isFalse, reason: '此刻 sink 还没就绪');

    await installing;
    await flushConsoleLogForTest();

    expect(logFile.readAsStringSync(), contains('开档期间'));
  });

  test('文件打不开时静默退化，不抛也不假装在写', () async {
    // 指向一个不可能写成的路径（父目录不存在）。
    final unwritable = File(p.join(tmp.path, 'no-such-dir', 'x.log'));
    await installConsoleLogCapture(logFile: unwritable);

    expect(consoleLogActive, isFalse);
    debugPrint('这条只该去 stdout'); // 不该抛
    await flushConsoleLogForTest(); // 也不该抛
  });

  test('重复安装不会把钩子套娃', () async {
    await installConsoleLogCapture(logFile: logFile);
    await installConsoleLogCapture(logFile: logFile);

    debugPrint('只应出现一次');
    await flushConsoleLogForTest();

    // 套娃的话第二次安装会把第一个钩子当成"原始 debugPrint"，
    // 同一行会被写两遍。
    final hits = '只应出现一次'.allMatches(logFile.readAsStringSync()).length;
    expect(hits, 1);
  });

  test('到上限就截断重来，且保留最近那段', () async {
    setConsoleLogMaxBytesForTest(512); // 生产是 8MiB，跑不到，所以调小
    await installConsoleLogCapture(logFile: logFile);

    for (var i = 0; i < 40; i++) {
      debugPrint('AAAA-$i-${'x' * 32}');
    }
    // 轮换是异步收尾的，所以标记行写在 flush 之前、等 flush 把它们一起推下去。
    debugPrint('最近的一行');
    await flushConsoleLogForTest();

    final text = logFile.readAsStringSync();
    expect(text, contains('截断重来'), reason: '应该发生过轮换');
    expect(text, contains('最近的一行'), reason: '最近那段必须留下');
    expect(text, isNot(contains('AAAA-0-')), reason: '被截断的早期内容不该还在');
  });
}

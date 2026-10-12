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

  group('同步钩子', () {
    late File staging;
    late List<String> uploaded;

    setUp(() {
      staging = File(p.join(tmp.path, 'pili-console.upload'));
      uploaded = [];
    });

    /// 装钩子。注意签名是 `{onSnapshot, stagingPath}` —— stagingPath 是**具名**
    /// 可选参数，写成位置参数 `setConsoleLogSyncHook(fn, staging.path)` 会直接
    /// 编译不过。
    void installHook(Future<void> Function(String) fn) =>
        setConsoleLogSyncHook(fn, stagingPath: staging.path);

    test('钩子抛异常不会毒化队列，之后的日志照写', () async {
      // 这是这个功能最要命的失败模式：_queue 是裸 .then 链，没有 onError。
      // 快照步骤漏一个异常出去，_queue 就变成一个失败的 future，
      // **之后每一行日志静默消失** —— 正是这个模块存在的理由被打掉。
      await installConsoleLogCapture(logFile: logFile);
      installHook((_) async => throw StateError('原生炸了'));

      debugPrint('同步前一行');
      await syncConsoleLogForTest(); // 不该抛

      debugPrint('同步后一行');
      await flushConsoleLogForTest();

      final text = logFile.readAsStringSync();
      expect(text, contains('同步前一行'));
      expect(text, contains('同步后一行'), reason: '钩子炸了也不能把队列带走');
    });

    test('快照拿走的是完整内容，且一行都不落进 staging 之外的地方', () async {
      await installConsoleLogCapture(logFile: logFile);
      installHook((path) async => uploaded.add(path));

      debugPrint('要同步的一行');
      await syncConsoleLogForTest();

      expect(uploaded, [staging.path]);
      // 快照在 flush 之后做：不 flush 的话，sink 里攒着的这批到不了磁盘，
      // copy 出来的会是上一版的文件。
      expect(staging.readAsStringSync(), contains('要同步的一行'));
      // 快照只读日志、不动日志：走 _enqueue 的话这里会多出一行 staging 路径。
      expect(logFile.readAsStringSync(), isNot(contains(staging.path)));
    });

    test('内容没变就不再调钩子', () async {
      await installConsoleLogCapture(logFile: logFile);
      installHook((path) async => uploaded.add(path));

      debugPrint('一行');
      await syncConsoleLogForTest();
      expect(uploaded, hasLength(1));

      // 一行都没多打：指纹没变，跨语言调用和 8MiB 的拷贝都该省掉。
      await syncConsoleLogForTest();
      expect(uploaded, hasLength(1), reason: '内容没变就不该再传一次');

      debugPrint('又一行');
      await syncConsoleLogForTest();
      expect(uploaded, hasLength(2));
    });

    test('钩子失败不提交指纹，下次拿同一份内容重试', () async {
      await installConsoleLogCapture(logFile: logFile);
      var fail = true;
      installHook((path) async {
        uploaded.add(path);
        if (fail) throw StateError('写到一半被打断');
      });

      debugPrint('只打这一次');
      await syncConsoleLogForTest();
      expect(uploaded, hasLength(1));

      // 提交了指纹的话，这份内容此后永远"看起来已同步"，日志停在那一刻 ——
      // 而这正是"退到后台被挂起"最常见的形态。
      fail = false;
      await syncConsoleLogForTest();
      expect(uploaded, hasLength(2), reason: '上次没送出去，这次必须重试');
      expect(staging.readAsStringSync(), contains('只打这一次'));
    });

    test('没装钩子时同步是空操作，一个字节都不拷', () async {
      await installConsoleLogCapture(logFile: logFile);
      debugPrint('一行');
      await syncConsoleLogForTest(); // 没绑文件夹就是这个形态
      expect(staging.existsSync(), isFalse);
    });
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

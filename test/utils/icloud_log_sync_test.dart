import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/services/console_log.dart';
import 'package:PiliPlus/utils/ios/icloud_log_sync.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as p;

/// `ICloudLogSync` 的测试。
///
/// 这个模块的职责是**编排**：什么时候跨 channel、什么时候认输。真正碰 iCloud
/// 的写全在 `ios/Runner/ICloudLogPlugin.swift` 里（那边只能靠真机验收），
/// 所以这里用假 channel 把"谁调谁、调几次、失败之后还剩什么状态"钉死。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 和 ICloudLogSync 内部那个是同一个名字 —— flutter_test 按 **channel 名**
  // 注册假 handler，所以这里新建一个也拦得到。
  const channel = MethodChannel('com.example.piliplus/icloud_log');

  late Directory tmp;
  late List<MethodCall> calls;

  /// native 那边的账本。每个方法返回什么由各用例现改。
  late Map<String, Object? Function(MethodCall call)> handlers;

  Future<Object?> dispatch(MethodCall call) async {
    calls.add(call);
    final handler = handlers[call.method];
    if (handler == null) fail('没有给 ${call.method} 安排返回值');
    return handler(call);
  }

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('pili-icloud-');
    // `appSupportDirPath` 是个 `late final` 全局，**只能赋一次值** ——
    // 所以整个文件共用一个临时目录，而不是每个用例换一个。
    appSupportDirPath = tmp.path;
    Hive.init(tmp.path);
    GStorage.localCache = await Hive.openBox('localCache');
  });

  tearDownAll(() async {
    await Hive.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  setUp(() async {
    await GStorage.localCache.clear();
    calls = [];
    handlers = {
      'isAvailable': (_) => true,
      'pickFolder': (_) => null,
      'resolve': (_) => {
        'path': '/fake/CloudDocs/PiliPlusLogs',
        'stale': false,
      },
      'clearAccess': (_) => null,
      'uploadLog': (_) => null,
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, dispatch);
    ICloudLogSync.isAvailable = false;
    ICloudLogSync.folderPath = null;
    ICloudLogSync.lastSyncedAt = null;
    ICloudLogSync.lastError = null;
  });

  tearDown(() async {
    await resetConsoleLogCaptureForTest();
    // 先解绑再关 Hive（unbind 要写 localCache，关在 tearDownAll 里）。
    await ICloudLogSync.unbind();
    setConsoleLogSyncHook(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  List<String> methods() => calls.map((c) => c.method).toList();

  test('原生说不支持时什么都不做', () async {
    handlers['isAvailable'] = (_) => false;
    await ICloudLogSync.init();
    expect(ICloudLogSync.isAvailable, isFalse);
    expect(ICloudLogSync.isConfigured, isFalse);
    expect(methods(), ['isAvailable']);
  });

  test('没存过书签就只探一次能力，不解析', () async {
    await ICloudLogSync.init();
    expect(methods(), ['isAvailable']);
    expect(ICloudLogSync.isConfigured, isFalse);
  });

  test('用户取消选择 = 没绑定，且不写书签', () async {
    await ICloudLogSync.init();
    final ok = await ICloudLogSync.pickFolder();
    expect(ok, isFalse);
    expect(ICloudLogSync.isConfigured, isFalse);
    expect(
      GStorage.localCache.get(LocalCacheKey.iCloudLogBookmark),
      isNull,
    );
    // 取消 **不是**失败：设置页拿 lastError 非空来把两者分开，留着旧错误
    // 会把一次正常取消弹成一条报错。
    expect(ICloudLogSync.lastError, isNull);
  });

  test('选完文件夹却绑不上时，原因要留在 lastError 里', () async {
    // 真机实测过的那一档：bookmark 建不出来
    // （`The file couldn't be opened because it doesn't exist.`）。
    // 用户看到的是"点了、选了、什么都没发生"，所以原因必须能显示出来。
    ICloudLogSync.lastError = '上一次的旧错误';
    handlers['pickFolder'] = (_) =>
        throw PlatformException(code: 'BOOKMARK', message: '建不出来');
    await ICloudLogSync.init();
    expect(await ICloudLogSync.pickFolder(), isFalse);
    expect(ICloudLogSync.lastError, contains('建不出来'));
    expect(ICloudLogSync.isConfigured, isFalse);
    // 这条路不走 _failing 那套：它是用户手点的一次动作，说"会继续重试"是假的。
    expect(ICloudLogSync.lastError, isNot(contains('会继续重试')));
  });

  test('绑定之后就每分钟往外送，书签存成 Uint8List', () async {
    final bookmark = Uint8List.fromList([1, 2, 3, 4]);
    handlers['pickFolder'] = (_) => {
      'bookmark': bookmark,
      'path': '/fake/CloudDocs/PiliPlusLogs',
    };
    await ICloudLogSync.init();

    expect(await ICloudLogSync.pickFolder(), isTrue);
    expect(ICloudLogSync.isConfigured, isTrue);
    expect(ICloudLogSync.folderName, 'PiliPlusLogs');
    // 存的是原始字节而不是 base64 —— Flutter 的 codec 和 Hive 都直接支持。
    expect(
      GStorage.localCache.get(LocalCacheKey.iCloudLogBookmark),
      isA<Uint8List>(),
    );
    // 绑定那一刻就把 `resolve` 走了（只有一条绑定路径）。
    expect(methods(), contains('resolve'));

    // 日志 -> staging -> uploadLog。
    await installConsoleLogCapture(logFile: File(p.join(tmp.path, 'log.tmp')));
    debugPrint('绑定之后的一行');
    await syncConsoleLogForTest();

    final upload = calls.where((c) => c.method == 'uploadLog').toList();
    expect(upload, isNotEmpty);
    final staging =
        (upload.last.arguments as Map)['stagingPath'] as String;
    // 快照落在**应用支持目录**，不是暴露给「文件」App 的文档目录。
    expect(p.dirname(staging), tmp.path);
    expect(File(staging).readAsStringSync(), contains('绑定之后的一行'));
  });

  test('瞬时失败只记状态，配置留着继续重试', () async {
    handlers['pickFolder'] = (_) => {
      'bookmark': Uint8List.fromList([1]),
      'path': '/fake/CloudDocs/PiliPlusLogs',
    };
    handlers['uploadLog'] = (_) =>
        throw PlatformException(code: 'WRITE', message: 'FileProvider 正忙');
    await ICloudLogSync.init();
    expect(await ICloudLogSync.pickFolder(), isTrue);
    await installConsoleLogCapture(logFile: File(p.join(tmp.path, 'log.tmp')));

    debugPrint('一行');
    for (var i = 0; i < 4; i++) {
      await syncConsoleLogForTest();
    }

    expect(ICloudLogSync.isConfigured, isTrue, reason: '写不进去不代表配置废了');
    expect(ICloudLogSync.lastError, isNotNull);
    expect(ICloudLogSync.lastSyncedAt, isNull);
    expect(
      GStorage.localCache.get(LocalCacheKey.iCloudLogBookmark),
      isNotNull,
      reason: '瞬时失败绝不该清书签',
    );
  });

  test('永久失败攒够阈值就解绑、清书签、退回未设置', () async {
    handlers['pickFolder'] = (_) => {
      'bookmark': Uint8List.fromList([1]),
      'path': '/fake/CloudDocs/PiliPlusLogs',
    };
    // 文件夹被改名/移走 —— 原生侧已经拿不到访问权了。
    handlers['uploadLog'] = (_) =>
        throw PlatformException(code: 'NO_FOLDER', message: 'no folder bound');
    await ICloudLogSync.init();
    expect(await ICloudLogSync.pickFolder(), isTrue);
    await installConsoleLogCapture(logFile: File(p.join(tmp.path, 'log.tmp')));

    // 失败不提交内容指纹，所以每一次都会重新尝试（也就是每次都会计入失败）。
    for (var i = 0; i < 5; i++) {
      debugPrint('第 $i 行');
      await syncConsoleLogForTest();
    }
    // 解绑是即发即忘的（`_notePermanent` 跑在 catch 里，没法 await），
    // 把它的微任务和 Hive 写都排空。
    await pumpEventQueue(times: 50);

    expect(ICloudLogSync.isConfigured, isFalse, reason: '退回「未设置」');
    expect(
      GStorage.localCache.get(LocalCacheKey.iCloudLogBookmark),
      isNull,
      reason: '死书签不能留着下次开机再解析一遍',
    );
    expect(methods(), contains('clearAccess'));
  });

  test('上传在飞时进来的那次会被合并，但内容绝不能丢', () async {
    handlers['pickFolder'] = (_) => {
      'bookmark': Uint8List.fromList([1]),
      'path': '/fake/CloudDocs/PiliPlusLogs',
    };
    final gate = Completer<void>();
    final landed = <String>[];
    handlers['uploadLog'] = (call) async {
      final path = (call.arguments as Map)['stagingPath'] as String;
      landed.add(File(path).readAsStringSync());
      // 第一次一直飞着，逼出"在飞时又来一次"那个窗口。
      if (landed.length == 1) await gate.future;
      return null;
    };
    await ICloudLogSync.init();
    expect(await ICloudLogSync.pickFolder(), isTrue);
    await installConsoleLogCapture(logFile: File(p.join(tmp.path, 'pili.log')));

    debugPrint('第一行');
    unawaited(syncConsoleLogForTest());
    await pumpEventQueue(times: 200);

    // 这个断言不是走过场：**它保证后面那段真的落在"在飞"的窗口里**。
    // 如果第一次的快照还没走到就往下走，两边会拿到同一份内容，
    // 测试就退化成恒真了（第一版就是这么假绿的）。
    expect(landed, hasLength(1), reason: '第一次应该已经进到原生调用了');
    expect(landed.single, contains('第一行'));
    expect(landed.single, isNot(contains('第二行')), reason: '快照必须发生在第二行之前');

    // 第一次还在飞的时候落了第二行。
    debugPrint('第二行');
    unawaited(syncConsoleLogForTest());
    await pumpEventQueue(times: 200);

    gate.complete();
    await pumpEventQueue(times: 200);

    // 合并那次如果只是"正常返回"，console_log 会把第二行这份内容标成已同步，
    // 而它一个字节都没出去 —— 之后带着同样内容来就会被指纹挡掉，永远不出现。
    expect(
      landed.last,
      contains('第二行'),
      reason: '被合并的那一份必须靠"上传结束后再跑一次"补上：$landed',
    );
  });

  test('启动时解析不出来会排一次重试，而不是整个会话作废', () async {
    await GStorage.localCache.put(
      LocalCacheKey.iCloudLogBookmark,
      Uint8List.fromList([9]),
    );
    handlers['resolve'] = (_) =>
        throw PlatformException(code: 'RESOLVE', message: '解析不出来');
    await ICloudLogSync.init();

    // 冷启动那一刻 iCloud Drive 常常还没挂好，这时失败是**瞬时**的；
    // 没有这条重试，用户只能自己去设置页重选一遍。
    expect(ICloudLogSync.isConfigured, isFalse);
    expect(calls.where((c) => c.method == 'resolve'), hasLength(1));
    // 排了重试就有个挂着的 Timer —— tearDown 里的 unbind 会取消它。
  });
}

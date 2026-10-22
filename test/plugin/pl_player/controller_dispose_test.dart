import 'dart:io';

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
// wakelock_plus 的传递依赖；测试只用来替换 `wakelockPlusPlatformInstance`。
// ignore: depend_on_referenced_packages
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

class _FakeWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}

  @override
  Future<bool> get enabled async => false;
}

/// `dispose()` 的单例生命周期回归。
///
/// 一条不变量：**完整拆解过的旧对象，迟到的 `dispose()` 不能动当前单例。**
/// 现场路径是直播间（`lib/pages/live_room/view.dart`）——它的 controller 字段在
/// 构造时就抓住了 `getInstance()` 返回的对象；单例被别的页面拆掉又重建之后，
/// 旧直播间退出时仍会调用旧对象的 `dispose()`。修前那次调用会再走一遍完整拆解，
/// 把新实例的静态计数清零、`_instance` 置空，顺带清掉锁屏卡片和播放回调。
///
/// 这是构造器/销毁路径的第一组单测。macOS 宿主上 `PlatformUtils.isMobile` 为假，
/// 构造器会跳过方向监听；需要 Hive 三个盒（构造时读 `Pref` 与 `GStorage.video`），
/// 以及两个平台通道 mock：`resetScreenRotation()` 走 `SystemChannels.platform`，
/// `WakelockPlus.disable()` 走 pigeon。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late WakelockPlusPlatformInterface originalWakelock;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('piliplus-dispose-test-');
    Hive.init(tempDir.path);
    GStorage.regAdapter();
    // 顺序要紧：必须在第一次碰 Pref 之前。播放器单例构造时会读
    // `GStorage.setting` 与 `GStorage.video`。
    GStorage.setting = await Hive.openBox('setting');
    GStorage.localCache = await Hive.openBox('localCache');
    GStorage.video = await Hive.openBox('video');
  });

  setUp(() {
    // resetScreenRotation() 无条件走系统通道；不 mock 会抛 MissingPluginException。
    messenger.setMockMethodCallHandler(SystemChannels.platform, (_) async {
      return null;
    });
    // dispose() 里的 WakelockPlus.disable() 换成假实现：flutter_test 里没注册
    // macOS 插件，真实现会走 pigeon 通道。
    originalWakelock = wakelockPlusPlatformInstance;
    wakelockPlusPlatformInstance = _FakeWakelock();
  });

  tearDown(() {
    // 把用例可能留下的当前实例收掉，避免跨用例串状态。
    final current = PlPlayerController.instance;
    if (current != null) {
      current
        ..debugPlayerCount = 1
        ..dispose();
    }
    wakelockPlusPlatformInstance = originalWakelock;
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  test('完整拆解后单例消失，旧对象标记已拆', () {
    final a = PlPlayerController.getInstance()
      ..debugPlayerCount = 1
      ..dispose();

    expect(PlPlayerController.instanceExists(), isFalse);
    expect(a.debugDisposed, isTrue);
  });

  test('僵尸对象的迟到 dispose 不能清掉新实例', () {
    final a = PlPlayerController.getInstance()
      ..debugPlayerCount = 1
      ..dispose();
    expect(PlPlayerController.instanceExists(), isFalse);

    final b = PlPlayerController.getInstance()..debugPlayerCount = 1;
    // 旧直播间退出：a 已经是满拆过的对象，这一次必须原地返回。
    a.dispose();

    expect(identical(PlPlayerController.instance, b), isTrue);
    expect(b.debugDisposed, isFalse);
  });

  test('部分拆解不置标记，最后一次仍能完整拆解', () {
    final a = PlPlayerController.getInstance()
      ..debugPlayerCount = 2
      ..dispose();

    expect(identical(PlPlayerController.instance, a), isTrue);
    expect(a.debugDisposed, isFalse);

    a
      ..debugPlayerCount = 1
      ..dispose();

    expect(PlPlayerController.instanceExists(), isFalse);
    expect(a.debugDisposed, isTrue);
  });

  test('updatePlayCount 拆掉旧实例后，旧对象也不能误清新实例', () {
    final a = PlPlayerController.getInstance()..debugPlayerCount = 1;

    PlPlayerController.updatePlayCount();
    expect(PlPlayerController.instanceExists(), isFalse);

    final b = PlPlayerController.getInstance()..debugPlayerCount = 1;
    a.dispose();

    expect(identical(PlPlayerController.instance, b), isTrue);
    expect(b.debugDisposed, isFalse);
  });
}

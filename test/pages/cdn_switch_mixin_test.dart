import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/models/common/video/audio_quality.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/pages/video/cdn_switch_mixin.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/utils/cdn_speed_test.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';

/// CDN 自动切换的回归测试台。
///
/// 这个文件存在的理由是**一条时序**：一轮自动换源要在 `await playerInit(...)`
/// 上停几秒（真实环境里那是播放器重载），而"相关视频跳转"恰恰会在这几秒里 push
/// 一个新页面、把共享播放器单例上的回调从旧页抢走。旧页醒来之后如果不查"我还是
/// 不是现役那一页"就继续往下走，用户看到的就是"跳了个视频，CDN 却还按上一个视频
/// 的节奏乱动"。读代码看得出这件事，只有把时序重放一遍才**证明**它不在。
///
/// **为什么不造假播放器**：`PlPlayerController` 全仓只有一个**私有**构造函数
/// （`lib/plugin/pl_player/controller.dart:973`），另一个库里 `extends` 不过去，
/// mockito 那类生成式 mock 同理（dev_dependencies 里也没有）。但它自己的公开字段
/// 足够把状态摆成想要的样子（`playerStatus` / `position` / `buffered` /
/// `durationInMilliseconds`），而 `videoPlayerController` 为 null 时
/// `positionInMilliseconds` 恒为 0 —— 正好让"落点落后"这件事必然发生。代价是
/// **观察不到 `seekTo`**，所以断言落在 `debugPrint` 行上（仓库既有文化就是拿
/// 日志行当证据）。
///
/// **网络只有一条缝**：宿主上的 `cdnAutoDioForTest`，配一个手写的
/// `HttpClientAdapter`。真 Dio 的默认适配器走 `dart:io` 的 `HttpClient`，而
/// `flutter_test` 会把全局那个换成"永远回 400"的假货（`_binding_io.dart:365`）
/// —— 手写适配器根本不碰它，所以整轮测速能离线跑完。
///
/// 注意：`.gitignore` 里有 `test*`，但 `test/` 本身已被 `!test/` 反忽略
/// （`.gitignore:160-161`），所以这个文件能直接 `git add`，**不需要 `-f`**。仍被
/// 忽略的只有 basename 以 `test` 开头的文件（`test/test_helpers.dart` 之类）——
/// 新增辅助文件前用 `git check-ignore <路径>` 确认一下，别想当然。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _CdnHost hostA;
  late _CdnHost hostB;
  late _FakeCdn cdn;
  late _LogCapture log;

  /// 这一轮的对象：400MB / 1 小时。够大才有非零的取样偏移（见
  /// [CdnSpeedTest.targetOffset] 的下界 `offsetFloor`），非零偏移才谈得上
  /// "镜像遵不遵守 Range"。
  const objectSize = 400 * 1000 * 1000;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('piliplus-cdn-test-');
    Hive.init(tempDir.path);
    GStorage.regAdapter();
    // 三个盒都是 `static late final`，跨库可以一次性赋值。顺序要紧：**必须在
    // 第一次碰 Pref 之前**。播放器单例构造时会读 `GStorage.setting` 与
    // `GStorage.video`（`controller.dart:194/917`），所以 video 盒也要开。
    GStorage.setting = await Hive.openBox('setting');
    GStorage.localCache = await Hive.openBox('localCache');
    GStorage.video = await Hive.openBox('video');
  });

  setUp(() async {
    log = _LogCapture()..install();
    await GStorage.localCache.clear();
    await GStorage.setting.clear();
    // 只关提示，不动 debugPrint —— 断言全在日志行上。
    await GStorage.setting.put(SettingBoxKey.showCdnSwitchToast, false);
    // 每个用例都从"没有历史、轮换从 0 起"开始，否则上一轮写下的速度记录会喂给
    // 下一轮的冠军位，用例之间就不独立了。
    Pref.cdnSpeedRecord = const [];
    Pref.cdnMirrorRotation = 0;
    cdn = _FakeCdn(objectSize);

    PlPlayerController.getInstance()
      ..playerStatus = PlayerStatus.paused
      ..position.value = 0
      ..buffered.value = 0
      // `buffer` 是单例上的 `late final` 字段，改它**会跨用例留下**。回填水位摆成
      // 0 等于关掉那条判据（`_cdnBufferFloor` 对 `<= 0` 返回 null），用例 1c 再自己
      // 把它抬起来 —— 所以每次进来都得先归零。
      ..buffer['demuxer-hysteresis-secs'] = '0'
      // 时长与对象大小一起决定"这条流需要多快"，也是取样偏移算式的分母。
      ..durationInMilliseconds = 3600 * 1000
      // duration.value 非零让 seekTo 走 seek() 分支，不在单例上留一条永不触发
      // 的订阅（那一条在测试进程里没人清）。
      ..duration.value = 3600;

    hostA = _CdnHost(cdn: cdn, url: _baselineUrl);
    hostB = _CdnHost(cdn: cdn, url: _baselineUrl);
    // 解码账（_decodeErrors / _decodeErrorUntil …）是单例字段，跨用例只增不减；
    // T1 不 attach host（走不到 attachCdnSwitch 里的复位），所以这里显式清零。
    PlPlayerController.getInstance().resetDecodeErrorAccounting();
  });

  tearDown(() async {
    // 残留的一轮还在等定时器（`_restoreResumePosition` 800ms 一拍最多 8 拍、
    // `_awaitRecovery` 500ms 一拍最多 12s）。**真正让它们退出的是下面这两句**：
    // `resetCdnForNewObject()` 推代际、`detachCdnSwitch()` 撤回调，残留的那一拍
    // 醒来时两道闸门都是假的，各自 return。
    //
    // 那 20ms 不是等它们退出（800ms / 500ms 的周期它等不到），只是让**已经排上队**
    // 的微任务在 `log.restore()` 之前落地 —— 否则它们会把日志打进下一个用例的捕获里。
    for (final host in [hostA, hostB]) {
      host
        ..resetCdnForNewObject()
        ..detachCdnSwitch();
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    PlPlayerController.getInstance()
      ..onStall = null
      ..onDecodeError = null;
    log.restore();
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  test('被顶掉的那一页不许再动播放器（跨页污染）', () async {
    // A 起一轮，卡在重载播放器那一步 —— 复现的就是"这几秒里 B 顶了进来"。
    hostA
      ..holdInit = Completer<void>()
      ..attachCdnSwitch();
    _stall(hostA);
    await _waitFor(() => hostA.initCalls == 1);
    // 先确认这一轮真的起来了、真的走到重载播放器那一步 —— 否则下面那句
    // "没有落点"会退化成"这一轮压根没跑"的假绿。
    expect(log.has('开始找可用镜像'), isTrue);
    expect(log.has('基线无有效速度，直接切换'), isTrue);

    // 相关视频跳转：新页 attach，抢走共享播放器的回调。旧页不 onClose、不换代。
    hostB.attachCdnSwitch();
    hostA.holdInit!.complete();

    // 补落点是 800ms 一拍。这里要等的是一件**不该发生**的事，所以余量必须给足：
    // 只等 1500ms 的话，慢机器上"坏实现的第一拍还没打出来"就会被判成通过。
    await Future<void>.delayed(const Duration(seconds: 3));

    expect(
      log.has('补一次 seek'),
      isFalse,
      reason: '旧页已经不在台上了，不该再往共享播放器上 seek：\n${log.text}',
    );
    expect(
      log.has('成功，已切到'),
      isFalse,
      reason: '旧页不该宣布切换成功（那是给新页的 toast/日志）：\n${log.text}',
    );
  });

  test('被顶掉的那一页不许在补落点的半路上再 seek', () async {
    // 与上一条只差**顶进来的时刻**：上一条顶在"重载播放器"那一步（第一道闸门
    // 之前），这条顶在"等落点"的 800ms 拍子里（第一道闸门之后）。
    //
    // 两条都得有。只看上一条的话，一个只补了第一道闸门的半截修复照样全绿 ——
    // 它会在第一道闸门就 return，后面几道根本轮不到执行，测不到。而"跳出去过几秒
    // 再回来"这个真实的用户节奏，落点恰恰就在这几拍里。
    hostA
      ..holdInit = Completer<void>()
      ..attachCdnSwitch();
    _stall(hostA);
    await _waitFor(() => hostA.initCalls == 1);

    // 放行重载：这一轮随即越过第一道闸门，进到 `_restoreResumePosition` 的
    // 800ms 拍子上。200ms 足够它走完那几步（中间只有微任务），又远早于第一拍。
    hostA.holdInit!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    hostB.attachCdnSwitch();

    await Future<void>.delayed(const Duration(seconds: 3));
    expect(
      log.has('补一次 seek'),
      isFalse,
      reason: '旧页是在等落点的半路被顶掉的，同样不该再 seek：\n${log.text}',
    );
  });

  test('被顶掉的那一页不许在重载点上就往下走', () async {
    // 顶进来的时刻与第一条相同（卡在重载里），但**落点取 0**：
    // `_restoreResumePosition` 于是立刻返回，这一轮直接走到 `_switchTo` 的返回
    // 值上。把回填水位抬起来，是为了让"它要是继续往下走"这件事留下痕迹 ——
    // 一个可见的裁定（`未恢复` 或 `成功`）。
    //
    // 为什么非要这一条：几条闸门是**冗余的**，只还原其中一条，下一条会接住，
    // 所以前三条都发现不了"只还原了最早那道"。只有落点为零、且把水位摆好，
    // 才观察得到"最早那道闸门到底拦没拦住"。
    PlPlayerController.getInstance()
      ..buffer['demuxer-hysteresis-secs'] = '30'
      ..buffered.value = 60
      ..position.value = 0;
    hostA
      ..holdInit = Completer<void>()
      ..attachCdnSwitch();
    _stall(hostA, Duration.zero);
    await _waitFor(() => hostA.initCalls == 1);

    hostB.attachCdnSwitch();
    hostA.holdInit!.complete();
    await Future<void>.delayed(const Duration(seconds: 2));

    expect(
      log.has('未恢复') || log.has('成功，已切到'),
      isFalse,
      reason: '重载完就该发现本页已被顶掉，不该再做任何裁定：\n${log.text}',
    );
  });

  test('被顶掉的那一页不许在等恢复的半路宣布切换成功', () async {
    // 这一条打的是 `_awaitRecovery`：它要能跑起来，得先让 `_switchTo` 整条走完。
    // 两个前提：
    //   1. 触发点用 **0s** —— `_restoreResumePosition` 对 `target <= 0` 直接返回，
    //      于是这一轮不用干等 8 拍，立刻进到等恢复；
    //   2. 把回填水位抬到余量以下 —— 否则那条判据永远为假，这个用例就成了
    //      "因为判据不可能成立所以没误报"的空转。
    PlPlayerController.getInstance()
      ..buffer['demuxer-hysteresis-secs'] = '30'
      ..buffered.value = 60
      ..position.value = 0;
    hostA.attachCdnSwitch();
    _stall(hostA, Duration.zero);
    await _waitFor(() => hostA.initCalls == 1);

    await Future<void>.delayed(const Duration(milliseconds: 200));
    hostB.attachCdnSwitch();

    await Future<void>.delayed(const Duration(seconds: 2));
    // 正面信号：门是活的 —— "未恢复"出现说明 `_awaitRecovery` 确实进了、确实在
    // 那一拍上做了裁定。少了它，下面那句"没有成功"就可能是"整条路压根没跑到"。
    expect(
      log.has('未恢复'),
      isTrue,
      reason: '这一轮没走到等恢复那一步，用例空转了：\n${log.text}',
    );
    expect(
      log.has('成功，已切到'),
      isFalse,
      reason: '余量早就够了，是"这页已经不是现役"才该判成未恢复：\n${log.text}',
    );
  });

  test('没人顶掉时正常换源照旧（守卫没把正常路径掐掉）', () async {
    hostA.attachCdnSwitch();
    _stall(hostA);

    await _waitFor(() => log.has('补一次 seek'));
    expect(hostA.initCalls, 1);
  });

  test('暂停态换源保持暂停', () async {
    PlPlayerController.getInstance().playerStatus = PlayerStatus.paused;
    hostA.attachCdnSwitch();
    _stall(hostA);

    await _waitFor(() => hostA.initCalls == 1);
    expect(hostA.initAutoplay, [false]);
  });

  test('作废的那一轮一个格子都不提交', () async {
    // 把"探对象总长"那一发卡住 —— 它正好是 `_pickFastestCdn` 中间那个 await，
    // 也正好是"用户在这几秒里换了画质/换集"的那个时刻。
    cdn.holdProbe = Completer<void>();
    hostA.attachCdnSwitch();
    _stall(hostA);
    await _waitFor(() => cdn.probes.isNotEmpty);

    hostA.resetCdnForNewObject();
    cdn.holdProbe!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(cdn.probes.length, 1);
    expect(
      cdn.samples,
      isEmpty,
      reason: '这一轮已经作废了，不该再花流量去测速：${cdn.samples}',
    );
  });

  test('作废的那一轮不许推进轮换相位', () async {
    // 轮换游标的提交点在 `_pickFastestCdn` 里**第一个 await 之前**，而作废复查
    // 在它之后 —— "用户在这几秒里换了画质/换集"这个时机，恰好让被作废的那一轮
    // 白推进一次相位，下一轮就跳过几个镜像。上一条（「一个格子都不提交」）只看
    // 采样，看不出游标已经动了：那条在修复前后都绿。
    cdn.holdProbe = Completer<void>();
    hostA.attachCdnSwitch();
    _stall(hostA);
    await _waitFor(() => cdn.probes.isNotEmpty);

    // 正面前提：探长请求只在候选非空**之后**才发出（`candidates.isEmpty` 在它
    // 前面就 return 了），所以这一轮确实取过候选、游标本该有非零推进量。少了它，
    // 下面那句 0 就可能是"压根没走到轮换"的假绿。
    expect(cdn.probes.length, 1);

    hostA.resetCdnForNewObject();
    cdn.holdProbe!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(
      Pref.cdnMirrorRotation,
      0,
      reason: '被作废的那一轮推进了轮换相位：游标提交落在了作废复查之外',
    );
  });

  test('被顶掉的那一页连兜底重载都不该碰', () async {
    // 尾段那道兜底（`_autoSwitchLoop` 收尾）：一轮没能换出结果、而画面已经冻住
    // （`telemetryDiverged`）时，重载当前源，让音视频两条流重新对齐时钟。它
    // **不换源**，所以前几条用例盯的那些切换动作一个都看不见它 —— 得单独把
    // "画面已冻"这个前提摆出来才测得到。
    //
    // 前提摆两样：
    //   - `cache-secs` 30s（mpv 的缓存上限）× `_kDivergedFactor` 3 倍 = 90s 是
    //     失真线，余量 200s 压在上面 —— 也就是"音频在走、画面冻着"那份被抬到
    //     上千秒的余量。判据是**现场取值**的（那段注释：一轮跑好几秒，期间可能
    //     自己缓过来），所以整轮都得让它成立；
    //   - 基线挪到 [_steadyBaselineUrl]：假适配器按 host 发字节，基线那一份于是
    //     不再是"拿不出有效速度"的小样本，这一轮的裁定落成一条**不切换**的结论
    //     —— 正是兜底要接的那种。留在 [_baselineUrl] 上，结论会是"基线无有效
    //     速度，直接切换"，这一轮换完就走人，兜底根本轮不到，用例会空转。
    PlPlayerController.getInstance()
      ..buffer['cache-secs'] = '30'
      ..buffered.value = 200
      ..position.value = 0;
    cdn.holdProbe = Completer<void>();
    hostA
      ..videoUrl = _steadyBaselineUrl
      ..attachCdnSwitch();
    _stall(hostA);
    await _waitFor(() => cdn.probes.isNotEmpty);

    // 相关视频跳转：新页 attach 抢走共享播放器的回调，旧页不 onClose、不换代。
    // 顶进来的时刻选在"探对象总长"那一发卡住的时候 —— 那一发后面还有整轮测速，
    // 每一处 await 之后旧页都还会接着往下走，最后撞在 `_pickFastestCdn` 之后
    // 那道 `!_cdnIsAttached` 复查上。
    hostB.attachCdnSwitch();
    cdn.holdProbe!.complete();

    // 等三发采样都发出去 —— 那是"这一轮真的跑到了测速"的正面证据。少了它，
    // 下面那两句"没有"就可能是"这一轮压根卡在探测里"的假绿。
    await _waitFor(() => cdn.samples.length >= 3);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(cdn.samples.length, 3, reason: '这一轮没跑完测速：${cdn.samples}');
    expect(
      PlPlayerController.getInstance().telemetryDiverged,
      isTrue,
      reason: '兜底的前提不成立，这条用例就空转了 —— 下面两句"没有"什么也证明不了',
    );
    expect(
      log.has('画面已冻（余量失真），重载当前源'),
      isFalse,
      reason: '旧页已经不在台上了，不该重载共享播放器：\n${log.text}',
    );
    expect(
      log.has('放弃，'),
      isFalse,
      reason: '这一轮该在那道复查上断掉，不该走到收尾、更不该写冷却：\n${log.text}',
    );
  });

  test('没被顶掉时兜底重载照旧（上一条的否定不是空的）', () async {
    // 上一条的对照组，**只差"有没有被顶掉"这一件事**：同样的"画面已冻"前提、
    // 同一条基线、同一轮测速。这里必须看见那句重载 —— 否则上一条的"没有"就只是
    // "这句日志在任何情况下都不会出现"，什么也没锁住。
    //
    // 关键是让这一轮**不切换**：换了源 `switched` 就是真，兜底那句
    // `if (!switched && telemetryDiverged)` 直接短路。裁定怎么摆出来：
    //   - 基线在 [_steadyBaselineUrl] 上 —— host 一离开 [_baselineHost]，假适配器
    //     就按候选档发字节，基线于是**拿得出**有效速度；
    //   - 候选拿到的字节数与基线一模一样，比值 ≈ 1.0x，够不着 `_kCdnStarveRatio`
    //     1.5 → 判成 `healthy`（"CDN 都正常"）→ 不切换。真要两边比出差距得靠
    //     真实墙钟去堆分块延迟，那既慢又不稳（文件头那句"刻意不用速度比来造
    //     better"）。实测这条路上比值一直落在 0.99x 附近，阈值在 1.5。
    //
    // 播放器单例的 `dataSource` 是 `late`（`controller.dart:189`），兜底那句
    // `refreshPlayer()` 头一件事就是读它（`:1321`）。不摆好，这条会在打出"画面
    // 已冻"之后抛 LateInitializationError —— 日志对了、用例照样红。摆成网络源
    // （非 FileSource）才走得到重载那一句。
    PlPlayerController.getInstance()
      ..dataSource = NetworkSource(
        videoSource: _steadyBaselineUrl,
        audioSource: null,
      )
      ..buffer['cache-secs'] = '30'
      ..buffered.value = 200
      ..position.value = 0;
    hostA
      ..videoUrl = _steadyBaselineUrl
      ..attachCdnSwitch();
    _stall(hostA);

    await Future<void>.delayed(const Duration(seconds: 3));

    expect(
      log.has('-> 不切换'),
      isTrue,
      reason: '这一轮本该判成不切换（基线健康、候选不快）—— 裁定变了就不是这条用例在测的东西了：'
          '\n${log.text}',
    );
    expect(
      log.has('画面已冻（余量失真），重载当前源'),
      isTrue,
      reason: '没人顶掉、又没能换出更快的镜像，兜底就该重载当前源：\n${log.text}',
    );
    expect(
      log.has('放弃，60s 内不再尝试（画面已冻，没有更快的镜像，已重载当前源）'),
      isTrue,
      reason: '重载之后那句收尾没写出来，说明兜底半路断了：\n${log.text}',
    );
  });

  test('被顶掉又回来的那一页，旧一轮不许复活（重挂要作废在途轮）', () async {
    // 与"被顶掉的那一页连兜底重载都不该碰"只差**一步**：那条停在"被顶掉"，
    // 这条多一个"用户又退回来"。返回时 `view.dart` 的 `didPopNext` 会再调一次
    // `attachCdnSwitch()`，而此刻 `_cdnIsAttached` 是假（回调被 B 抢走了），幂等
    // 守卫拦不住 —— 回调重新挂上、`_cdnIsAttached` 又读成真。可 `_cdnGeneration`
    // 没动，于是那一轮"本页还有效吗"重新读成真：它醒来就接着往下走，拿的还是
    // **上一个视频**的地址去指挥这台共享播放器。修复就是让"重挂"顺手作废在途轮。
    //
    // 卡在"探对象总长"那一发上，好让这一轮停在 `_pickFastestCdn` 中间：那里之后
    // 只有 `_roundVoided` 一道闸、**没有** `_cdnIsAttached` 复查（`:1332`），
    // 正是"代际不动就拦不住"的那个缺口。
    cdn.holdProbe = Completer<void>();
    hostA.attachCdnSwitch();
    _stall(hostA);
    await _waitFor(() => cdn.probes.isNotEmpty);
    expect(
      log.has('卡顿 @100s，开始找可用镜像'),
      isTrue,
      reason: '这一轮压根没起来，下面那句"没有取样"什么也证明不了：\n${log.text}',
    );

    // 相关视频跳转：新页 attach 抢走回调。旧页不 onClose、不换代。
    hostB.attachCdnSwitch();
    // 用户又退了回来：`didPopNext` 再挂一次 —— 就是这一步让旧一轮"复活"。
    hostA.attachCdnSwitch();

    cdn.holdProbe!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(
      cdn.samples,
      isEmpty,
      reason: '旧页被顶掉过，那一轮已经作废，不该再花流量测速：${cdn.samples}',
    );

    // 半路那道闸不能只关不重开：代际一推进，那一轮的 whenComplete 就认不出自己了
    // （`:770` 的 `generation == _cdnGeneration` 为假），busy 得在同一口气里放下
    // —— 否则 `_cdnAutoBusy` 永远为真，此后每一次触发都只打一行 `busy=true`，
    // 而 `attachCdnSwitch` 是幂等的，再也不会回来救它。
    _stall(hostA, const Duration(seconds: 300));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      log.has('卡顿 @300s，开始找可用镜像'),
      isTrue,
      reason: '重挂之后新一轮起不来 —— busy 那道闸没放下：\n${log.text}',
    );
    expect(
      log.has('busy=true'),
      isFalse,
      reason: 'busy 没在重挂时清掉，这一页的自动换源被永久关闸了：\n${log.text}',
    );
  });

  // ---------------------------------------------------------------------------
  // 下面这一批打的是"刚修完的下半段"：触发闸门不该顺手消费状态、失败该不该装
  // 冷却、解码档不许被兜底覆写、预检 pending 不该被静默吃掉、回页不该重新武装。
  // 每条都配了"删掉守卫必须变红"的验证（见各自注释里点名的生产行）。
  // ---------------------------------------------------------------------------

  test('解码档（force）不许被"余量失真 → 重载当前源"改写（F8）', () async {
    // 前提两样，缺一不可：
    //   - force：走解码档（onDecodeError），它跳过速度门槛，也**跳过**尾段那道
    //     `!switched && !force && telemetryDiverged` 的覆写；
    //   - telemetryDiverged 为真：这正是旧行为会踩的雷。解码故障里它恰恰常为真
    //     （坏镜像余量填得满、位置被音频时钟推着走），于是旧代码把"没找到可换的
    //     镜像"这个**正确的**结论改写成"重载当前源"，去对同一个坏 Media 再
    //     refreshPlayer 一次 —— 治错病。
    PlPlayerController.getInstance()
      // 兜底那句 `refreshPlayer()` 头一件事是读 `dataSource`（`late`）。不摆好，
      // 删掉守卫做变红验证时它会在打出"画面已冻"之后抛 LateInitializationError
      // —— 日志对了、用例照样红，变红的原因就不干净了。
      ..dataSource = NetworkSource(videoSource: _baselineUrl, audioSource: null)
      ..buffer['cache-secs'] = '30'
      ..buffered.value = 200
      ..position.value = 0;
    // 基线、候选**都**拿不出有效速度 → 这一轮测成 unmeasurable，正是"没得换"
    // 那个结论的来源。
    cdn.allTiny = true;
    hostA.attachCdnSwitch();

    PlPlayerController.getInstance().onDecodeError!(
      const Duration(seconds: 100),
    );
    await _waitFor(() => log.has('放弃，'));

    // 前提自检：不成立的话下面两句"没有/有"就什么也证明不了。
    expect(
      PlPlayerController.getInstance().telemetryDiverged,
      isTrue,
      reason: '覆写那条判据的前提不成立，这条用例空转了',
    );
    // 正面证据：force 真的生效了 —— 结论是解码档专属那句，不是普通那轮的
    // "无法测出更快的 CDN"。
    expect(
      log.has('当前镜像的字节解不出画面，但没找到可换的镜像'),
      isTrue,
      reason: 'force 没生效，或这一轮没走到 unmeasurable：\n${log.text}',
    );
    expect(
      log.has('无法测出更快的 CDN，暂不切换'),
      isFalse,
      reason: '这是非 force 那一档的说法，说明 force 丢了：\n${log.text}',
    );
    // 被守护的那件事：force 不该落进那条覆写。
    expect(
      log.has('画面已冻（余量失真），重载当前源'),
      isFalse,
      reason: '解码档不该去重载同一个坏 Media（治错病）：\n${log.text}',
    );
  });

  test('host 改写后地址为空：这次失败要装冷却（N10）', () async {
    // `_switchTo` 里 `newVideo.isEmpty` 那条：host 改写对这条镜像压根不生效、
    // 一个可用 URL 都拿不出来。它是**真的失败**，不是作废轮 —— 不装冷却的话，
    // 下一次触发照样选中它、照样空手而归，无限重试。
    //
    // 造法：`_pickFastestCdn` 在**开头**就把 `firstVideo.playUrls` 拷了一份
    // （`urls`）供整轮用，此后一串 await；而 `_switchTo` 读的是**当时的**
    // `firstVideo.playUrls`。卡在"探对象总长"那一发上把视频轨的 baseUrl 抹掉，
    // 那一轮便照着旧拷贝选中候选、却在 `_switchTo` 里读到一个空列表。
    cdn.holdProbe = Completer<void>();
    hostA.attachCdnSwitch();
    _stall(hostA);
    await _waitFor(() => cdn.probes.isNotEmpty);

    hostA.videoItemUrl = null; // host 改写拿不出 URL（playUrls 变空）
    cdn.holdProbe!.complete();

    await _waitFor(() => log.has('host 改写后地址为空，放弃本次并冷却'));
    // 正面证据：这一轮真的选出了候选、走到了 `_switchTo`（否则那句"冷却"可能是
    // 别的路径打出来的）。
    expect(log.has('第1次 ->'), isTrue, reason: '这一轮没走到换源：\n${log.text}');
    expect(
      log.has('放弃，'),
      isFalse,
      reason: '这条失败路径在 `_switchTo` 里就地 return，不该走到收尾那句：\n${log.text}',
    );

    // 冷却真的装上了：紧接着的下一次触发被冷却闸挡下。
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _stall(hostA, const Duration(seconds: 200));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      log.has('冷却中，忽略卡顿 @200s'),
      isTrue,
      reason: '没装冷却 —— 下一次触发又冲了上去（就是那个无限重试）：\n${log.text}',
    );
  });

  test('generation 作废的那一轮不装冷却（N10 的对照组）', () async {
    // N10 修的是"真的失败"要装冷却；但**作废**的一轮是另一回事：它什么都没试过
    // （用户换了视频/画质 → `resetCdnForNewObject` 推了代际），装冷却是错的 ——
    // 那会把一个刚换了对象的页面按在 60s 冷却里，而它其实什么坏事都没发生。
    // `_autoSwitchLoop` 在循环口那道 `_roundVoided(generation)` 复查上直接 return，
    // 压根走不到收尾写冷却那一句。
    cdn.holdProbe = Completer<void>();
    hostA.attachCdnSwitch();
    _stall(hostA);
    await _waitFor(() => cdn.probes.isNotEmpty);

    hostA.resetCdnForNewObject(); // 换集/换画质：在途那一轮当场作废
    cdn.holdProbe!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(
      log.has('放弃，'),
      isFalse,
      reason: '作废的一轮不该走到收尾、更不该写冷却：\n${log.text}',
    );

    // 直接验证"没装冷却"：再来一发触发。冷却若被装上（60s），这一发会被"冷却中"
    // 挡下。触发点用 0s，`_restoreResumePosition` 于是立刻返回，这一轮不会在收尾
    // 留下要等的 800ms 拍。
    _stall(hostA, Duration.zero);
    await _waitFor(() => log.has('卡顿 @0s，开始找可用镜像'));
    expect(
      log.has('冷却中，忽略'),
      isFalse,
      reason: '作废那轮装了冷却，把这一发正常触发挡下了：\n${log.text}',
    );
  });

  test('小卡顿的节流只在探测真起步后才消费（F7）', () async {
    // `_onPlayerRebuffer` 原来的顺序是"先落下时间戳、再交给闸门"。被 busy/冷却/
    // 进展闸挡下的那一次照样把接下来 30s 的小卡顿探测机会吃掉了 —— 而那几个闸
    // 说的本来就是"现在别动"，节流却被它顺手消费，画面一直冻着也得干等 30s。
    //
    // 造一个被**进展闸**挡下的触发（它最"瞬时"，不像冷却会把后面也一起挡住）：
    // 先跑一轮把 `_cdnLastAttemptPos` 抬到 100s、卡在重载播放器那一步；再顶掉
    // 又回来（作废在途轮，但**不清** `_cdnLastAttemptPos`），一秒后发小卡顿。
    hostA
      ..holdInit = Completer<void>()
      ..attachCdnSwitch();
    _stall(hostA);
    await _waitFor(() => hostA.initCalls == 1);
    expect(log.has('第1次 ->'), isTrue, reason: '这一轮没走到选源：\n${log.text}');

    // 顶掉又回来：重挂会让在途那一轮作废，`_cdnLastAttemptPos` 仍停在 100s。
    hostB.attachCdnSwitch();
    hostA.attachCdnSwitch();
    hostA.holdInit!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // 距上次尝试只推进 1s → 被进展闸挡下，`_onPlayerStall` 返回 false。
    PlPlayerController.getInstance().onRebuffer!(const Duration(seconds: 101));
    expect(
      log.has('距上次尝试只推进了 1s，忽略'),
      isTrue,
      reason: '没被进展闸挡下，这条用例的前提不成立：\n${log.text}',
    );
    // 紧接着的一发（推进 5s，过闸）必须真的跑起来 —— 若上一发把节流时间戳写了
    // 下去，这里会被 30s 节流吃掉，只剩一行"小卡顿冷却中"。
    PlPlayerController.getInstance().onRebuffer!(const Duration(seconds: 105));
    await _waitFor(() => log.has('小卡顿 @105s'));
    expect(
      log.has('小卡顿冷却中'),
      isFalse,
      reason: '节流在探测没起步时就消费了：\n${log.text}',
    );
  });

  test('预检的 pending 只在被接受后才消费（F6）', () async {
    // `_onCdnProbeTick` 的预检支原来"先清 pending、把定时器降到 2 分钟档，再去
    // 调 `_onPlayerStall`"。那一调被冷却/进展闸当场挡下时就漏了：pending 已清、
    // 定时器已变慢，这次预检**静默消失**，要等整整 2 分钟才轮到下一次。修法是先
    // 过闸门、拿到 `accepted`，再据此消费。
    //
    // 观察点：pending 还在 ⇒ 定时器仍是 2 秒档 ⇒ 被挡下的预检会**再来**（每 2s
    // 一行"冷却中，忽略预检"）。若 pending 被消费，定时器变 2 分钟档，只剩一行。
    cdn.allTiny = true; // 造一轮 unmeasurable，顺手把 20s 冷却装上
    hostA.attachCdnSwitch();
    _stall(hostA);
    await _waitFor(() => log.has('放弃，20s 内不再尝试'));
    expect(
      log.has('放弃，20s 内不再尝试（无法测出更快的 CDN，暂不切换）'),
      isTrue,
      reason: '这一轮没落到 unmeasurable 那档冷却上，用例前提不成立：\n${log.text}',
    );

    // 让预检那一拍走到 `_onPlayerStall`：开播 + 缓冲已过回填水位。
    PlPlayerController.getInstance()
      ..playerStatus = PlayerStatus.playing
      ..buffer['demuxer-hysteresis-secs'] = '30'
      ..buffer['cache-secs'] = '30'
      ..buffered.value = 60
      ..position.value = 0;

    await _waitFor(
      () => log.lines.where((l) => l.contains('冷却中，忽略预检')).length >= 2,
      timeout: const Duration(seconds: 8),
    );
    expect(
      log.lines.where((l) => l.contains('冷却中，忽略预检')).length,
      greaterThanOrEqualTo(2),
      reason: '被挡下的预检没有再来的机会 —— pending 被静默消费了：\n${log.text}',
    );
  });

  test('回页只重挂定时器，不重新武装预检（F11）', () async {
    // 首次挂载（页面 onInit）武装装载后那一次预检；回页（didPopNext 再挂一次）
    // 只重挂定时器 —— 无条件再武装等于每次从相关视频返回都白花一轮 ~6MB 的测速。
    // 两次调的是同一个方法，只能靠"本页有没有挂载过"来分：
    // `restartCdnProbe(armPreflight: !_cdnAttachedOnce); _cdnAttachedOnce = true;`。
    //
    // 观察点：让首次预检真的跑掉（pending 归假），再模拟"跳走又回来"。回页若又
    // 把它设回真，就会冒出第二次预检；否则永远只有那一次。
    hostA.attachCdnSwitch();
    PlPlayerController.getInstance()
      ..playerStatus = PlayerStatus.playing
      ..buffer['demuxer-hysteresis-secs'] = '30'
      ..buffer['cache-secs'] = '30'
      ..buffered.value = 60
      ..position.value = 0;

    await _waitFor(() => log.has('预检 @'));
    expect(
      log.lines.where((l) => l.contains('预检 @')).length,
      1,
      reason: '首次预检没跑起来，用例前提不成立：\n${log.text}',
    );

    // 跳去相关视频（新页抢走回调），又退回来（didPopNext 再挂一次）。
    hostB.attachCdnSwitch();
    hostA.attachCdnSwitch();
    await Future<void>.delayed(const Duration(seconds: 3));

    expect(
      log.lines.where((l) => l.contains('预检 @')).length,
      1,
      reason: '回页把预检又武装了一次 —— 白花一轮测速：\n${log.text}',
    );
  });

  test('解码错误档端到端：force 换源 + 只认"不再吐坏字节"的恢复（F10）', () async {
    // onDecodeError → force=true → `_awaitRecovery(decode: true)`。这一档的两条
    // 位置/余量判据都不可信（坏镜像余量填得满、位置被音频时钟推着走），只看
    // "换过去之后还吐不吐坏字节"。这里把回填水位/余量摆成"够健康"的样子：若误走
    // 非 decode 的判据，会在第一拍就宣布恢复并打出"前向余量回到"。
    PlPlayerController.getInstance()
      ..buffer['demuxer-hysteresis-secs'] = '30'
      ..buffer['cache-secs'] = '30'
      ..buffered.value = 60
      ..position.value = 0;
    hostA.attachCdnSwitch();

    PlPlayerController.getInstance().onDecodeError!(Duration.zero);

    await _waitFor(() => log.has('第1次 ->'));
    // force 的独有痕迹之一：触发那条源（正在播的 host）被记入本集黑名单。
    expect(
      log.has('$_baselineHost 给的字节解不出画面，本集不再作为候选'),
      isTrue,
      reason: 'force 的"坏 host 记账"没走到：\n${log.text}',
    );

    // 解码档的恢复要等"宽限 4s + 干净窗口 4s"≈8s，比别的用例长。
    await _waitFor(
      () => log.has('成功，已切到'),
      timeout: const Duration(seconds: 20),
    );
    expect(
      log.has('解码错误档换源后'),
      isTrue,
      reason: '恢复不是走解码档判据判出来的：\n${log.text}',
    );
    expect(
      log.has('前向余量回到'),
      isFalse,
      reason: 'decode=true 的恢复判据不该去看余量（那是坏镜像最会骗人的一项）：\n${log.text}',
    );
  });

  test('坏字节的一次性上报不许被放弃冷却吞掉', () async {
    // 播放器侧的风暴上报是**一次性消费**：先清空窗口、再武装 30s 静默、最后才回调。
    // 这条通道**现在有回执**（`onDecodeError` 返回 `bool`）：页面在途轮次会回 `false`，
    // 播放器据此把静默期缩成 2s 退避、之后重发 —— 所以"被下游丢掉的那一次永远不会
    // 重报"这条已经不成立（见下面 T1 / T2 两条用例）。
    //
    // 本用例钉的是**另一件**事：放弃冷却（20~60s）那道闸对解码档的豁免。回执管的是
    // "在途轮次拒收后能不能重发"，豁免管的是"这一发到底会不会被冷却吞掉"—— 两件事。
    //
    // 2026-10-12 真机取证：坏镜像喂坏字节（截断在 54MB/788MB + 非法 NAL），那次唯一
    // 的风暴上报（13:56:10.169）正好落在轮 1 挣来的 20s 冷却里被吞掉，画面冻了 6 分
    // 半，直到定期档碰巧撞上"基线无有效样本 → 直接切换"才恢复。
    //
    // 解码错误是唯一**跳过比值、直接换源**的触发，它自己的节流是播放器侧的
    // `_kDecodeErrorCooldown`（一次故障只报一次）—— 这里再压一道等于双保险变零保险。
    // 所以它像绕过进展闸那样，也绕过放弃冷却。
    cdn.allTiny = true; // 造一轮 unmeasurable，顺手把 20s 冷却装上（与 F6 同法）
    hostA.attachCdnSwitch();
    _stall(hostA);
    await _waitFor(() => log.has('放弃，20s 内不再尝试'));
    expect(
      log.has('放弃，20s 内不再尝试（无法测出更快的 CDN，暂不切换）'),
      isTrue,
      reason: '这一轮没落到 unmeasurable 那档冷却上，用例前提不成立：\n${log.text}',
    );

    // 先确认这道冷却对**别的**触发照旧有效 —— 否则下面的否定是空的。
    _stall(hostA);
    expect(
      log.has('冷却中，忽略卡顿'),
      isTrue,
      reason: '冷却没挡住非解码触发，用例前提不成立：\n${log.text}',
    );

    // 同一窗口里的解码错误上报必须当场起步（`_describeTrigger` 打在闸门之后）。
    PlPlayerController.getInstance().onDecodeError!(const Duration(seconds: 100));
    expect(
      log.has('冷却中，忽略解码错误'),
      isFalse,
      reason: '坏字节上报又被放弃冷却吞了，而它是一次性消费、不会再来：\n${log.text}',
    );
    await _waitFor(() => log.has('解码错误 @100s，当前镜像给的是坏字节'));
  });

  test('解码风暴被在途轮次拒收后要退避重报，不是丢了等 30 秒', () {
    final pc = PlPlayerController.getInstance()..resetDecodeErrorAccounting();
    var calls = 0;
    var accept = false;
    pc.onDecodeError = (_) {
      calls++;
      return accept;
    };

    // 稀疏档 6s / 12 条、去重窗 5ms：10ms 间隔喂 12 条既能稳定达标，
    // 又不会让密集档（100ms / 20 行）抢先成立。
    void burst(DateTime end) {
      for (var i = 0; i < 12; i++) {
        pc.debugSampleDecodeError(
          'Invalid NAL unit size (34817 > 5117).',
          end.subtract(Duration(milliseconds: 10 * (11 - i))),
        );
      }
    }

    final t0 = DateTime(2026, 1, 1);
    burst(t0);
    expect(calls, 1, reason: '门槛一到就该上报一次');

    burst(t0.add(const Duration(seconds: 1)));
    expect(calls, 1, reason: '退避期内不该重报');

    burst(t0.add(const Duration(seconds: 3)));
    expect(calls, 2, reason: '退避过后必须重报 —— 被在途轮次挡下的这一发不丢');

    accept = true;
    burst(t0.add(const Duration(seconds: 6)));
    expect(calls, 3);

    burst(t0.add(const Duration(seconds: 10)));
    expect(calls, 3, reason: '被受理后走正常的 30s 静默');
  });

  test('在途轮次里的解码风暴要退回播放器重发，轮次结束后仍能起步', () async {
    final pc = PlPlayerController.getInstance();
    // allTiny 让这一轮量不出速度、快速落到"放弃"收尾（同"坏字节的一次性上报不许被
    // 放弃冷却吞掉"那条用例的手法）—— 注意这一档**不会**选候选、也就不会调 playerInit，
    // 所以不能用 initCalls 判 busy；busy 是 `_stall` **同步**置上的，直接断言就行。
    cdn.allTiny = true;
    hostA.attachCdnSwitch();
    _stall(hostA); // 默认 position=100s
    expect(hostA.debugCdnAutoBusy, isTrue, reason: '用例前提：轮次在途');

    // 轮次在途：解码风暴收不下 → 回执 false，且不许起步。
    expect(
      pc.onDecodeError!(const Duration(seconds: 100)),
      isFalse,
      reason: '轮次在途时必须回 false，播放器才会保住这一发',
    );
    expect(log.has('忽略解码错误'), isTrue);
    // ⚠ 否定断言别用 '解码错误 @100s' —— busy 那行 '忽略解码错误 @100s (busy=…)' 也含这个子串。
    expect(
      log.has('当前镜像给的是坏字节'),
      isFalse,
      reason: '轮次在途时不该起步换源',
    );

    await _waitFor(() => !hostA.debugCdnAutoBusy); // 这一轮收尾、busy 已清

    // 收尾后再来一发（模拟播放器退避后的重发）→ 这回该起步。
    expect(
      pc.onDecodeError!(const Duration(seconds: 100)),
      isTrue,
      reason: '轮次收尾后同一发风暴要能起步（不再丢）',
    );
    await _waitFor(() => log.has('解码错误 @100s，当前镜像给的是坏字节'));
  });

  test('持续饥饿每 20s 补报一次，恢复后重新武装', () {
    // 病灶（2026-10-12 真机取证）：播放器判据 3 的去重是"一段饥饿只报一次"，
    // 而"这段结束"的判据是余量涨回 mpv 自己的水位 —— 镜像持续供不上（或像那次
    // 一样持续喂坏字节）时它**永远不结束**，于是那唯一一次上报被页面侧的放弃冷却
    // 吞掉之后，后面 52 秒再没有任何信号，只能等 2 分钟定期档兜底。
    //
    // 这条用例盯的是"还在饿就每 20s 再出声一次"，以及"恢复之后不许继承上一个
    // 20s 的节流"。放在这个文件里是因为播放器单例的状态（Hive / Pref / `buffer`
    // 那个 late final）在这里已经摆好了 —— 而 `_sampleStarve` 只看 `now` 和几个
    // 公开 Rx 字段，不需要真播放器（驱动它的 1s ticker 才需要，见
    // `controller.dart` 的 `debugSampleStarve`）。
    final pc = PlPlayerController.getInstance();
    var reports = 0;
    pc.onBufferStarve = (_) => reports++;
    // 静默期（`_armRebufferSuppress`，8s）是与挂钟比较的，所以时间戳取在未来，
    // 免得撞上前一个用例留下的窗口。
    final base = DateTime.now().add(const Duration(minutes: 5));
    DateTime at(int s) => base.add(Duration(seconds: s));

    pc
      // 拿 reload 当"从头开始"：任何一次真实装载都会这样归零三条判据。`dataSource`
      // 是 `late`，不摆好这里会抛。
      ..dataSource = NetworkSource(videoSource: _baselineUrl, audioSource: null)
      ..refreshPlayer()
      ..buffer['demuxer-hysteresis-secs'] = '10' // 阈值 6.0s → 判据启用
      ..duration.value = 3600
      ..position.value = 100
      ..buffered.value = 100; // 前方余量 0：趴在低位

    // 攒够连续采样之前不许出声（去重状态已被上面那次 reload 清空）。
    for (var i = 0; i < 3; i++) {
      pc.debugSampleStarve(at(i));
    }
    expect(reports, 0, reason: '还没攒够 $_kStarveSecondsExpect 拍就上报了：\n${log.text}');

    pc.debugSampleStarve(at(3));
    expect(reports, 1, reason: '攒够了却没上报：\n${log.text}');
    expect(
      log.has('缓冲饥饿: 前方余量 0s < 6.0s (连续 4 s) @100s'),
      isTrue,
      reason: log.text,
    );

    // 同一段饥饿里 20s 之内不许重复，越过 20s 必须再报。
    pc.debugSampleStarve(at(18));
    expect(reports, 1, reason: '20s 之内就重复上报了：\n${log.text}');
    pc.debugSampleStarve(at(23));
    expect(reports, 2, reason: '越过 20s 还没补报 —— 这正是那次裸奔 52 秒：\n${log.text}');
    expect(log.has('缓冲饥饿: 仍在饥饿，再次上报'), isTrue, reason: log.text);

    // 余量回到 mpv 自己的水位（6.0 / 0.6 = 10s）→ 这段饥饿结束、去重清空。
    // 抬到 120 而不是随便一个更大的数：余量超过缓存上限的 3 倍会先落进
    // "遥测失真"那一支（`_divergedAheadSec` = 16s × 3 = 48s）。
    pc.buffered.value = 120;
    pc.debugSampleStarve(at(24));
    expect(log.has('缓冲饥饿: 已恢复 (20s)'), isTrue, reason: log.text);
    expect(reports, 2, reason: '恢复本身不该上报：\n${log.text}');

    // 新的一段立刻可以出声：它离上一次上报只有 5s，靠的正是"恢复时把节流清空"。
    pc.buffered.value = 100;
    for (var i = 25; i < 28; i++) {
      pc.debugSampleStarve(at(i));
    }
    expect(reports, 2, reason: '新一段还没攒够就上报了：\n${log.text}');
    pc.debugSampleStarve(at(28));
    expect(reports, 3, reason: '恢复之后的新一段被上一段的节流压住了：\n${log.text}');

    // 新的一段里补报照旧。
    pc.debugSampleStarve(at(43));
    expect(reports, 3, reason: '新一段里 20s 之内就重复了：\n${log.text}');
    pc.debugSampleStarve(at(48));
    expect(reports, 4, reason: '新一段里越过 20s 没补报：\n${log.text}');
  });

  // 判据 3 的两支分流（2026-10-12 log 17 取证）。原来"前向余量趴在低位"和"余量
  // 涨到失真（音频在走、画面冻着）"共用 `onBufferStarve` 一条回调、共用
  // `_CdnTrigger.starve` 一个标签，于是后者拿不到页面侧的闸门豁免 —— 那局真机日志
  // 里，三次失真上报被一次**无关**尝试留下的 60s 放弃冷却吞掉两次，画面多冻了
  // 61 秒，而它自己的节流是 20s 补报一次。修法是把失真那一支拆成独立触发
  // `_CdnTrigger.diverged`（日志里叫「画面已冻」），给它 `decode` 那两条**闸门**
  // 豁免，但**不给**比值关豁免。
  //
  // 这里盯三件事：出口分得干净、闸门豁免真的生效、以及没顺手拿到比值关豁免
  // （那是被否掉的方案）。后两件都靠 log 17 的现场复放。
  //
  // 已知测不到的一处：进展闸（`position - _cdnLastAttemptPos < 3s`）那半截与冷却
  // 那半截共用同一个谓词（`_CdnTrigger.bypassesGates`），所以下面那条用例的红证只
  // 能证明冷却那半截。要单独红证进展闸得先让 `_cdnLastAttemptPos` 非零，而那要求
  // 一轮真的换过源、且 `_awaitRecovery` 跑满 12s 窗口才返回 false —— 这半边在
  // `decode` 档上同样是盲区，不是这次新欠的。别以为它测过了。
  group('画面已冻独立成触发（判据 3 的两支分流）', () {
    late PlPlayerController pc;

    setUp(() {
      pc = PlPlayerController.getInstance()
        // 拿 reload 当"从头开始"：任何一次真实装载都会这样归零三条判据。
        // `dataSource` 是 `late`，不摆好这里会抛。
        ..dataSource = NetworkSource(videoSource: _baselineUrl, audioSource: null)
        ..refreshPlayer()
        ..buffer['demuxer-hysteresis-secs'] = '10' // 饥饿线 6.0s → 判据启用
        ..buffer['cache-secs'] = '30' // 失真线 30 × 3 = 90s
        ..duration.value = 3600
        ..position.value = 100
        ..buffered.value = 100
        // 这两个是单例上的字段，上一个用例留下的闭包会跨用例计数。
        ..onBufferStarve = null
        ..onTelemetryDiverged = null;
    });

    tearDown(() {
      pc
        ..onBufferStarve = null
        ..onTelemetryDiverged = null
        // `buffer` 是 late final，两个键都会跨用例留下。全局 setUp 只归零
        // hysteresis；`cache-secs` 留着 30 会让后面用例的 `telemetryDiverged`
        // 凭空为真（失真线从 0 变成 90s）。
        ..buffer['demuxer-hysteresis-secs'] = '0'
        ..buffer['cache-secs'] = '0';
    });

    test('余量失真走新出口，低水位那支收不到', () {
      var starve = 0;
      var diverged = 0;
      // 余量 95s：高过失真线 90s，也高过饥饿线 6.0s —— 只有失真那一支够得着。
      // 它不需要连续几拍（那是低水位那支的规矩），一拍就该出声。
      pc
        ..onBufferStarve = (_) {
          starve++;
        }
        ..onTelemetryDiverged = (_) {
          diverged++;
        }
        ..position.value = 100
        ..buffered.value = 195
        ..debugSampleStarve(_sampleAt(0));

      expect(diverged, 1, reason: '失真那一支没走新出口：\n${log.text}');
      expect(
        starve,
        0,
        reason: '失真那一支还落在 onBufferStarve 上 —— 拆分没做到：\n${log.text}',
      );
      expect(
        log.has(
          'CDN 遥测失真: 余量 95s 超过缓存上限 90.0s 的 3.0x '
          '(音频在走，画面已冻) @100s',
        ),
        isTrue,
        reason: '失真那支自己的判据没成立（余量算错了？）：\n${log.text}',
      );
    });

    test('低水位仍走旧出口，新出口收不到', () {
      var starve = 0;
      var diverged = 0;
      // 余量 0：趴在低位。这一支要连续 4 拍 —— 顺手钉住"这次改动没把它一起改了"。
      pc
        ..onBufferStarve = (_) {
          starve++;
        }
        ..onTelemetryDiverged = (_) {
          diverged++;
        }
        ..position.value = 100
        ..buffered.value = 100
        ..debugSampleStarve(_sampleAt(0));
      for (var i = 1; i < 3; i++) {
        pc.debugSampleStarve(_sampleAt(i));
      }
      expect(starve, 0, reason: '还没攒够 $_kStarveSecondsExpect 拍就出声了：\n${log.text}');
      pc.debugSampleStarve(_sampleAt(3));

      expect(starve, 1, reason: '低水位那一支的出口被这次改动带走了：\n${log.text}');
      expect(diverged, 0, reason: '低水位那一支不该走新出口：\n${log.text}');
      expect(
        log.has('缓冲饥饿: 前方余量 0s < 6.0s (连续 $_kStarveSecondsExpect s) @100s'),
        isTrue,
        reason: log.text,
      );
    });

    test('画面已冻的上报不许被放弃冷却吞掉', () async {
      // log 17 那 61 秒就是这个：21:28:48 一次无关尝试挣出 60s 冷却，21:29:22 与
      // 21:29:43 两次失真上报被 `冷却中，忽略缓冲饥饿` 吞掉，直到 21:30:04 冷却
      // 过期才放行。
      cdn.allTiny = true; // 造一轮 unmeasurable，顺手把冷却装上（与 F8 同法）
      hostA.attachCdnSwitch();
      _stall(hostA);
      await _waitFor(() => log.has('放弃，20s 内不再尝试'));

      // 先确认这道冷却对**别的**触发照旧有效 —— 否则下面的否定是空的。
      _stall(hostA);
      expect(
        log.has('冷却中，忽略卡顿'),
        isTrue,
        reason: '冷却没挡住非豁免触发，用例前提不成立：\n${log.text}',
      );

      // 同一窗口里的失真上报必须当场起步（`_describeTrigger` 打在闸门之后）。
      // 红证：把 `_CdnTrigger.bypassesGates` 改回只认 decode，这句断言变红。
      _diverge();
      expect(
        log.has('冷却中，忽略画面已冻'),
        isFalse,
        reason: '画面已冻的上报又被放弃冷却吞了 —— 正是 log 17 那 61 秒：\n${log.text}',
      );
      await _waitFor(() => log.has('画面已冻 @100s，'));
    });

    test('坏源那一局能自己走出来，且不许给新触发开 force（log 17 复放）', () async {
      // log 17 的现场：切画质拿到坏地址 → 视频轨不吐数据 → 余量涨到失真。那条真机
      // 日志里它靠"定期档碰巧撞上基线无有效样本"才恢复。这里把那条路径重放一遍：
      // 基线留在 [_baselineUrl]（假适配器只回 8KiB 小样本 = 拿不出有效速度），于是
      // 这一轮必然走"基线无有效速度，直接切换"。
      hostA.attachCdnSwitch();
      _diverge();

      await _waitFor(() => log.has('画面已冻 @100s，'));
      await _waitFor(() => log.has('基线无有效速度，直接切换'));
      expect(log.has('第1次 ->'), isTrue, reason: '触发起步了却没换源：\n${log.text}');

      // 这一轮**真的换过源**（上一句就是证据），所以下面两条否定不是空的：`force`
      // 会给正在播的 host 定罪并把整集拉黑，理由写的是"字节解不出画面"—— 而失真
      // 这个签名分不出"视频轨死了"和"位置读数归零造成的假失真"，后者的字节是好的。
      expect(
        log.has('给的字节解不出画面，本集不再作为候选'),
        isFalse,
        reason: '给新触发开了 force，把当前 host 冤枉拉黑了：\n${log.text}',
      );
      expect(
        log.has('当前镜像的字节解不出画面'),
        isFalse,
        reason: '给新触发开了 force，套用了解码档的措辞：\n${log.text}',
      );
    });

    test('画面已冻时"没找到更快的镜像就重载当前源"这条兜底仍然可达', () async {
      // 与 F 组「没被顶掉时兜底重载照旧」同一个局面，只把入口换成失真上报。锁的是
      // **被否掉的那个方案**：若照抄 decode 给新触发也开 `force`，`_autoSwitchLoop`
      // 收尾那句 `if (!switched && !force && telemetryDiverged)` 就不成立，这句日志
      // 会消失 —— 而它正是这个故障唯一不换源的解法。
      //
      // 前提摆两样（同 F 组）：`cache-secs` 30s × 3 = 90s 是失真线、余量 200s 压在
      // 上面；基线挪到 [_steadyBaselineUrl]，让这一轮落成一条**不切换**的裁定。
      PlPlayerController.getInstance()
        ..dataSource = NetworkSource(
          videoSource: _steadyBaselineUrl,
          audioSource: null,
        )
        ..buffer['cache-secs'] = '30'
        ..buffered.value = 200
        ..position.value = 0;
      hostA
        ..videoUrl = _steadyBaselineUrl
        ..attachCdnSwitch();

      _diverge(Duration.zero);

      await Future<void>.delayed(const Duration(seconds: 3));
      expect(
        log.has('-> 不切换'),
        isTrue,
        reason: '这一轮本该判成不切换（基线健康、候选不快）—— 裁定变了就不是这条用例在测的东西了：'
            '\n${log.text}',
      );
      expect(
        log.has('画面已冻（余量失真），重载当前源'),
        isTrue,
        reason: '给新触发开了 force，这句兜底被关掉了：\n${log.text}',
      );
    });
  });

  // 「无视频轨」自愈失败后的就地重建（P3）。这里能测的只有**判据**：真正拆
  // `Player`、重建渲染上下文、请页面重载那一段全都要真 libmpv（测试进程里
  // `_videoPlayerController` 恒为 null，`_kNoVideoProbes` 探满之后
  // `_healNoVideoTrack` 第一句就 return false），所以断言落在"闸门说了什么"和
  // "失败之后有没有去叩那道门"上。两者都是这次新增的代码路径，去掉修复即红。
  //
  // 已知覆盖不到的一处：`_renderRebuildBlocker` 里"换源/换集在途"（`_processing`）
  // 那道闸门 —— 它排在"播放器不存在"**之后**，而测试进程里 player 恒为 null，
  // 所以永远停在前一条。别给 `_processing` 加测试缝去凑：缝有了也走不到。
  group('无视频轨自愈失败 → 就地重建渲染上下文', () {
    late PlPlayerController pc;

    setUp(() {
      pc = PlPlayerController.getInstance()
        // setUp 每次都 `getInstance()`，`_playerCount` 跨用例只增不减，摆不成
        // "恰好一个页面持有单例"这个前提。
        ..debugPlayerCount = 1
        ..debugNoVideoRebuilds = 0
        // 下面这几样在测试进程里**没有别的复位点**（生产里的复位分别在
        // `_createVideoController` 与页面 `dispose()`，测试都够不到），不在这里
        // 摆干净就会把后面的用例污染成另一种初始状态。
        ..debugNoVideoHealed = false
        ..debugRebuildingRenderContext = false
        ..debugClearRenderReloadListeners();
    });

    tearDown(() {
      pc
        ..debugRebuildingRenderContext = false
        ..debugNoVideoHealed = false
        ..debugNoVideoRebuilds = 0
        ..debugPlayerCount = 1
        ..debugClearRenderReloadListeners()
        // 强指纹注入缝也还回默认值（null ⇒ 走真实判据）。不还的话，后面用例会
        // 在别人摆出的强指纹下悄悄走快路。
        ..debugNoVideoStrongOverride = null
        // `isBuffering` 的初值就是 true（`controller.dart:222`），还回原样。
        ..isBuffering.value = true
        // openNoVideoGates 摆过、又不属于本 group 的字段，同样还回去。
        ..isSeeking.value = false
        ..onlyPlayAudio.value = false
        ..isLive = false
        ..position.value = 0;
    });

    /// 把 [_checkNoVideoTrack] 的六道门全部放开。
    ///
    /// 必须显式摆一遍，不能靠默认值：单例跨用例存活，而这些标志位上一批用例
    /// 早就动过了 —— 尤其 `isBuffering` **初值就是 true**，光看代码会以为它默认
    /// 是关的。第一版就是栽在这上面：一条日志都没打出来。
    void openNoVideoGates() {
      pc
        ..position.value = 100
        ..isBuffering.value = false
        ..isSeeking.value = false
        ..onlyPlayAudio.value = false
        ..isLive = false
        ..debugPlayerCount = 1;
    }

    /// 把"连空几探"的计数与位置记忆一起归零。
    ///
    /// 生产里每个 `_noVideoProbes = 0` 的返回点都会顺手清掉位置记忆，测试进程里
    /// 没有那个复位口 —— 这两样又都是单例字段、跨用例只增不减。用一记"闸门关着"
    /// 的探针复刻那一步即可：`position.value <= 0` 恰好落在关着的那一侧。不归零
    /// 的话，前一个用例探过的拍数会记到这一个头上。
    void resetNoVideoProbe() {
      pc
        ..position.value = 0
        ..debugCheckNoVideoTrack();
    }

    test('没有页面认领重载就不许重建：拆了没人把它建回来', () {
      expect(pc.debugRenderRebuildBlocker(), '没有页面认领重载');
    });

    test('认领之后这一条让开，轮到下一道闸门（否定不是空的）', () {
      Future<void> reload() async {}
      final pageA = Object();
      expect(pc.debugRenderRebuildBlocker(), '没有页面认领重载');

      pc.addRenderReloadListener(pageA, reload);
      expect(
        pc.debugRenderRebuildBlocker(),
        '播放器不存在',
        reason: '认领了就该放过"没人认领"，在测试进程里停在下一条：没有真 Player',
      );

      // 卸认领只是**休眠**（页面还在），所以这一条又该拦回来。
      pc.removeRenderReloadListener(pageA);
      expect(pc.debugRenderRebuildBlocker(), '没有页面认领重载');
    });

    test('直播间并存时不重建：它计了数却从不认领重载', () {
      // 这就是"视频页 + 直播间"的形状：两个页面控制器都 `getInstance()`（`_playerCount`
      // == 2），而只有视频页会认领 —— 直播间从不认领、也不登记休眠，于是落在"计了数却
      // 没登记身份"的差额里，拆了会把直播间的播放一起掀掉。
      // 同一形状也覆盖"新页刚 push、认领还没发生"那个瞬时窗口（数值同形，语义不同）。
      Future<void> reload() async {}
      final pageA = Object();
      pc
        ..addRenderReloadListener(pageA, reload)
        ..debugPlayerCount = 2;
      // 卸在 tearDown 而不是断言之后：断言抛了就轮不到它执行，集合会漏进后面的
      // 用例（那边的日志会变成另一个理由，看起来像它自己的毛病）。
      addTearDown(() => pc.removeRenderReloadListener(pageA));
      expect(pc.debugRenderRebuildBlocker(), '有 1 个共用者没登记身份（直播间/装载中）');
    });

    // ---- 细口径放行：多出来的共用者只要全是"登记过的休眠视频页"就放行 ----

    test('视频页被视频页压住：休眠的旧页可解释 → 放行到下一道闸', () {
      // 本次要修的场景：旧页被 B 压住时 `didPushNext` 只卸认领、**不** dispose，
      // `_playerCount` 一直挂着 2 —— 老判据 `_playerCount != 1` 在这里**恒拦**，
      // 整个覆盖期间用户只能手动退出再进。
      Future<void> reload() async {}
      final pageA = Object(); // 被压住的旧页（休眠）
      final pageB = Object(); // 压在上面的新页（认领中）
      pc
        ..addRenderReloadListener(pageA, reload)
        ..removeRenderReloadListener(pageA)
        ..addRenderReloadListener(pageB, reload)
        ..debugPlayerCount = 2;
      addTearDown(() => pc.removeRenderReloadListener(pageB));
      expect(
        pc.debugRenderRebuildBlocker(),
        '播放器不存在',
        reason: '休眠页可以解释，该放过"共用者"这一条，停在测试进程的下一条',
      );
    });

    test('三个视频页叠加：两层休眠一并放行', () {
      Future<void> reload() async {}
      final pageA = Object();
      final pageB = Object();
      final pageC = Object();
      pc
        ..addRenderReloadListener(pageA, reload)
        ..removeRenderReloadListener(pageA)
        ..addRenderReloadListener(pageB, reload)
        ..removeRenderReloadListener(pageB)
        ..addRenderReloadListener(pageC, reload)
        ..debugPlayerCount = 3;
      addTearDown(() => pc.removeRenderReloadListener(pageC));
      expect(pc.debugRenderRebuildBlocker(), '播放器不存在');
      expect(pc.debugRenderReloadClaimants, {pageC});
      expect(pc.debugDormantRenderClaimants, {pageA, pageB});
    });

    test('两个页面同时认领时不重建：掀谁都不对', () {
      Future<void> reload() async {}
      final pageA = Object();
      final pageB = Object();
      pc
        ..addRenderReloadListener(pageA, reload)
        ..addRenderReloadListener(pageB, reload)
        ..debugPlayerCount = 2;
      addTearDown(() {
        pc
          ..removeRenderReloadListener(pageA)
          ..removeRenderReloadListener(pageB);
      });
      expect(pc.debugRenderRebuildBlocker(), '有 2 个页面同时认领重载');
    });

    test('休眠页消亡后不占名额：页面 dispose 必须 forget，不能只卸认领', () {
      // 这条钉的是本次唯一"靠纪律"的点：页面消亡时只 `removeRenderReloadListener`
      // （= 休眠）而不 `forgetRenderReloadOwner`，死 token 会留着占名额 —— 一边计数已减、
      // 一边名册还挂着，重建闸门的等式就被"抵消"了。这里摆出忘掉 forget 的后果。
      Future<void> reload() async {}
      final pageA = Object();
      final pageB = Object();
      pc
        ..addRenderReloadListener(pageA, reload)
        ..removeRenderReloadListener(pageA)
        ..addRenderReloadListener(pageB, reload)
        ..debugPlayerCount = 2;
      addTearDown(() => pc.removeRenderReloadListener(pageB));
      // A 那一世结束：计数减 1，身份也从两处抹掉。
      pc
        ..debugPlayerCount = 1
        ..forgetRenderReloadOwner(pageA);
      expect(pc.debugDormantRenderClaimants, isEmpty);
      expect(pc.debugRenderRebuildBlocker(), '播放器不存在');
    });

    test('认领/卸认领反复调用是幂等的，不造幽灵休眠', () {
      Future<void> reload() async {}
      final pageA = Object();
      for (var i = 0; i < 3; i++) {
        pc
          ..addRenderReloadListener(pageA, reload)
          ..removeRenderReloadListener(pageA);
      }
      pc.addRenderReloadListener(pageA, reload);
      addTearDown(() => pc.removeRenderReloadListener(pageA));
      expect(pc.debugRenderReloadClaimants, {pageA});
      expect(pc.debugDormantRenderClaimants, isEmpty);
      expect(pc.debugRenderRebuildBlocker(), '播放器不存在');

      // 反过来：没认领过就卸，什么都不该发生（尤其不能进休眠集）。
      pc.removeRenderReloadListener(Object());
      expect(pc.debugDormantRenderClaimants, isEmpty);
    });

    test('认领之前就 forget 不留幽灵休眠', () {
      // 同一条纪律的另一半：forget 是"从两处都抹掉"，不是"顺手往休眠集里塞一笔"。
      final pageA = Object();
      pc.forgetRenderReloadOwner(pageA);
      expect(pc.debugRenderReloadClaimants, isEmpty);
      expect(pc.debugDormantRenderClaimants, isEmpty);
      expect(pc.debugRenderRebuildBlocker(), '没有页面认领重载');
    });

    test('已经在重建时不许重入：拆第二遍会让两个 Player 抢同一个 handle', () {
      Future<void> reload() async {}
      final pageA = Object();
      pc
        ..addRenderReloadListener(pageA, reload)
        ..debugRebuildingRenderContext = true;
      addTearDown(() => pc.removeRenderReloadListener(pageA));
      expect(pc.debugRenderRebuildBlocker(), '已在重建');
    });

    test('额度用完先放弃，不再往下问别的条件', () {
      // 有意**不**认领重载、也不把页面数摆成 1：额度这一条必须排在它们前面，
      // 否则额度用完时还会一路问下去，最后落在别的理由上、放弃得不明不白。
      pc
        ..debugPlayerCount = 3
        ..debugNoVideoRebuilds = _kNoVideoRebuildMaxExpect;
      expect(pc.debugRenderRebuildBlocker(), '本媒体已重建 2 次');
    });

    test('探满死锁 → 自愈失败（没有 Player）→ 升级去叩重建那道门', () async {
      openNoVideoGates();
      expect(pc.debugRenderRebuildBlocker(), '没有页面认领重载');

      for (var i = 0; i < _kNoVideoProbesExpect; i++) {
        pc.debugCheckNoVideoTrack();
      }
      // `_healNoVideoTrack().then(...)` 是一次微任务，让它落地。
      await Future<void>.delayed(Duration.zero);

      expect(
        log.has('无视频轨: 音频正常但画面始终为空'),
        isTrue,
        reason: '探满 $_kNoVideoProbesExpect 次就该报现场：\n${log.text}',
      );
      expect(
        log.has('就地重建: 跳过（没有页面认领重载）'),
        isTrue,
        reason: '自愈失败之后没有去叩重建那道门：\n${log.text}',
      );
    });

    test('重建窗口里不许把自己刚做的动作当成新的死锁再探（红测）', () {
      // 上一条是这条的对照组：同样的门、同样的探数，唯一的差别是窗口标志。
      // 没有那一句开门的辅助，这条会**假绿** —— 门本来就关着，什么都不设也过。
      openNoVideoGates();
      pc.debugRebuildingRenderContext = true;
      for (var i = 0; i < _kNoVideoProbesExpect + 2; i++) {
        pc.debugCheckNoVideoTrack();
      }
      expect(
        log.has('无视频轨:'),
        isFalse,
        reason: '重建期间画面本来就还没起来，不该把这个当成新的死锁：\n${log.text}',
      );
    });

    // ---- 强指纹快路：解码器真起来了就 2 探动手（2026-10-15）----

    test('强指纹 + 位置在推进 → 2 探即认死锁，上报行带 [强指纹]', () async {
      // 测试进程里没有原生 Player（`_safeProp` 恒空），强指纹永远为假，只能靠注入缝摆。
      resetNoVideoProbe();
      openNoVideoGates();
      pc
        ..debugNoVideoStrongOverride = (() => true)
        ..position.value = 100
        ..debugCheckNoVideoTrack();
      expect(
        log.has('无视频轨:'),
        isFalse,
        reason: '强指纹也走满 $_kNoVideoProbesFastExpect 探才动手，第 1 探不该报：\n${log.text}',
      );

      // 第 2 探：位置比上一探大（100 → 101），强指纹成立 → 计数够 $_kNoVideoProbesFastExpect。
      pc
        ..position.value = 101
        ..debugCheckNoVideoTrack();
      await Future<void>.delayed(Duration.zero);

      expect(
        log.has('无视频轨: 音频正常但画面始终为空'),
        isTrue,
        reason: '强指纹下 $_kNoVideoProbesFastExpect 探就该报现场：\n${log.text}',
      );
      expect(
        log.has('[强指纹]'),
        isTrue,
        reason: '强指纹那条上报行该带 [强指纹] 后缀（基串不变，只加尾巴）：\n${log.text}',
      );
    });

    test('弱指纹仍要探满 $_kNoVideoProbesExpect 探：没有证据就不抢跑', () async {
      resetNoVideoProbe();
      openNoVideoGates();
      pc.debugNoVideoStrongOverride = () => false;

      // 前 $_kNoVideoProbesFastExpect 探：位置照常推进，但指纹是弱的 —— 不许报。
      for (var i = 0; i < _kNoVideoProbesFastExpect; i++) {
        pc
          ..position.value = 100 + i
          ..debugCheckNoVideoTrack();
      }
      expect(
        log.has('无视频轨:'),
        isFalse,
        reason: '弱指纹下第 $_kNoVideoProbesFastExpect 探还不该动手：\n${log.text}',
      );

      // 补满到第 $_kNoVideoProbesExpect 探才该报。
      for (var i = _kNoVideoProbesFastExpect; i < _kNoVideoProbesExpect; i++) {
        pc
          ..position.value = 100 + i
          ..debugCheckNoVideoTrack();
      }
      await Future<void>.delayed(Duration.zero);

      expect(
        log.has('无视频轨: 音频正常但画面始终为空'),
        isTrue,
        reason: '弱指纹下要探满 $_kNoVideoProbesExpect 探才报：\n${log.text}',
      );
      expect(
        log.has('[强指纹]'),
        isFalse,
        reason: '弱指纹的上报行不带后缀：\n${log.text}',
      );
    });

    test('闸门一关就把计数清掉：旧的那一探不记到新一轮头上', () async {
      resetNoVideoProbe();
      openNoVideoGates();
      // 强指纹先走一探（计数到 1，差 1 探就该动手）。
      pc
        ..debugNoVideoStrongOverride = (() => true)
        ..position.value = 100
        ..debugCheckNoVideoTrack();
      expect(log.has('无视频轨:'), isFalse, reason: '第 1 探不该报：\n${log.text}');

      // 位置归零 = 走 `position.value <= 0` 那道门 → 计数与位置记忆一起归零。
      pc
        ..position.value = 0
        ..debugCheckNoVideoTrack();

      // 重开闸门，只再探一探。位置取一个必然大于任何旧记忆的值，于是"报不报"
      // 只由计数决定：计数真被清过 → 停在 1，不报；没清 → 凑满 2 探、误报。
      openNoVideoGates();
      pc
        ..position.value = 200
        ..debugCheckNoVideoTrack();
      await Future<void>.delayed(Duration.zero);

      expect(
        log.has('无视频轨:'),
        isFalse,
        reason: '闸门重置后上一探的账不该接着算（这里会凑满快路 2 探而误报）：\n${log.text}',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // `_pickFastestCdn` 那条「基线无有效样本 → 直接切换」出口新增的**佐证**
  // （2026-10-13，闸门 = `_playerInTrouble`）。log 18 的现场：预检在缓冲补满
  // （32s）时开测，基线探到一次 `connection timeout`，而播放器正拿**同一条 URL**
  // 播得好好的（位置一路从 0 走到 6.6s）—— 换完 24 秒，同一个 host 又测出
  // 3.50MB/s，比换过去的更快。一次并行新连接没建起来跟"这条镜像供不上字节"是
  // 两回事，不该为此白付一次 ~8 秒的重载。所以放行要佐证：播放器自己也在挨饿/
  // 冻着（`bufferedAhead` 低于 mpv 回填水位、或正在重新缓冲、或遥测失真）。
  // 下面两条就是这枚闸的正反两面：健康态掐住、真挨饿放行。
  // ---------------------------------------------------------------------------

  test('基线没探到样本、但播放器没在挨饿时不许直接换源（新闸门，log 18 复放）', () async {
    // 健康态，四样缺一不可：
    //   - position 0 / buffered 32：`bufferedAhead` = 32 - 0 = 32s（**秒**），压过
    //     回填水位 21.333s；
    //   - isBuffering **显式设 false**：它是 `RxBool(..true.obs)`，初值就是 true，
    //     漏了这一句新闸门会因"正在重新缓冲"提前为真 —— 用例假绿；
    //   - `demuxer-hysteresis-secs` 21.333：抬出一个非零水位，让余量判据真的可判；
    //   - `cache-secs` 30：把失真线钉在 90s，免得继承来的 0 让 telemetryDiverged 翻转。
    PlPlayerController.getInstance()
      ..playerStatus = PlayerStatus.playing
      ..position.value = 0
      ..buffered.value = 32
      ..isBuffering.value = false
      ..buffer['demuxer-hysteresis-secs'] = '21.333'
      ..buffer['cache-secs'] = '30';
    // 基线留在 [_baselineUrl]：假适配器对 [_baselineHost] 只回 8KiB 小样本 → 基线
    // 必然"拿不出有效速度"，正落在新闸门那条出口上。
    hostA.attachCdnSwitch();
    _stall(hostA);

    // 正面证据 + 收尾：出现新行说明那一轮真的走到了这道闸；`放弃，` 说明整轮跑完
    // 了，下面两句"没有"才不是"还没跑到"的假绿。
    await _waitFor(() => log.has('基线探测没拿到样本，但播放器没在挨饿'));
    await _waitFor(() => log.has('放弃，'));

    expect(
      log.has('基线无有效速度，直接切换'),
      isFalse,
      reason: '这一次探测失败只是并行新连接没建起来，不该付一次重载：\n${log.text}',
    );
    expect(
      log.has('第1次 ->'),
      isFalse,
      reason: '健康态下"没"到换源这一步，连候选都不该被选中：\n${log.text}',
    );
  });

  test('真挨饿时"基线没样本 → 直接换源"照旧（上一条的否定不是空的，log 8 复放）', () async {
    // 与上一条只差**播放器在不在挨饿**这一件事：余量归零 + 正在重新缓冲。log 8
    // 那次「钉 cosov → 基线断流 → ~6 秒救走」就是这个形状（余量 0s + 重新缓冲
    // true），这条出口必须原样放行 —— 否则新闸门把真救援也一起掐了。
    PlPlayerController.getInstance()
      ..playerStatus = PlayerStatus.playing
      ..position.value = 0
      ..buffered.value = 0
      ..isBuffering.value = true
      ..buffer['demuxer-hysteresis-secs'] = '21.333'
      ..buffer['cache-secs'] = '30';
    hostA.attachCdnSwitch();
    _stall(hostA);

    await _waitFor(() => log.has('第1次 ->'));
    expect(
      log.has('基线无有效速度，直接切换'),
      isTrue,
      reason: '挨饿态下没走那条出口，用例前提不成立：\n${log.text}',
    );
    expect(
      log.has('基线探测没拿到样本，但播放器没在挨饿'),
      isFalse,
      reason: '挨饿态下被新闸门拦下了 —— 真救援被掐：\n${log.text}',
    );
  });
}

/// 判据 3 的连续采样拍数（`controller.dart:_kStarveSeconds`）。只用在失败原因里，
/// 别跟着生产常量一起改。
const _kStarveSecondsExpect = 4;

/// 「无视频轨」连空几探才动手（`controller.dart:_kNoVideoProbes` / 强指纹快路
/// `controller.dart:_kNoVideoProbesFast`）与重建上限（`controller.dart:_kNoVideoRebuildMax`）。
/// 同上：只用在断言里。
const _kNoVideoProbesExpect = 4;
const _kNoVideoProbesFastExpect = 2;
const _kNoVideoRebuildMaxExpect = 2;

/// 把触发打进播放器上报口 —— 这就是真实的机制（页面不直接调 mixin 的私有方法）。
///
/// [at] 就是"卡在哪一秒"。它不只决定日志里那个数字，还经 `_switchTo` 一路变成
/// 续播落点：非零 → 走"补落点"那几拍；`Duration.zero` → `_restoreResumePosition`
/// 直接返回，这一轮立刻进到等恢复。
void _stall(_CdnHost host, [Duration at = const Duration(seconds: 100)]) =>
    PlPlayerController.getInstance().onStall!(at);

/// 把失真上报打进播放器的新出口（`PlPlayerController.onTelemetryDiverged`）。
/// 和 [_stall] 一样：页面不直接调 mixin 的私有方法，走真实的机制。
void _diverge([Duration at = const Duration(seconds: 100)]) =>
    PlPlayerController.getInstance().onTelemetryDiverged!(at);

/// 采样时刻。取在**未来**：`_armRebufferSuppress` 那 8s 静默期是跟挂钟比的，
/// 沿用上一个用例留下的窗口会让采样静悄悄地全部落空。
DateTime _sampleAt(int seconds) =>
    DateTime.now().add(Duration(minutes: 5, seconds: seconds));

Future<void> _waitFor(
  bool Function() ready, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待超时：条件一直没成立');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// 基线（= 正在播的那条 URL）用的 host。
///
/// URL 形状不是随便写的：`VideoUtils.getCdnUrl` 只对匹配 `_mirrorRegex`
/// （`video_utils.dart:15-17`）的 URL 做 host 替换，路径**必须**以 `/upgcxcode`
/// 开头、host 必须长成 `upos-<区>-<镜像>.(bilivideo.com|akamaized.net)`。不匹配
/// 就落到 `last` 分支，所有候选都变成同一个 URL，一轮测速成了自比。
const _baselineHost = 'upos-sz-mirrorcos.bilivideo.com';
const _baselineUrl = 'https://$_baselineHost/upgcxcode/1/2/3/4.m4s';

/// 基线换一条镜像之后的版本：host 挪出 [_baselineHost]，[_FakeAdapter] 于是不再
/// 把基线当"慢 host"，给它的字节跟候选同一档。
///
/// 为什么需要它：按 host 发字节这件事把一轮的裁定分成了两条互斥的路 ——
/// 基线拿不出有效样本时永远是"直接切换"（`:1620`），一条**不切换**的裁定
/// （`healthy` / `noBetter`）只有基线**拿得出**速度时才出得来，而
/// `_autoSwitchLoop` 收尾那道兜底重载（`cdn_switch_mixin.dart:1183`）恰恰只接
/// 不切换的裁定。
///
/// host 形状还是照旧匹配 `_mirrorRegex`：`getCdnUrl` 只认这个形状，换成别的形状
/// 候选会全变成同一个 URL，一轮测速就成了自比。这里改的只是"谁坐在基线位置上"。
const _steadyBaselineUrl =
    'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/1/2/3/4.m4s';

/// 假播放器宿主：只实现 mixin 的宿主契约（`cdn_switch_mixin.dart:153-189`），
/// 外加两个测试钩子。
class _CdnHost extends GetxController with CdnSwitchMixin {
  _CdnHost({required this.cdn, required String url}) : videoUrl = url {
    // 唯一的生产缝：把整轮测速的流量交给假适配器（见文件头）。
    cdnAutoDioForTest = cdn.dio;
  }

  final _FakeCdn cdn;

  @override
  String? videoUrl;
  @override
  String? audioUrl;
  @override
  Duration? playedTime;
  @override
  Duration? defaultST;
  @override
  bool autoPlay = false;

  /// 视频轨的 baseUrl。置空 = "host 改写拿不出 URL"（`firstVideo.playUrls` 变空），
  /// 用来验证 `_switchTo` 里 `newVideo.isEmpty` 那条冷却（见 N10 用例）。
  ///
  /// 它和 [videoUrl]（mixin 的基线）是两件事：`_pickFastestCdn` 探候选读的是
  /// 这里的 `playUrls`，而基线一直是 [videoUrl]。所以抹掉它不会让那一轮选不出
  /// 候选，只会让 `_switchTo` 在最后一刻读到一个空列表。
  String? videoItemUrl = _baselineUrl;

  /// 非空时 [playerInit] 会卡在这里 —— 复现"重载播放器那几秒"的关键。
  Completer<void>? holdInit;
  int initCalls = 0;
  final List<bool?> initAutoplay = [];

  @override
  PlayUrlModel get data => PlayUrlModel(
    dash: Dash(
      duration: 3600,
      video: [
        VideoItem(
          id: 80,
          quality: VideoQuality.high1080,
          baseUrl: videoItemUrl,
        ),
      ],
    ),
  );

  @override
  VideoItem get firstVideo => data.dash!.video!.first;

  /// 音频留空：换源时的音频那一段就整段跳过，用例只盯视频这条线。
  @override
  AudioQuality? get currentAudioQa => null;

  @override
  bool get isFileSource => false;

  @override
  bool get isQuerying => false;

  @override
  PlPlayerController get plPlayerController => PlPlayerController.getInstance();

  @override
  Future<void> playerInit({
    bool? autoplay,
    bool autoFullScreenFlag = false,
    // 只是为了让 @override 对得上：这条路的 P3 重建测试里触发不到（拆 Player 要
    // libmpv），续播点的推导改由纯函数 test/utils/resume_seek_test.dart 覆盖。
    Duration? resumeAt,
  }) async {
    initCalls++;
    initAutoplay.add(autoplay);
    final hold = holdInit;
    if (hold != null) await hold.future;
  }
}

/// 假 CDN：手写 `HttpClientAdapter`，按 Range 回罐头字节。
///
/// 基线与候选的差别只有一个字节数：
/// - 基线给 8KiB（低于 [CdnSpeedTest.autoMinBytes]）→ 样本"不可用"，于是
///   `_pickFastestCdn` 走"基线拿不出有效速度，直接切换"那条路（`:1611`）。
///   刻意不用速度比来造 `better`：那要靠真实墙钟去堆分块延迟，既慢又不稳。
/// - 候选给满 [CdnSpeedTest.autoBytes] → 样本可用。
class _FakeCdn {
  _FakeCdn(this.objectSize);

  final int objectSize;
  late final Dio dio = CdnSpeedTest.createDio()
    ..httpClientAdapter = _FakeAdapter(this);

  /// 按到达顺序记下每一发请求。分得清"探对象总长"和"采样"两类。
  final List<({Uri uri, String? range})> requests = [];

  /// 非空时"探对象总长"那一发会卡住（用例 4 用）。
  Completer<void>? holdProbe;

  /// 为真时**所有** host 都只回小样本 —— 造"基线、候选都拿不出有效速度"的
  /// unmeasurable 轮（F8 / F6 用）。默认假：只有基线那个 host 是慢的。
  bool allTiny = false;

  List<({Uri uri, String? range})> get probes =>
      requests.where((r) => r.range == _probeRange).toList();

  List<({Uri uri, String? range})> get samples =>
      requests.where((r) => r.range != _probeRange).toList();
}

const _probeRange = 'bytes=0-0';
const _autoBytes = 2 * 1024 * 1024;
const _tinyBytes = 8 * 1024;

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.cdn);

  final _FakeCdn cdn;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final range = options.headers['range'] as String?;
    cdn.requests.add((uri: options.uri, range: range));

    // 探对象总长：只回头部就够了（调用方读完就 cancel）。`parseContentRangeSize`
    // 只取最后一个 `/` 之后的整数。
    if (range == _probeRange) {
      final hold = cdn.holdProbe;
      if (hold != null) await hold.future;
      return ResponseBody.fromString(
        '',
        206,
        headers: {
          'content-range': ['bytes 0-0/${cdn.objectSize}'],
        },
      );
    }

    final offset = _rangeStart(range);
    final fast = !cdn.allTiny && options.uri.host != _baselineHost;
    final bytes = fast ? _autoBytes : _tinyBytes;
    return ResponseBody.fromBytes(
      List<int>.filled(bytes, 0),
      offset > 0 ? 206 : 200,
      headers: {
        if (offset > 0)
          'content-range': ['bytes $offset-${offset + bytes - 1}/${cdn.objectSize}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}

  int _rangeStart(String? range) {
    if (range == null) return 0;
    final match = RegExp(r'bytes=(\d+)-').firstMatch(range);
    return match == null ? 0 : int.parse(match.group(1)!);
  }
}

/// 抓住 `debugPrint` 的输出。
///
/// 断言只能落在日志行上（见文件头），所以这里得**原样**收下来：
/// `debugPrintThrottled` 会在突发时丢行，而恰恰是那些行在说明问题。
class _LogCapture {
  final List<String> lines = [];
  DebugPrintCallback? _original;

  void install() {
    _original = debugPrint;
    debugPrint = _collect;
  }

  void restore() {
    final original = _original;
    if (original != null) debugPrint = original;
  }

  void _collect(String? message, {int? wrapWidth}) {
    if (message != null) lines.add(message);
  }

  bool has(String needle) => lines.any((line) => line.contains(needle));

  String get text => lines.join('\n');
}

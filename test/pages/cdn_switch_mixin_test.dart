import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/models/common/video/audio_quality.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/pages/video/cdn_switch_mixin.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
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
/// （`lib/plugin/pl_player/controller.dart:892`），另一个库里 `extends` 不过去，
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
/// 注意：仓库的 .gitignore 里 `test*` 是整片忽略的，这个文件默认**不会**被 git
/// 看到。要纳入版本管理得 `git add -f test/pages/cdn_switch_mixin_test.dart`。
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
    // `GStorage.video`（`controller.dart:185/836`），所以 video 盒也要开。
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
    PlPlayerController.getInstance().onStall = null;
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
}

/// 把触发打进播放器上报口 —— 这就是真实的机制（页面不直接调 mixin 的私有方法）。
///
/// [at] 就是"卡在哪一秒"。它不只决定日志里那个数字，还经 `_switchTo` 一路变成
/// 续播落点：非零 → 走"补落点"那几拍；`Duration.zero` → `_restoreResumePosition`
/// 直接返回，这一轮立刻进到等恢复。
void _stall(_CdnHost host, [Duration at = const Duration(seconds: 100)]) =>
    PlPlayerController.getInstance().onStall!(at);

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

/// 假播放器宿主：只实现 mixin 的宿主契约（`cdn_switch_mixin.dart:118-155`），
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
          baseUrl: _baselineUrl,
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
///   `_pickFastestCdn` 走"基线拿不出有效速度，直接切换"那条路（`:1358`）。
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
    final fast = options.uri.host != _baselineHost;
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

import 'dart:async';

import 'package:PiliPlus/models/common/video/audio_quality.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/cdn_speed_test.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:collection/collection.dart';
import 'package:dio/dio.dart' show CancelToken, Dio, DioException;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

/// 一轮 CDN 测速的结论。
enum _CdnRoundVerdict {
  /// 有候选比当前镜像快一大截，值得切换。
  better,

  /// 测出了有效基线，但没有候选够快 —— 镜像不是瓶颈。
  healthy,

  /// 没有候选比基线快，而基线本身就慢于 [_kCdnHealthyMBps]。这种情况说
  /// "CDN 都正常"是假话：不是镜像没瓶颈，是没得换。要报出当前有多慢。
  noBetter,

  /// 样本全部作废（未遵守 Range、416、读不到字节），没有可比较的东西。
  unmeasurable,
}

/// [CdnSwitchMixin._pickFastestCdn] 的一轮结果。[service] 只在
/// [verdict] 为 [_CdnRoundVerdict.better] 时非空。
typedef _CdnRound = ({
  _CdnRoundVerdict verdict,
  CDNService? service,
  int bytes,
  int micros,
});

/// 触发一轮测速的原因。只影响日志和 toast 里的说法，以及用哪一档预算 ——
/// 决策链本身（[_kCdnStarveRatio] 那一关）对所有触发一视同仁。
enum _CdnTrigger {
  /// 播放器判据 1/2：位置长时间不推进。
  stall,

  /// 判据 3：前向余量长期趴在低位，画面还在走。
  starve,

  /// 后台定期测速，缓冲掉到 mpv 回填水位以下。
  probe,

  /// 新视频装载后的那一次预检，唯一不看缓冲水位的触发。
  preflight,

  /// 余量刚归零的小卡顿，用快速档预算。
  rebuffer;

  /// 日志/toast 里的简称。
  String get label => switch (this) {
    _CdnTrigger.stall => '卡顿',
    _CdnTrigger.starve => '缓冲饥饿',
    _CdnTrigger.probe => '定期测速',
    _CdnTrigger.preflight => '预检',
    _CdnTrigger.rebuffer => '小卡顿',
  };
}

// ---------------------------------------------------------------------------
// 卡顿自动切换 CDN
//
// 触发是纯反应式的：只有播放器上报卡顿（位置不推进，或前向缓冲长期趴在低位）
// 才测速。卡住的播放器已经不再下载，此时测速不会与播放争带宽，结果才可信；
// 健康播放时测速反而会制造我们要修的卡顿。
//
// 测速一律在"播放头即将需要的那段字节"上做，并且总是先测当前镜像作基线：
// 坏镜像的头部区间和好镜像一样快（实测 upos-sz-mirrorcosov 前 100MB 跑满
// 23MB/s，之后掉到 30KB/s），只在头部取样等于永远发现不了故障，只测候选而
// 不测基线则没有比较对象。
//
// session-only：绝不写 [VideoUtils.cdnService]，只把目标镜像作为
// `defaultCDNService` 显式传给 getCdnUrl，否则会静默改掉用户的手动设置。
// ---------------------------------------------------------------------------

/// 以 mixin 的形式挂在页面控制器上，而不是独立类：本功能要用到页面的一大堆
/// 状态（当前地址、画质、播放器、data…），独立类得为它们造一整套接口；而
/// 页面控制器本来就已经 `with BlockMixin`（lib/pages/sponsor_block/block_mixin.dart），
/// 同一套写法，宿主契约一样用抽象成员声明。
mixin CdnSwitchMixin on GetxController {
  // ---------------------------------------------------------------------------
  // 宿主契约：本 mixin 只读/写这些成员，具体由页面控制器提供。类型必须与页面
  // 上的真实声明一致 —— 对不上 analyzer 会直接报错。
  // ---------------------------------------------------------------------------

  /// 当前正在播的视频地址，也是每轮测速的基线。
  String? get videoUrl;
  set videoUrl(String? value);

  /// 换源时一并换掉的音频地址。
  set audioUrl(String? value);

  /// 换源后的续播点；[playerInit] 会读它。
  set playedTime(Duration? value);

  /// 每次装载前清空，让 [playerInit] 走 [playedTime] 分支。
  set defaultST(Duration? value);

  /// 页面控制器的公开入口（`controller.dart:583-584`），内部是 `_autoPlay`。
  set autoPlay(bool value);

  /// playurl 响应，[dash] 里是音视频轨。
  PlayUrlModel get data;

  /// 当前画质的视频轨；`playUrls` 是各镜像候选。
  VideoItem get firstVideo;

  /// 当前音质；换源时用它挑对应的音频轨。
  AudioQuality? get currentAudioQa;

  /// 本地文件、直播都不在自动切换的范围内。
  bool get isFileSource;

  /// 正在请求新的 playurl —— 此时的地址列表属于上一轮，别用。
  bool get isQuerying;

  PlPlayerController get plPlayerController;

  Future<void> playerInit({bool? autoplay, bool autoFullScreenFlag = false});

  // ---------------------------------------------------------------------------
  // 参数：改这些数字就是在改自动切换的性格。触发语义见上面的契约。
  // ---------------------------------------------------------------------------

  /// 单次卡顿最多尝试几个镜像。
  static const int _kCdnMaxAttempts = 3;

  /// 候选必须比当前镜像快这么多倍才值得切换。切换是一次真实的重新加载
  /// （playerInit + seek 回原位），画面会闪一下，所以宁可少切。
  static const double _kCdnStarveRatio = 1.5;

  /// 测到高于这个速率就认为镜像本身不是瓶颈：1MB/s ≈ 8Mbps，远高于 1080P 码率。
  static const double _kCdnHealthyMBps = 1.0;

  /// 距上次尝试必须又真实播放了这么久，才允许新的尝试，避免死链无限重试。
  static const Duration _kCdnMinReProgress = Duration(seconds: 3);

  /// 放弃后冷却多久才允许再次自动切换。
  static const Duration _kCdnGiveUpCooldown = Duration(seconds: 60);

  /// 小卡顿探测的节流。它比 [_kCdnProbeInterval] 敏感得多，所以靠这个间隔
  /// 而不是靠判据来限流：两次探测之间至少隔这么久，免得一次持续抖动被拆成
  /// 十几轮测速，反而把带宽全抢走。
  static const Duration _kCdnRebufferCooldown = Duration(seconds: 30);

  /// 目标偏移的下界占对象总长的比例。头部是"面子区间"，坏镜像在这里也是满速，
  /// 必须在它之后取样。
  static const double _kCdnOffsetFloor = 0.15;

  /// 目标偏移的上界要给尾部留出这么多字节。样本本身最多读
  /// [CdnSpeedTest.autoBytes]，留 2 倍余量是为了别撞上对象末尾——EOF 会被
  /// 误读成"这个镜像慢"。
  static const int _kCdnReadWindowBytes = 4 * 1024 * 1024;

  /// 同一个镜像隔多久允许重测。
  static const Duration _kCdnRetryAfter = Duration(minutes: 3);

  /// 上一轮连一个字节都没测到的镜像，隔多久才允许再进候选窗口。
  ///
  /// 和"测到了但慢"分开对待：慢是随时会变的（同一个偏移隔几分钟能差 4 倍），
  /// 所以 3 分钟重测是对的；一个字都没到多半是硬性的。实测 akamai
  /// (upos-hz-mirrorakam) 每轮都是 403、akamai_sz 每轮都是连接失败，而
  /// hw/ali/cos/tf_* 用同样的 host 改写都能正常出样本 —— 那是 Akamai 边缘不
  /// 接受在原始签名下换 host，不是网络抖。窗口只有 2 个候选位，让它每 3 分钟
  /// 占掉一位，等于整轮只剩一个候选可挑，而这正是之前修过的"候选组成"缺陷。
  static const Duration _kCdnDeadRetryAfter = Duration(minutes: 30);

  /// 切换后等待恢复的最长时间。
  static const Duration _kCdnRecoverWindow = Duration(seconds: 12);

  /// 切换后位置推进这么多即认为已恢复。
  static const Duration _kCdnRecoverProgress = Duration(seconds: 2);

  /// 换源重载后，落点离目标多远之内算"还在原处"，不必补 seek。
  static const Duration _kCdnResumeTolerance = Duration(seconds: 5);

  /// 落点检查的轮询间隔与最多补几次 seek。
  ///
  /// 8 × 800ms ≈ 6.4s 不是随手取的：重载后 duration 要过几秒才知道，而
  /// `seekTo` 在 duration 为 0 时只是挂到 `duration.listen` 上等（多次调用会互相
  /// 顶掉），所以前几次补 seek 期间位置会一直读到 0（实测连续 4 次都是 0ms）。
  /// 预算给到 6.4s，才覆盖得住"duration 到位 → 真正 seek → 落点正确"这条链。
  static const Duration _kCdnResumePoll = Duration(milliseconds: 800);
  static const int _kCdnResumeAttempts = 8;

  /// 后台测速的间隔。一轮真实开销是 1 基线 + 2 候选 × 2MB，但只有缓冲掉到
  /// mpv 回填水位以下时才会真的花这笔流量（见 [_onCdnProbeTick]），所以健康
  /// 播放的代价是 0。
  static const Duration _kCdnProbeInterval = Duration(minutes: 2);

  /// 预检的检查间隔：等缓冲补满就动手，不干等。
  static const Duration _kCdnPreflightPoll = Duration(seconds: 2);

  /// 预检最晚什么时候做。缓冲一直补不满（镜像本就是坏的）也要测。
  static const Duration _kCdnPreflightDeadline = Duration(seconds: 10);

  // ---------------------------------------------------------------------------
  // 一集之内的状态：换集、换 P、换画质都走 resetCdnAutoSwitch() 清掉。
  // ---------------------------------------------------------------------------

  bool _cdnAutoBusy = false;
  int _cdnAutoAttempts = 0;
  int _cdnGeneration = 0;

  /// 测过的镜像以及测的时间。原来是永久的 Set：一个镜像测过一次，整集就
  /// 再不考虑。长时间播放里那是致命的 —— 轮换窗口一路滑下去，实测第 4 轮
  /// 只剩 aliov/hwov 两个海外节点，而真正快的国内节点早在网络还正常的时候
  /// 就被"测过"并永久拉黑，此后每次卡顿都只能在这两个最差的里面挑。CDN 的
  /// 快慢是随时间变的（同一个偏移隔几分钟实测能差 4 倍），所以改成冷却重测。
  final Map<CDNService, DateTime> _cdnTriedAt = {};

  /// 上一轮一个字节都没到的候选。见 [_kCdnDeadRetryAfter]。
  final Set<CDNService> _cdnNoSample = {};

  /// 这一集的对象总长。所有镜像服务字节一致的同一个对象，探一次就够；
  /// 缓存它主要是为了小卡顿档 —— 3 秒预算里不该再花几秒去探大小。
  int? _cdnObjectSize;

  Duration _cdnLastAttemptPos = Duration.zero;
  CDNService? _cdnAutoServiceSnapshot;
  Dio? _cdnAutoDio;

  // ---------------------------------------------------------------------------
  // 时钟与闸门。三个时间闸互相独立，谁也别合并谁：
  //   _cdnGiveUpUntil  整集放弃——一轮试完仍不行，60s 内不再响应任何触发
  //   _cdnQuickProbeAt 只压"小卡顿"这一条触发（30s），其余触发照常
  //   _cdnProbeTimer   后台探测的 tick，顺带承担起播预检
  // ---------------------------------------------------------------------------

  Timer? _cdnProbeTimer;

  /// 装载后那一次"预检"还没做。和周期性的常规测速区分开：预检无视缓冲水位，
  /// 常规测速只在缓冲吃紧时才跑。见 [_onCdnProbeTick]。
  bool _cdnPreflightPending = false;

  /// 本次预检从什么时候开始等（起播那一刻算起，不是页面创建时刻）。
  DateTime? _cdnPreflightSince;

  DateTime? _cdnQuickProbeAt;
  DateTime? _cdnGiveUpUntil;

  /// 冷却窗口还没过（时长取决于上一轮的样本是"慢"还是"一个字都没有"）。
  bool _cdnRecentlyTried(CDNService service, DateTime now) {
    final at = _cdnTriedAt[service];
    if (at == null) return false;
    final window = _cdnNoSample.contains(service)
        ? _kCdnDeadRetryAfter
        : _kCdnRetryAfter;
    return now.difference(at) < window;
  }


  bool get _cdnAutoEligible {
    // 直播、本地文件、durl(edl://) 都不在范围内。
    if (isFileSource || plPlayerController.isLive) return false;
    if (data.dash == null) return false;
    if (!Pref.autoSwitchCdnOnStall) return false;
    // 基线就是正在播的这条 URL，拿不到就没得比较（也说明还没开始播）。
    if (videoUrl?.isNotEmpty != true) return false;
    // 听视频 + 音频不跟随 CDN 时，所有候选返回同一个原始 URL，测速没有意义。
    if (plPlayerController.onlyPlayAudio.value && VideoUtils.disableAudioCDN) {
      return false;
    }
    return true;
  }

  /// 换集、换 P、重置等用户动作都要让在途的自动切换失效。
  void resetCdnAutoSwitch() {
    _cdnGeneration++;
    _cdnAutoBusy = false;
    _cdnAutoAttempts = 0;
    _cdnTriedAt.clear();
    _cdnNoSample.clear();
    // 换集/换画质后对象变了，缓存的总长不再适用。
    _cdnObjectSize = null;
    _cdnGiveUpUntil = null;
    _cdnLastAttemptPos = Duration.zero;
    _cdnAutoServiceSnapshot = null;
  }

  /// 下面这些诊断刻意不套 kDebugMode：release 包只走手机测试，套了就看不到。
  static String _fmtSpeed(int bytes, int micros) =>
      '${(bytes / micros).toStringAsPrecision(3)}MB/s';

  /// 换画质等于换了 dataSource，在途的测速结果对应的是旧列表，作废。
  ///
  /// 只有真有一轮在跑时才作废：把 reset 无条件地放在换画质的路径上，会顺手
  /// 清掉放弃冷却和镜像冷却，等于每次调画质都重新开闸。
  void resetCdnSwitchIfBusy() {
    if (_cdnAutoBusy) resetCdnAutoSwitch();
  }

  /// 小卡顿（余量刚归零）触发的后台探测。
  ///
  /// 与前三条的差别在**节流**，不在判据：这里每次都会真的花流量
  /// （3 × [CdnSpeedTest.quickBytes]，挂钟上限定死 3 秒），而代价是跟正在挨饿
  /// 的播放器抢同一根管子，所以单独压一个 [_kCdnRebufferCooldown]。只测速，
  /// 换不换仍由 [_kCdnStarveRatio] 决定 —— 一次抖动的样本不该换来一次重载。
  void _onPlayerRebuffer(Duration position) {
    final at = _cdnQuickProbeAt;
    final now = DateTime.now();
    if (at != null && now.difference(at) < _kCdnRebufferCooldown) {
      debugPrint(
        'CDN 自动切换: 小卡顿冷却中（距上次 ${now.difference(at).inSeconds}s）'
        '，只记不测 @${position.inSeconds}s',
      );
      return;
    }
    _cdnQuickProbeAt = now;
    _onPlayerStall(position, trigger: _CdnTrigger.rebuffer);
  }

  void _onPlayerStall(
    Duration position, {
    _CdnTrigger trigger = _CdnTrigger.stall,
  }) {
    final what = trigger.label;
    if (_cdnAutoBusy || isClosed || !_cdnAutoEligible) {
      debugPrint(
        'CDN 自动切换: 忽略$what @${position.inSeconds}s '
        '(busy=$_cdnAutoBusy closed=$isClosed eligible=$_cdnAutoEligible)',
      );
      return;
    }

    final cooldownUntil = _cdnGiveUpUntil;
    if (cooldownUntil != null && DateTime.now().isBefore(cooldownUntil)) {
      debugPrint('CDN 自动切换: 冷却中，忽略$what @${position.inSeconds}s');
      return;
    }

    // 距上次尝试没有实质进展 → 这个视频是真的放不动，不要再花钱测速。
    // 缓冲饥饿的位置一直在被音频时钟推着走，通常能正常通过这一关。
    if (_cdnLastAttemptPos != Duration.zero &&
        position - _cdnLastAttemptPos < _kCdnMinReProgress) {
      debugPrint(
        'CDN 自动切换: 距上次尝试只推进了 '
        '${(position - _cdnLastAttemptPos).inSeconds}s，忽略',
      );
      return;
    }

    debugPrint('CDN 自动切换: ${_describeTrigger(trigger, position)}');
    _cdnAutoBusy = true;
    _cdnAutoServiceSnapshot = VideoUtils.cdnService;
    final generation = _cdnGeneration;
    _autoSwitchLoop(
      generation,
      position,
      what: what,
      quick: trigger == _CdnTrigger.rebuffer,
    ).whenComplete(() {
      if (!isClosed) _cdnAutoBusy = false;
    });
  }

  /// 触发时的日志正文（`CDN 自动切换: ` 之后那一段）。
  String _describeTrigger(_CdnTrigger trigger, Duration position) =>
      switch (trigger) {
        _CdnTrigger.preflight =>
          '预检 @${position.inSeconds}s（新视频，在 size×15% 处测一轮，不看缓冲）',
        _CdnTrigger.probe =>
          '定期测速 @${position.inSeconds}s，前方余量 '
              '${plPlayerController.bufferedAhead}s 低于 mpv 回填水位，开始找可用镜像',
        _CdnTrigger.rebuffer =>
          '小卡顿 @${position.inSeconds}s，余量刚归零，后台快速测一轮'
              '（快速档 ${CdnSpeedTest.quickBytes ~/ 1024}kB × 3，不看缓冲水位）',
        _CdnTrigger.starve =>
          '缓冲饥饿 @${position.inSeconds}s，开始找可用镜像 '
              '(bufferSec=${Pref.bufferSec})',
        _CdnTrigger.stall => '卡顿 @${position.inSeconds}s，开始找可用镜像',
      };

  /// 启动后台测速：每 [_kCdnPreflightPoll] 检查一次，做完那一次预检之后就
  /// 改按 [_kCdnProbeInterval] 走。换 P / 换集（[onReset]）会重新计时。
  void restartCdnProbe() {
    _cdnPreflightPending = true;
    _cdnPreflightSince = null;
    _cdnProbeTimer?.cancel();
    _cdnProbeTimer = Timer.periodic(
      _kCdnPreflightPoll,
      (_) => _onCdnProbeTick(),
    );
  }

  /// 把本页挂到播放器的三个上报口上（见 [detachCdnSwitch]）。
  void attachCdnSwitch() {
    plPlayerController
      ..onStall = _onPlayerStall
      ..onBufferStarve = _onPlayerBufferStarve
      ..onRebuffer = _onPlayerRebuffer;
    restartCdnProbe();
  }

  /// 页面销毁：只撤掉自己的回调，别把新页面的覆盖掉。
  void detachCdnSwitch() {
    if (plPlayerController.onStall == _onPlayerStall) {
      plPlayerController.onStall = null;
    }
    if (plPlayerController.onBufferStarve == _onPlayerBufferStarve) {
      plPlayerController.onBufferStarve = null;
    }
    if (plPlayerController.onRebuffer == _onPlayerRebuffer) {
      plPlayerController.onRebuffer = null;
    }
    _cdnProbeTimer?.cancel();
    _cdnProbeTimer = null;
    resetCdnAutoSwitch();
  }

  /// mpv 自己的回填水位；取不到（或过小）返回 null，表示不启用。
  double? get _cdnBufferFloor {
    final floor = double.tryParse(
      plPlayerController.buffer['demuxer-hysteresis-secs'] ?? '',
    );
    return (floor == null || floor <= 0) ? null : floor;
  }

  /// 定时器只决定"多久考虑一次"；要不要真的花流量，由缓冲决定。
  ///
  /// 常规测速的策略是**只在缓冲吃紧时才换**：余量还在 mpv 的回填水位
  /// （`demuxer-hysteresis-secs`，健康时锯齿就在这个值到 `cache-secs` 之间摆动）
  /// 以上，说明当前镜像喂得动，一分钱不花。掉到水位以下 —— mpv 该回填却没回填
  /// —— 才跑一轮，把卡顿提前到还没被看见的时候解决，而不是等它饿到 0s。
  ///
  /// 预检是唯一例外：每个视频开播后无条件测一轮，因为"缓冲已补满"在这里什么也
  /// 证明不了。头部每个镜像都快（实测 5.4~5.7MB/s），缓冲正是从头部补满的；而
  /// 预检的取样点在 size×15% 处，那才是"头快尾死"型镜像露馅的地方 —— 等缓冲饿
  /// 下去再发现，用户已经看了十几分钟。
  ///
  /// 预检**越早越值钱**：位置还在起点附近时换源，画面几乎看不出闪；等到 30s 才
  /// 换就是一次实打实的重载。所以这里不是死等一个固定延迟，而是每 2s 看一次，
  /// 缓冲一补满（正常镜像 3~5s）就测；一直补不满说明镜像本来就是坏的，
  /// [_kCdnPreflightDeadline] 一到也照样测 —— 那正是要抓的情形。
  void _onCdnProbeTick() {
    if (isClosed || _cdnAutoBusy || !_cdnAutoEligible) return;
    // 还没开播就把预检留着，下一个 tick 再试 —— 页面创建到真正起播之间可能
    // 隔很久（分段加载、用户没点播放），一次错过就永远不做预检了。
    if (!plPlayerController.playerStatus.isPlaying) return;

    final preflight = _cdnPreflightPending;
    final floor = _cdnBufferFloor;
    if (preflight) {
      final since = _cdnPreflightSince ??= DateTime.now();
      final filled = floor != null && plPlayerController.bufferedAhead >= floor;
      if (!filled &&
          DateTime.now().difference(since) < _kCdnPreflightDeadline) {
        return; // 再等等：初期突发流量还没过去，这时候测不准
      }
      _cdnPreflightPending = false;
      _cdnPreflightSince = null;
      _cdnProbeTimer?.cancel();
      _cdnProbeTimer = Timer.periodic(
        _kCdnProbeInterval,
        (_) => _onCdnProbeTick(),
      );
    } else {
      if (floor == null) return;
      if (plPlayerController.bufferedAhead >= floor) return;
    }

    _onPlayerStall(
      Duration(seconds: plPlayerController.position.value),
      trigger: preflight ? _CdnTrigger.preflight : _CdnTrigger.probe,
    );
  }

  /// 判据 3 的回调：画面还在走、前向缓冲却在变少。换源型故障只在这里露头，
  /// 播放器只负责上报，怎么处理由本页决定（和 [onStall] 同一个决策链）。
  void _onPlayerBufferStarve(Duration position) =>
      _onPlayerStall(position, trigger: _CdnTrigger.starve);

  Future<void> _autoSwitchLoop(
    int generation,
    Duration stalledAt, {
    required String what,
    bool quick = false,
  }) async {
    var switched = false;
    // 记录本轮测到过的最好候选速率，用来判断"镜像没问题，是别处卡"。
    var bestBytes = 0;
    var bestMicros = 0;
    // 放弃时要说的话。测速给了明确结论就照实说，别让用户以为 CDN 有问题。
    String? giveUp;
    for (var attempt = 0; attempt < _kCdnMaxAttempts; attempt++) {
      if (generation != _cdnGeneration ||
          isClosed ||
          isQuerying ||
          !_cdnAutoEligible) {
        return;
      }
      // 用户中途手动换了 CDN，听他的。
      if (_cdnAutoServiceSnapshot != VideoUtils.cdnService) return;

      final round = await _pickFastestCdn(stalledAt, quick: quick);
      if (generation != _cdnGeneration || isClosed || isQuerying) return;
      if (round == null) break;
      if (round.verdict == _CdnRoundVerdict.unmeasurable) {
        // 这里说「CDN 都正常」是假话：根本没测出可比的数据。
        giveUp = '无法测出更快的 CDN，暂不切换';
        break;
      }
      if (round.verdict == _CdnRoundVerdict.healthy) {
        giveUp = 'CDN 都正常，可能是网络问题';
        break;
      }
      if (round.verdict == _CdnRoundVerdict.noBetter) {
        // 候选都比不过基线，可基线自己也慢：没得换，不是没问题。
        giveUp =
            '当前 CDN 只有 ${_fmtSpeed(round.bytes, round.micros)}，'
            '没找到更快的镜像';
        break;
      }

      final chosen = round.service!;
      final speed = _fmtSpeed(round.bytes, round.micros);
      if (bestMicros == 0 ||
          round.bytes / round.micros > bestBytes / bestMicros) {
        bestBytes = round.bytes;
        bestMicros = round.micros;
      }

      _cdnAutoAttempts = attempt + 1;
      _cdnLastAttemptPos = stalledAt;
      debugPrint('CDN 自动切换: 第$_cdnAutoAttempts次 -> ${chosen.desc} ($speed)');
      SmartDialog.showToast(
        '$what，尝试切换到 ${chosen.desc}\n$speed',
        displayTime: const Duration(seconds: 3),
      );

      switched = true;
      if (!await _switchTo(chosen, generation, resumeAt: stalledAt)) return;
      if (await _awaitRecovery(generation, stalledAt)) {
        _cdnAutoAttempts = 0;
        _cdnLastAttemptPos = Duration.zero;
        _cdnTriedAt.clear();
        _cdnGiveUpUntil = null;
        debugPrint('CDN 自动切换: 成功，已切到 ${chosen.desc}');
        SmartDialog.showToast(
          '已切换到 ${chosen.desc}',
          displayTime: const Duration(seconds: 2),
        );
        return;
      }
      debugPrint('CDN 自动切换: ${chosen.desc} 未恢复，换下一个候选');
    }

    _cdnGiveUpUntil = DateTime.now().add(_kCdnGiveUpCooldown);
    debugPrint(
      'CDN 自动切换: 放弃，${_kCdnGiveUpCooldown.inSeconds}s 内不再尝试'
      '${giveUp == null ? '' : '（$giveUp）'}',
    );
    final reason =
        giveUp ??
        (switched
            ? (bestMicros > 0 && bestBytes / bestMicros >= _kCdnHealthyMBps
                  ? 'CDN 都正常，可能是网络问题'
                  : '自动切换 CDN 未能改善，已暂停尝试')
            : null);
    if (reason != null) {
      SmartDialog.showToast(reason, displayTime: const Duration(seconds: 3));
    }
  }

  /// 在播放头即将需要的字节上做一轮测速：当前镜像（基线）+ 最多
  /// [CdnSpeedTest.autoCandidatesMax] 个轮换候选，同一批并发测完。
  ///
  /// 返回 null 表示这一轮无从下手（拿不到地址、没有候选），调用方静默放弃。
  Future<_CdnRound?> _pickFastestCdn(
    Duration position, {
    bool quick = false,
  }) async {
    final urls = firstVideo.playUrls.toList();
    final baselineUrl = videoUrl;
    if (urls.isEmpty || baselineUrl == null || baselineUrl.isEmpty) {
      debugPrint('CDN 自动切换: 拿不到播放地址');
      return null;
    }

    // 当前生效的镜像要从 videoUrl 里解析 host —— 默认偏好是 backupUrl，它的
    // URL 里带的是真实 host，只看 Pref 会漏判。
    final currentHost = Uri.tryParse(baselineUrl)?.host;
    final baseUrl = CdnSpeedTest.urlFor(urls, CDNService.baseUrl);

    // 窗口就取 autoCandidatesMax = autoConcurrency - 1：基线要占掉一个并发位，
    // 剩下的才轮到候选，整轮必须挤进同一批。分两批的话，测基线的那几秒里缓冲
    // 已经又耗掉一截，结论就过时了 —— 饥饿时省下的每一秒都是画面。
    const limit = CdnSpeedTest.autoCandidatesMax;

    // 轮换相位在**完整镜像表**上推进，而不是在当前可用候选上。后者会随
    // `_cdnTriedAt` 收缩，两个模数（表长和候选数）对不上，窗口就会跳着走、
    // 整轮整轮地漏掉镜像 —— 实测 hw 和 cos 就是这样被跳过的。在完整表上按
    // 固定相位走，每个镜像都保证有轮到的时候。
    // 相位持久化：控制器随页面销毁，onReset(换P) 也会清状态，轮换要跨这些事件累积。
    final all = CdnSpeedTest.mirrors;
    final phase = Pref.cdnMirrorRotation % all.length;
    Pref.cdnMirrorRotation = (phase + limit) % all.length;

    final now = DateTime.now();
    final candidates = <CDNService>[];
    // 第二遍忽略冷却：宁可重测刚测过的，也不要出现"一轮没有候选"。
    for (final ignoreCooldown in const [false, true]) {
      for (var i = 0; i < all.length && candidates.length < limit; i++) {
        final service = all[(phase + i) % all.length];
        if (candidates.contains(service)) continue;
        final host = service.host;
        if (host == null || host == currentHost) continue;
        if (!ignoreCooldown && _cdnRecentlyTried(service, now)) continue;
        // host 替换不起作用（mcdn-only / edl:// 合成项），换过去也是同一个 URL。
        final url = CdnSpeedTest.urlFor(urls, service);
        if (url.isEmpty || url == baseUrl) continue;
        candidates.add(service);
      }
    }
    if (candidates.isEmpty) {
      debugPrint('CDN 自动切换: 没有可测的候选镜像');
      return null;
    }

    final dio = _cdnAutoDio ??= CdnSpeedTest.createDio();

    // 对象总长探一次就够：所有镜像服务的是字节一致的同一个对象。同一集内缓存
    // 下来 —— 小卡顿档只有 3 秒预算，每次再花几秒去探大小会把预算整个吃掉。
    // 换画质/换集走 [resetCdnAutoSwitch]，缓存随之作废。
    var size = _cdnObjectSize;
    if (size == null) {
      final sizeToken = CancelToken();
      try {
        size = await CdnSpeedTest.probeSize(
          dio,
          baselineUrl,
          sizeToken,
          connectTimeout: CdnSpeedTest.probeConnect,
          receiveTimeout: CdnSpeedTest.probeReceive,
        );
      } catch (e) {
        debugPrint('CDN 自动切换: 探测对象大小失败: $e');
      } finally {
        if (!sizeToken.isCancelled) sizeToken.cancel();
      }
      if (size != null && size > 0) _cdnObjectSize = size;
    }

    final readOffset = _starveOffset(position, size);
    debugPrint(
      'CDN 自动切换: 目标偏移 $readOffset/${size ?? '未知'} 字节 '
      '(位置 ${position.inMilliseconds}ms/'
      '${plPlayerController.durationInMilliseconds}ms)',
    );
    debugPrint(
      'CDN 自动切换: 测速 1 基线 + ${candidates.length} 候选 @$readOffset '
      '(轮换起点 $phase) ${candidates.map((e) => e.desc).join(', ')}',
    );

    // 无论测速成功与否，这一轮候选都进入冷却；[_kCdnRetryAfter] 之后可以重测。
    for (final service in candidates) {
      _cdnTriedAt[service] = now;
    }

    var offsetRejected = false;
    final tokens = <CancelToken>[];

    Future<CdnSample?> sample(String url) async {
      final token = CancelToken();
      tokens.add(token);
      try {
        return await CdnSpeedTest.measureAt(
          dio,
          url,
          token,
          offset: readOffset,
          maxBytes: quick ? CdnSpeedTest.quickBytes : CdnSpeedTest.autoBytes,
          maxMicros: quick ? CdnSpeedTest.quickMicros : CdnSpeedTest.autoMicros,
          connectTimeout: CdnSpeedTest.probeConnect,
          receiveTimeout: CdnSpeedTest.probeReceive,
          isCancelled: () => isClosed,
        );
      } on DioException catch (e) {
        // 服务端明确说这个偏移不存在：整轮作废，不能拿别的镜像去比。
        if (e.response?.statusCode == 416) offsetRejected = true;
        rethrow;
      }
    }

    /// 兜住任何一路的失败，别让它变成未捕获的异步异常。
    Future<CdnSample?> guarded(String url, String label) async {
      try {
        return await sample(url);
      } catch (e) {
        debugPrint('CDN 测速失败 $label: $e');
        return null;
      }
    }

    // 先把请求全部发出去，再逐个 await，中间不插入任何等待。
    final label = currentHost ?? '当前';
    final baselineFuture = guarded(baselineUrl, '[基线 $label]');
    final candidateFutures = [
      for (final service in candidates)
        (
          service: service,
          future: guarded(CdnSpeedTest.urlFor(urls, service), service.desc),
        ),
    ];

    CdnSample? baseline;
    final samples = <(CDNService, CdnSample)>[];
    try {
      baseline = await baselineFuture;
      for (final entry in candidateFutures) {
        final result = await entry.future;
        if (result != null) samples.add((entry.service, result));
      }
    } finally {
      for (final token in tokens) {
        if (!token.isCancelled) token.cancel();
      }
    }

    // 一个字节都没到的候选进"死镜像"冷却，下一轮不再占候选位；下次出样本了
    // 就立刻恢复。不要拿 samples 里的"样本太小"去判死 —— 那是活着只是慢。
    final gotSample = samples.map((e) => e.$1).toSet();
    for (final service in candidates) {
      if (gotSample.contains(service)) {
        _cdnNoSample.remove(service);
      } else {
        _cdnNoSample.add(service);
      }
    }

    String describe(String name, CdnSample? s) => s == null
        ? '$name 无样本'
        : '$name ${_fmtSpeed(s.bytes, s.micros)} '
              '(${s.bytes ~/ 1024}kB/${(s.micros / 1e6).toStringAsFixed(2)}s '
              'ranged=${s.ranged})';
    debugPrint(
      'CDN 自动切换: ${describe('[基线 $label]', baseline)}'
      '${samples.map((e) => ' | ${describe('[${e.$1.desc}]', e.$2)}').join()}',
    );

    _CdnRound unmeasurable(String why) {
      debugPrint('CDN 自动切换: $why，放弃本轮');
      return (
        verdict: _CdnRoundVerdict.unmeasurable,
        service: null,
        bytes: 0,
        micros: 0,
      );
    }

    if (offsetRejected) return unmeasurable('目标偏移 $readOffset 越界(416)');
    if (readOffset > 0 && baseline != null && !baseline.ranged) {
      // 回 200 = 从头发的整个对象，那是在"面子区间"取样，没法跟偏移样本比。
      return unmeasurable('基线未遵守 Range(200)，样本作废');
    }

    /// 样本能不能拿来比较。offset > 0 时服务器必须真的按 Range 回 206。
    /// 门槛跟着档位走：快速档只有 3 秒预算，用整轮的门槛会把最该采到的样本丢掉。
    final minBytes = quick
        ? CdnSpeedTest.quickMinBytes
        : CdnSpeedTest.autoMinBytes;
    bool usable(CdnSample? s) =>
        s != null && s.bytes >= minBytes && (readOffset == 0 || s.ranged);

    final best = samples
        .where((e) => usable(e.$2))
        .sortedBy((e) => -(e.$2.bytes / e.$2.micros))
        .firstOrNull;
    if (best == null) {
      // 候选全废，但基线本身测出来了 —— 那说明当前镜像没问题，是别处卡
      // （实测里就有一次：基线 akam 3.92MB/s，两个候选一个超时一个握手失败）。
      // 这时候说"测不出更快的 CDN"会把用户引到 CDN 上去，而真正的线索在
      // 播放器日志里（Seek failed / partial file / 解码器报错）。
      final base = baseline;
      if (base != null && usable(base)) {
        final baseBps = base.bytes / base.micros;
        final healthy = baseBps >= _kCdnHealthyMBps;
        // 这一句必须跟 verdict 一致：曾经无论基线多慢都印"正常"，于是同一轮里
        // 日志说"基线 0.304MB/s 正常 —— 卡顿多半不在 CDN"，紧跟着的 toast 却说
        // "当前 CDN 只有 0.304MB/s"。只有真的高于健康线才配说"正常"。
        debugPrint(
          healthy
              ? 'CDN 自动切换: 候选全无有效样本，但基线 [${currentHost ?? '当前'}] '
                    '${_fmtSpeed(base.bytes, base.micros)} 健康 —— 卡顿多半不在 CDN'
              : 'CDN 自动切换: 候选一个都没测到，基线 [${currentHost ?? '当前'}] '
                    '自己也只有 ${_fmtSpeed(base.bytes, base.micros)}（低于 '
                    '${_kCdnHealthyMBps}MB/s 健康线）—— 没得换，不是没毛病',
        );
        return (
          verdict: healthy
              ? _CdnRoundVerdict.healthy
              : _CdnRoundVerdict.noBetter,
          service: null,
          bytes: base.bytes,
          micros: base.micros,
        );
      }
      return unmeasurable(
        baseline == null ? '基线与候选都没有有效样本' : '所有候选都没有有效样本',
      );
    }
    final bestBps = best.$2.bytes / best.$2.micros;

    final base = baseline;
    if (base == null || !usable(base)) {
      // 基线拿不出可用速度，就是我们要修的那个故障本身：有候选就直接换。
      debugPrint(
        'CDN 自动切换: 基线无有效速度，直接切换 -> ${best.$1.desc} '
        '${_fmtSpeed(best.$2.bytes, best.$2.micros)}',
      );
      return (
        verdict: _CdnRoundVerdict.better,
        service: best.$1,
        bytes: best.$2.bytes,
        micros: best.$2.micros,
      );
    }

    final baseBps = base.bytes / base.micros;
    final ratio = bestBps / baseBps;
    final faster = ratio >= _kCdnStarveRatio;
    debugPrint(
      'CDN 自动切换: 判定 最快候选 ${best.$1.desc} '
      '${_fmtSpeed(best.$2.bytes, best.$2.micros)} / 基线 '
      '${_fmtSpeed(base.bytes, base.micros)} = '
      '${ratio.toStringAsPrecision(3)}x (阈值 $_kCdnStarveRatio) -> '
      '${faster ? '切换' : '不切换'} '
      '(有效候选样本 ${samples.where((e) => usable(e.$2)).length}/${candidates.length})',
    );
    if (!faster) {
      // 基线自己都低于健康线时不能说"CDN 都正常" —— 那是没得换，不是没毛病。
      return (
        verdict: baseBps >= _kCdnHealthyMBps
            ? _CdnRoundVerdict.healthy
            : _CdnRoundVerdict.noBetter,
        service: null,
        bytes: base.bytes,
        micros: base.micros,
      );
    }
    return (
      verdict: _CdnRoundVerdict.better,
      service: best.$1,
      bytes: best.$2.bytes,
      micros: best.$2.micros,
    );
  }

  /// 本轮测速的目标字节偏移。
  ///
  /// 用 position/duration 的比例把播放头映射到 size 上，并强制落在
  /// `[size × _kCdnOffsetFloor, size − _kCdnReadWindowBytes]`：头部是每个镜像都
  /// 快的"面子区间"（坏镜像在那里也是满速），尾部要留够一个读窗口，否则读到一半
  /// 就撞 EOF，会被误判成"这个镜像慢"。
  ///
  /// duration 未知时退回 0：只能测头部，好过不测。听视频模式下 mpv 拿到的是音频
  /// 地址，拿视频的偏移去读必然 416，也退回 0。
  int _starveOffset(Duration position, int? size) {
    if (size == null || size <= 0) return 0;
    if (plPlayerController.onlyPlayAudio.value) return 0;
    final total = plPlayerController.durationInMilliseconds;
    if (total <= 0) return 0;
    final upper = size - _kCdnReadWindowBytes;
    final lower = (size * _kCdnOffsetFloor).round();
    if (lower >= upper) return 0;
    final offset = (size * (position.inMilliseconds / total)).round();
    return offset.clamp(lower, upper);
  }

  /// 只换镜像 host：不重新请求 playurl，也不动 codec（updatePlayer 里的
  /// `findVideoByQa(setCodecs: true)` 会改 codec，这里不需要）。
  Future<bool> _switchTo(
    CDNService service,
    int generation, {
    required Duration resumeAt,
  }) async {
    // 测速期间用户可能已经换集/重置，此时这条 URL 属于上一轮的播放列表。
    if (generation != _cdnGeneration) return false;
    final newVideo = CdnSpeedTest.urlFor(firstVideo.playUrls, service);
    // 永远不要用空的 source 调 setDataSource。
    if (newVideo.isEmpty) return false;

    // 续播点不能用实时 position：换源会重载播放器，重载期间它短暂归零、也可能
    // 停在 seek 中途的中间值。实测一次换源本应在 1619s，重载完却停在 351s，
    // 用户看到的就是"换个 CDN 又从前面开始了"。以触发这一轮的 [resumeAt] 为准，
    // 只有实时位置确实更靠前（用户自己往前拖了）才听它的。
    final live = plPlayerController.videoPlayerController?.state.position;
    final pos = (live != null && live > resumeAt) ? live : resumeAt;

    videoUrl = newVideo;

    final audioQa = currentAudioQa;
    final audioList = data.dash?.audio;
    if (audioQa != null && audioList != null && audioList.isNotEmpty) {
      final firstAudio = audioList.firstWhere(
        (i) => i.id == audioQa.code,
        orElse: () => audioList.first,
      );
      // disableAudioCDN 已在 getCdnUrl 内部处理，这里不用额外分支。
      final newAudio = CdnSpeedTest.urlFor(firstAudio.playUrls, service);
      if (newAudio.isNotEmpty) audioUrl = newAudio;
    }

    autoPlay = true;
    playedTime = pos;
    // 清掉它，让 playerInit 走 playedTime 分支 seek 回原位置。
    defaultST = null;

    await playerInit(autoplay: true);
    if (generation != _cdnGeneration || isClosed) return false;
    await _restoreResumePosition(pos, generation);
    return generation == _cdnGeneration && !isClosed;
  }

  /// 换源重载后确认播放位置真的回到了 [target]，落在后面就补一次 seek。
  ///
  /// [playerInit] 里那次 seek 落在哪并不受控：EDL 源的字节偏移不可知
  /// （mpv 报 `Seek failed (to N, size -78)`），重载期间 `state.position` 又短暂
  /// 归零。实测一次换源后本应在 1619s，实际停在 351s，接着 `_awaitRecovery`
  /// 按位置判据把这条其实很健康的镜像（余量 32s）判成"未恢复"，于是又换下一个、
  /// 再重载、位置再丢一次 —— 越换越偏。
  ///
  /// 只在"落在后面"时纠正：用户自己往前拖的话位置会比 [target] 大，不动他。
  Future<void> _restoreResumePosition(Duration target, int generation) async {
    if (target <= Duration.zero) return;
    final player = plPlayerController;
    for (var i = 0; i < _kCdnResumeAttempts; i++) {
      await Future<void>.delayed(_kCdnResumePoll);
      if (generation != _cdnGeneration || isClosed) return;
      if (player.positionInMilliseconds >=
          (target - _kCdnResumeTolerance).inMilliseconds) {
        return;
      }
      debugPrint(
        'CDN 自动切换: 落点 ${player.positionInMilliseconds}ms 落后于 '
        '${target.inMilliseconds}ms，补一次 seek',
      );
      await player.seekTo(target);
    }
  }

  /// 判断"是否恢复"看的是切换之后位置有没有真的推进，而不是 isBuffering。
  ///
  /// 位置之外再认一条：**缓冲补回到 mpv 的回填水位**。换源成没成功，最直接的
  /// 证据是这条镜像喂不喂得饱播放器。实测 hw 换过去之后余量 32s（满的），却因为
  /// 落点不是 [from] 被判成"未恢复"，于是又换下一个候选、再重载一次 —— 每重载
  /// 一次位置就丢一次，这就是"换 CDN 会回到前面"的来源。位置对不对是
  /// [_restoreResumePosition] 的事，不该由这里兼任。
  Future<bool> _awaitRecovery(int generation, Duration from) {
    final player = plPlayerController;
    final completer = Completer<bool>();
    final start = DateTime.now();

    void listener(Duration position) {
      if (completer.isCompleted) return;
      if (position - from >= _kCdnRecoverProgress) {
        completer.complete(true);
      }
    }

    player.addPositionListener(listener);
    final timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (completer.isCompleted) return;
      if (generation != _cdnGeneration ||
          isClosed ||
          DateTime.now().difference(start) >= _kCdnRecoverWindow) {
        completer.complete(false);
        return;
      }
      final floor = _cdnBufferFloor;
      if (floor != null && player.bufferedAhead >= floor) {
        debugPrint(
          'CDN 自动切换: 前向余量回到 ${player.bufferedAhead}s（回填水位 '
          '${floor.toStringAsPrecision(3)}s），判定已恢复',
        );
        completer.complete(true);
      }
    });

    return completer.future.whenComplete(() {
      timer.cancel();
      player.removePositionListener(listener);
    });
  }
}

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
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
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
///
/// [champion] 是这一轮**白占了一个候选位**的那个镜像（没有就是 null）。它不参与
/// 判定，只是带回来给 [_noteChampionOutcome] 记账 —— 保留票该不该继续发，只能
/// 在结果出来之后才知道。
typedef _CdnRound = ({
  _CdnRoundVerdict verdict,
  CDNService? service,
  int bytes,
  int micros,
  CDNService? champion,
});

/// 触发一轮测速的原因。影响日志和 toast 里的说法、用哪一档预算，以及
/// **结论够不够格直接换**。
///
/// 前五个触发是同一套语义：当前镜像"喂不动"，所以要拿候选跟它比速度，赢过
/// [_kCdnStarveRatio] 才值得付一次重载。[_CdnTrigger.decode] 是唯一的例外 ——
/// 它比的根本不是速度，见那个成员的注释。
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
  rebuffer,

  /// 判据 4：解码器在刷"这段字节我解不出来"（见 `PlPlayerController.
  /// onDecodeError`）。
  ///
  /// 这个触发**跳过** [_kCdnStarveRatio] 那一关，直接换。理由是那一关的前提
  /// 在这里根本不成立：门槛问的是"候选比当前镜像快多少倍"，而坏镜像的速度
  /// **是快的** —— 实测它把垃圾字节以 2~14MB/s 送过来，比健康镜像还快，所以
  /// 每轮测速都判"基线健康 —— 卡顿多半不在 CDN"，然后什么都不做。要比的是
  /// "谁的字节能解出画面"，那是测速测不出来的东西，只有解码器知道。
  decode;

  /// 日志/toast 里的简称。
  String get label => switch (this) {
    _CdnTrigger.stall => '卡顿',
    _CdnTrigger.starve => '缓冲饥饿',
    _CdnTrigger.probe => '定期测速',
    _CdnTrigger.preflight => '预检',
    _CdnTrigger.rebuffer => '小卡顿',
    _CdnTrigger.decode => '解码错误',
  };
}

// ---------------------------------------------------------------------------
// 卡顿自动切换 CDN
//
// 触发是纯反应式的：只有播放器上报故障（位置不推进、前向缓冲长期趴在低位、
// 余量失真、**或解码器在刷"这段字节我解不出来"**）才测速。卡住的播放器已经
// 不再下载，此时测速不会与播放争带宽，结果才可信；健康播放时测速反而会
// 制造我们要修的卡顿。
//
// 测速一律在"播放头即将需要的那段字节"上做，并且总是先测当前镜像作基线：
// 坏镜像的头部区间和好镜像一样快（实测 upos-sz-mirrorcosov 前 100MB 跑满
// 23MB/s，之后掉到 30KB/s），只在头部取样等于永远发现不了故障，只测候选而
// 不测基线则没有比较对象。
//
// **测速测不出全部故障**：它只能回答"这条镜像供得上供不上"。同一台机器上
// 还有第二种坏法 —— 镜像以正常甚至更高的速度送**垃圾字节**，吞吐、余量、
// 位置、hwdec 全对，只有画面是冻的。那种故障要解码器来报，而且因为速度健康，
// 决策必须绕过"候选须比基线快 [CdnSwitchMixin._kCdnStarveRatio] 倍"这一关，
// 见 [_CdnTrigger.decode]。
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

  /// [resumeAt] 是**显式**的起播点，只有 P3 就地重建会传（见
  /// `utils/resume_seek.dart`）：它压过 [defaultST] / [playedTime]，但零值不算数。
  Future<void> playerInit({
    bool? autoplay,
    bool autoFullScreenFlag = false,
    Duration? resumeAt,
  });

  // ---------------------------------------------------------------------------
  // 参数：改这些数字就是在改自动切换的性格。触发语义见上面的契约。
  // ---------------------------------------------------------------------------

  /// 单次卡顿最多尝试几个镜像。
  static const int _kCdnMaxAttempts = 3;

  /// 候选必须比当前镜像快这么多倍才值得切换。切换是一次真实的重新加载
  /// （playerInit + seek 回原位），画面会闪一下，所以宁可少切。
  ///
  /// 解码错误那一档不走这条（见 [_CdnTrigger.decode]）：那里的病不在速度上。
  static const double _kCdnStarveRatio = 1.5;

  /// 当前镜像**已经喂不动这条流**（实测低于 `对象大小 / 时长`）时放宽到这个
  /// 倍数。
  ///
  /// 1.5 倍的隐含前提是"基线是健康的，只有明显更快才值得为它付一次重载"。
  /// 基线低于码率时这个前提不成立 —— 它不是"健康但有更好的"，而是**确定要
  /// 饿死**，这时候 1.2 倍也是实打实的画面。实测一例：对象 239720678B /
  /// 1075.5s = 0.223MB/s 是硬需求，基线 `akam` 只有 0.171（需求的 77%，注定
  /// 饿死），候选 `tf_tx` 0.242 刚好够，1.42x 被 1.5 挡下。
  ///
  /// 方向很重要：这是在基线**被证明不够用**时放宽，不是给赢家加绝对门槛。
  /// "讯号普遍很弱、换了也未必够"的场景不受影响。
  static const double _kCdnStarveRatioLow = 1.2;

  /// 测到高于这个速率就认为镜像本身不是瓶颈：1MB/s ≈ 8Mbps，远高于 1080P 码率。
  static const double _kCdnHealthyMBps = 1.0;

  /// 距上次尝试必须又真实播放了这么久，才允许新的尝试，避免死链无限重试。
  static const Duration _kCdnMinReProgress = Duration(seconds: 3);

  /// 放弃后冷却多久才允许再次自动切换。
  static const Duration _kCdnGiveUpCooldown = Duration(seconds: 60);

  /// 一轮下来**一个有效样本都没测到**时的冷却，比 [_kCdnGiveUpCooldown] 短。
  ///
  /// "测不出来"是不知道，不是"测过了没问题"，不该跟 healthy/noBetter 共用
  /// 一把锁：实测 @350s 一轮 0 样本锁了 60s，紧接着 @353 缓冲饥饿、@357
  /// 小卡顿、@362 卡顿、@363、@364 全被丢掉，而那 60 秒墙钟里画面一直是冻的
  /// （卡顿时墙钟约是视频位置的 7 倍）。
  ///
  /// 也不设成 0：卡顿触发会反复来，每次都是一整轮（3 条流 × 2MiB ≈ 6MB），
  /// 在一条连码率都喂不动的链路上按触发频率打是雪上加霜。
  static const Duration _kCdnUnmeasuredCooldown = Duration(seconds: 20);

  /// 小卡顿探测的节流。它比 [_kCdnProbeInterval] 敏感得多，所以靠这个间隔
  /// 而不是靠判据来限流：两次探测之间至少隔这么久，免得一次持续抖动被拆成
  /// 十几轮测速，反而把带宽全抢走。
  static const Duration _kCdnRebufferCooldown = Duration(seconds: 30);

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

  /// 解码错误档换源后，要求"干净"多久才认定恢复。
  ///
  /// 这一档不能用位置或余量判恢复：坏镜像的特征恰恰是余量填得满、位置还被
  /// 音频时钟推着走，两者都"看着正常"。唯一的真话是换了之后**不再吐坏字节**
  /// （[PlPlayerController.lastDecoderCorruptionAt]）。
  static const Duration _kCdnDecodeCleanWindow = Duration(seconds: 4);

  /// 上面那个干净窗口的宽限：换源重载期间旧流还在吐报错（解码器在消化旧字节），
  /// 这段时间的报错不算新镜像的账。
  static const Duration _kCdnDecodeRecoverGrace = Duration(seconds: 4);

  /// 解码错误档等待恢复的最长时间，比 [_kCdnRecoverWindow] 长：一次重载
  /// （实测 5~10s）之后还要走完"宽限 + 干净窗口"（≈8s）才敢下结论。
  static const Duration _kCdnDecodeRecoverWindow = Duration(seconds: 18);

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

  /// 历史速度记录多久没被刷新就重新开一个窗口。
  ///
  /// 只保留"最大值"会让一个早先的高峰永远占着冠军位子：09:00 测到 5MB/s、
  /// 之后实测只有 0.3MB/s，仍会被每轮送进候选窗口白占一个位子。所以超过这个
  /// 时间没刷新过就直接覆盖，而不是取最大值 —— 峰值会自然老去。
  static const Duration _kCdnRecordReset = Duration(minutes: 30);

  /// 历史速度记录超过这么久就作废，不再参与冠军评选。网络状况是随时间变的，
  /// 昨天的冠军今天未必还是。
  static const Duration _kCdnRecordExpiry = Duration(hours: 6);

  /// 历史冠军连着这么多轮**没能成为切换目标**，就把它从冠军位请出去，把那个
  /// 候选位让给轮换。判定与理由见 [_cdnChampionMisses] 和 [_noteChampionOutcome]。
  ///
  /// 取 2 而不是更大：误降级的代价只是"这一集少一张保留票"，而它照样能被轮换
  /// 窗口取到、照样能靠被选中重新挣回来；而漏降级的代价是每轮白少测一个镜像，
  /// 实测能连任 25 轮。宁可早点让位。
  static const int _kCdnChampionMisses = 2;

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

  /// 本集里给过**坏字节**的镜像 host。
  ///
  /// 和 [_cdnNoSample] 的区别是正好相反的两种病：那是"一个字节都到不了"，这是
  /// "字节到得又快又好，只是解不出画面"。所以测速两种都测不出来 —— 坏镜像的
  /// 吞吐实测 2~14MB/s，比健康镜像还高。这笔账只能由解码器来记（见
  /// [_CdnTrigger.decode]）。
  ///
  /// **不记的话会来回弹**：坏镜像当基线时被强制换走，下一轮**测速**又会把它评成
  /// 最快候选（它是真的快），于是换回去、画面再冻一次。按 host 记而不是按
  /// [CDNService]：基线那个 host 是 API 分的，不一定来自枚举表，而候选一律来自
  /// 枚举表，两边对不上就没法比。
  ///
  /// 只在换集/换 P 时清（[resetCdnAutoSwitch]）：换一个视频就是另一个对象，
  /// 同一条边完全可能是好的。
  final Set<String> _cdnBadHosts = {};

  /// 历史冠军的"欠账"：连着多少轮**没能成为切换目标**。达到
  /// [_kCdnChampionMisses] 就不再给它留候选位。
  ///
  /// 冠军位是一张**保留票** —— 让快的镜像不必等轮换排到（见 [_cdnChampion]）。
  /// 但保留票的前提是"迟早能兑现"。[_recordCdnSample] 只留最大值、且只在**刷新
  /// 纪录**时才续 30 分钟的时钟，于是当一条记录是靠一次突发立起来的、此后每轮
  /// 实测都更慢时，它既不更新也不作废（覆盖不了自己，也够不着 6 小时的作废线），
  /// 冠军位就被永久占住。
  ///
  /// 实测 2026-10-11 一局 25 轮：`ali（阿里云）` 连任 25/25 轮冠军，轮轮实测
  /// 0.475–0.879MB/s，而同一轮的基线有 1.7–6.1MB/s（比值 0.12–0.47，门槛 1.5）
  /// —— 一个候选位白占到底，轮换一轮只够走一个镜像。
  ///
  /// 用**结果**记这个账，而不是拿记录去比当下基线：基线每轮都在变（实测同一条
  /// 链路隔几分钟能差 4 倍），静态记录比动态读数本来就没有可靠门限；而"这一轮
  /// 它有没有被选中"是确定的事实。被选中就清零，所以降级可逆 —— 它还能从轮换
  /// 窗口里被取到，并靠被选中重新挣回冠军位（见 [_noteChampionOutcome]）。
  final Map<CDNService, int> _cdnChampionMisses = {};

  /// 这一集的对象总长。所有镜像服务字节一致的同一个对象，探一次就够；
  /// 缓存它主要是为了小卡顿档 —— 3 秒预算里不该再花几秒去探大小。
  int? _cdnObjectSize;

  Duration _cdnLastAttemptPos = Duration.zero;
  CDNService? _cdnAutoServiceSnapshot;
  Dio? _cdnAutoDio;

  /// 单测注入点：填了就用它测速，不填就走真网络（[CdnSpeedTest.createDio]）。
  ///
  /// 存在的理由只有一条：一轮测速要跑满 `probeSize` + 若干 `measureAt`，网络
  /// 是这一整套判据里唯一不可离线复现的东西。给它一个假适配器，整条
  /// [_onPlayerStall] → [_autoSwitchLoop] → [_switchTo] 的时序就能在
  /// `flutter test` 里重放（见 `test/pages/cdn_switch_mixin_test.dart`）。
  @visibleForTesting
  Dio? cdnAutoDioForTest;

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

  /// 本页**有没有挂载过**。只给 [attachCdnSwitch] 分场合用：页面创建时那一次
  /// （宿主 `onInit`）要武装装载后的预检，之后每次回页（`didPopNext`）不要 —— 两次
  /// 调用的是同一个方法，只能靠它区别。见 [restartCdnProbe] 的 `armPreflight`。
  bool _cdnAttachedOnce = false;

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

  /// 记下一个镜像这一轮实测到的速度，供 [_cdnChampion] 每轮把冠军送进候选窗口。
  ///
  /// 两条规则：超过 [_kCdnRecordReset] 没刷新过就**整个覆盖**（旧窗口作废，峰值
  /// 自然老去），否则只留最大值。只留最大值而没有第一条的话，一个早先的高峰
  /// 会永远占着冠军位子：09:00 测到 5MB/s、之后实测只有 0.3MB/s，仍会被每轮
  /// 送进候选窗口白占一个位子。
  void _recordCdnSample(
    CDNService service,
    CdnSample sample,
    DateTime now, {
    bool asCandidate = false,
  }) {
    if (sample.micros <= 0) return;
    final speed = sample.bytes * 1000000 ~/ sample.micros;
    // 0 天然就是"没记录过"，所以绝不能把 0 写进去。
    if (speed <= 0) return;

    final record = Pref.cdnSpeedRecord;
    final at = service.index * 3;
    // 枚举增删过的话旧记录会短一截，补齐而不是越界。
    if (record.length < CDNService.values.length * 3) {
      record.addAll(
        List.filled(CDNService.values.length * 3 - record.length, 0),
      );
    }
    var changed = false;
    // "当过候选"是镜像的固有属性（host 改写之后服务端认不认），不随时间过期，
    // 所以只置 1、从不回 0 —— 包括下面 stale 覆盖的时候。
    if (asCandidate && record[at + 2] != 1) {
      record[at + 2] = 1;
      changed = true;
    }
    final stale = CdnSpeedTest.recordTooOld(
      now,
      DateTime.fromMillisecondsSinceEpoch(record[at + 1] * 1000),
      _kCdnRecordReset,
    );
    if (stale || speed > record[at]) {
      record[at] = speed;
      record[at + 1] = now.millisecondsSinceEpoch ~/ 1000;
      changed = true;
    }
    if (changed) Pref.cdnSpeedRecord = record;
  }

  /// 记录里速度最高、且**当过候选**的那个镜像，还没有超过 [_kCdnRecordExpiry]。
  ///
  /// 冠军**不免检**：它照样每轮实测，照样要赢 [_kCdnStarveRatio] 倍才切换。
  /// 记录只决定"优先被想到"，不决定"优先被信任"，所以记录过期或不准也不会
  /// 造成误切，只是白占一个位子。
  ///
  /// 但"只是白占一个位子"这件事本身是要还的：连着 [_kCdnChampionMisses] 轮没能
  /// 成为切换目标就不再发这张保留票，见 [_cdnChampionMisses]。
  ///
  /// 要求"当过候选"是因为基线样本和候选样本不是同一个测量：基线用原始签名
  /// URL，候选用改写 host 之后的 URL。`akamai` 就是反例 —— 当基线能跑到
  /// 5MB/s，当候选每次都 403。把它送进候选窗口是纯亏：冠军位白占，轮换还少
  /// 测一个镜像（实测 @578s 那轮就是这样，整轮颗粒无收）。
  ///
  /// 等于当前正在播的 host 时**跳过它、继续往下找**，而不是整轮作废。原先是在
  /// 结尾写 `if (best.host == currentHost) return null;`，那等于把"当前镜像恰好是
  /// 最快的那个"翻译成"没有冠军"，而这两种情况该得到的答案是相反的。
  ///
  /// 实测就死在这上面：`cosov`（当前 host）当过一次候选、拿到 `cand=1` 之后又
  /// 每轮作基线写读数，最后记到 19.2MB/s（2MiB/0.12s 的热缓存突发），于是它永远
  /// 是记录里最快的那个、又永远被结尾那句丢掉。十轮日志里「历史冠军」出现 0 次、
  /// 轮换每轮固定 +2（`cdnMirrorRotation` 停在 4）就是它的指纹。改成跳过之后，
  /// 冠军退化成"第二快的合格候选"（记录里是 `hw` 3.27MB/s），而不是"没有冠军"。
  CDNService? _cdnChampion(DateTime now, String? currentHost) {
    final record = Pref.cdnSpeedRecord;
    CDNService? best;
    var bestSpeed = 0;
    for (final service in CdnSpeedTest.mirrors) {
      // 当前在播的已经坐在基线位置上了，再占一个候选位子等于白少测一个镜像。
      if (service.host == currentHost) continue;
      // 给过坏字节的镜像不是"快不快"的问题，历史记录里它可能正是最快的那个
      // （见 [_cdnBadHosts]）。留着它等于每一轮都白占一个候选位。
      if (service.host == null || _cdnBadHosts.contains(service.host)) continue;
      // 连着几轮没被选中，这张保留票它兑现不了，让给轮换。见 [_cdnChampionMisses]。
      if ((_cdnChampionMisses[service] ?? 0) >= _kCdnChampionMisses) {
        debugPrint(
          'CDN 自动切换: 历史冠军候选 ${service.desc} 已降级，本轮不发保留票 '
          '(欠账 ${_cdnChampionMisses[service]}/$_kCdnChampionMisses)',
        );
        continue;
      }
      final at = service.index * 3;
      if (at + 2 >= record.length) continue;
      if (record[at + 2] != 1) continue;
      final speed = record[at];
      if (speed <= bestSpeed) continue;
      // 没记录过的格子时间是 0，算出来是 1970 年，自然落在过期之外。
      if (CdnSpeedTest.recordTooOld(
        now,
        DateTime.fromMillisecondsSinceEpoch(record[at + 1] * 1000),
        _kCdnRecordExpiry,
      )) {
        continue;
      }
      best = service;
      bestSpeed = speed;
    }
    return best;
  }

  /// 一轮测速结束后给冠军位记账：它这一轮被选中了吗？
  ///
  /// 规则就一句：**谁被选中谁就挣到了**。所以冠军被选中就保住位子；轮换里冒出来
  /// 的镜像被选中，就把它自己的欠账清零 —— 一个被降级的冠军照样能从轮换窗口里
  /// 重新挣回来，降级不是永久的。
  ///
  /// 一轮作废（416 / 基线未遵守 Range）时谁也没测出东西，这一轮不算任何人的账。
  /// 其余情况冠军只要没成为切换目标就记一笔：包括它测得慢、包括别的候选比它更
  /// 合适、也包括它一个字节都没测到 —— 从"这张保留票该不该继续发"的角度看，
  /// 这三种都是没兑现。
  void _noteChampionOutcome(_CdnRound round) {
    if (round.verdict == _CdnRoundVerdict.better) {
      _cdnChampionMisses.remove(round.service);
    }
    final champion = round.champion;
    if (champion == null ||
        round.verdict == _CdnRoundVerdict.unmeasurable ||
        round.service == champion) {
      return;
    }
    final misses = (_cdnChampionMisses[champion] ?? 0) + 1;
    _cdnChampionMisses[champion] = misses;
    debugPrint(
      misses >= _kCdnChampionMisses
          ? 'CDN 自动切换: 历史冠军 ${champion.desc} 连续 $misses 轮没能成为切换目标，'
                '退出冠军位让给轮换'
          : 'CDN 自动切换: 历史冠军 ${champion.desc} 本轮没能成为切换目标 '
                '($misses/$_kCdnChampionMisses)',
    );
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
  /// [resetPlayerAccounting] 为假时不动共享播放器的解码账 —— 见 [detachCdnSwitch]：
  /// 那份账属于现役页面，一个已经不在台上的旧页退出时没资格清它。
  void resetCdnAutoSwitch({bool resetPlayerAccounting = true}) {
    _cdnGeneration++;
    _cdnAutoBusy = false;
    _cdnAutoAttempts = 0;
    _cdnTriedAt.clear();
    _cdnNoSample.clear();
    // 换集/换画质是新的对象，坏字节的账也跟着作废：同一条边对另一个视频
    // 完全可能是好的。
    _cdnBadHosts.clear();
    // 换集/换画质是新的比较对象，冠军位的欠账重新计。
    _cdnChampionMisses.clear();
    // 换集/换画质后对象变了，缓存的总长不再适用。
    _cdnObjectSize = null;
    _cdnGiveUpUntil = null;
    _cdnLastAttemptPos = Duration.zero;
    _cdnAutoServiceSnapshot = null;
    // 小卡顿的节流也要重来：不带上它，新一集开头 30 秒的 rebuffer 全被上一集的
    // 时间戳压住。
    _cdnQuickProbeAt = null;
    // 解码错误的账在播放器侧，换对象时一并作废（同一条边对另一个视频可能是好的）。
    if (resetPlayerAccounting) plPlayerController.resetDecodeErrorAccounting();
  }

  /// 下面这些诊断刻意不套 kDebugMode：release 包只走手机测试，套了就看不到。
  static String _fmtSpeed(int bytes, int micros) =>
      '${(bytes / micros).toStringAsPrecision(3)}MB/s';

  /// 换画质：**换了对象**。字节总长、坏 host、位置闸门、在途快照都作废重来。
  ///
  /// 和 [resetCdnAutoSwitch] 的区别在时间型冷却：这里**保留** [_cdnGiveUpUntil] /
  /// [_cdnTriedAt] / [_cdnNoSample]。原先把整套 reset 无条件放在换画质路径上，会
  /// 顺手清掉放弃冷却和镜像冷却，等于每次调画质都重新开闸。
  ///
  /// 但对象相关的几样必须清 —— 尤其是 [_cdnObjectSize]：换了画质对象长度就变了，
  /// 留着旧值会把取样偏移指到新对象之外，服务端回 416，整集每轮都测不出东西。
  ///
  /// 清 [_cdnAutoBusy] 必须和 [_autoSwitchLoop] 里的代际守卫配套：在途那一轮被
  /// generation++ 作废后，它的 whenComplete 不会再清 busy（见那里的注释），所以
  /// 只能在这里放闸，否则闸门永远关着、此后再也不响应任何触发。
  void resetCdnForNewObject() {
    _cdnGeneration++;
    _cdnObjectSize = null;
    _cdnBadHosts.clear();
    _cdnChampionMisses.clear();
    _cdnLastAttemptPos = Duration.zero;
    _cdnAutoServiceSnapshot = null;
    plPlayerController.resetDecodeErrorAccounting();
    if (_cdnAutoBusy) {
      _cdnAutoBusy = false;
      _cdnAutoAttempts = 0;
    }
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
    // 节流只在**这次探测真的起步了**之后才算数。原先先写时间戳再交给闸门，
    // 被 busy/冷却/进展闸挡下的那一次照样把接下来 [_kCdnRebufferCooldown] 秒的
    // 探测机会吃掉了 —— 那几个闸本来就是"现在别动"，而节流却被它顺手消费，
    // 于是画面一直冻着也要等满 30s 才轮到下一次。连续 rebuffer 刷不爆：一旦被
    // 接受，时间戳当场落下，后面的都在节流里。
    if (_onPlayerStall(position, trigger: _CdnTrigger.rebuffer)) {
      _cdnQuickProbeAt = now;
    }
  }

  /// 解码错误风暴（见 `PlPlayerController.onDecodeError`）触发的换源。
  ///
  /// 只改一件事：**结论直接照用**，不跟基线比速度（理由见 [_CdnTrigger.decode]）。
  /// 其余闸门（并发、冷却、换源快照）一件不减 —— 它和别的触发抢的是同一个
  /// 播放器，不能因为"画面冻着更急"就允许并发重载。
  void _onDecodeError(Duration position) =>
      _onPlayerStall(position, trigger: _CdnTrigger.decode);

  /// 返回**这次触发有没有真的起步**（闸门全过、[_autoSwitchLoop] 已起）。调用方
  /// 靠这个把"这一次没被丢"和"被丢了"分开：小卡顿的节流（[_onPlayerRebuffer]）
  /// 和预检的 pending（[_onCdnProbeTick]）都只该在起步之后才消费，否则一次被
  /// 冷却/进展闸挡下的触发会白吃掉下一次机会（"被丢弃的触发不该改状态"）。
  ///
  /// 签名仍是 `void Function(Duration)` 可赋值（`onStall` 是 ValueChanged），所以
  /// 直接挂在播放器上报口上不受影响。
  bool _onPlayerStall(
    Duration position, {
    _CdnTrigger trigger = _CdnTrigger.stall,
  }) {
    final what = trigger.label;
    if (_cdnAutoBusy || isClosed || !_cdnAutoEligible) {
      debugPrint(
        'CDN 自动切换: 忽略$what @${position.inSeconds}s '
        '(busy=$_cdnAutoBusy closed=$isClosed eligible=$_cdnAutoEligible)',
      );
      return false;
    }

    // 解码错误同样不吃放弃冷却（理由和下面绕过进展闸那一条同源）：病在**字节**上、
    // 画面当场就是冻的，冷却期那 20~60s 等不起；而它自己的节流是播放器侧的
    // [_kDecodeErrorCooldown]（一次故障只报一次）—— 两道闸叠起来就是"永远不救"。
    //
    // 2026-10-12 真机取证：那次**唯一**的风暴上报（13:56:10.169）正好落在轮 1 挣来的
    // 20s 冷却（`_kCdnUnmeasuredCooldown`）里，被这里吞掉；而播放器侧上报是**一次性
    // 消费**（先清窗口、再武装 30s 静默、最后才回调，通道是 `void` 没有回执），所以
    // 那个瞬时风暴再也不会重报 —— 画面一直冻到 6 分钟后定期档碰巧撞上"基线无有效
    // 样本 → 直接切换"才恢复。
    final cooldownUntil = _cdnGiveUpUntil;
    if (trigger != _CdnTrigger.decode &&
        cooldownUntil != null &&
        DateTime.now().isBefore(cooldownUntil)) {
      debugPrint('CDN 自动切换: 冷却中，忽略$what @${position.inSeconds}s');
      return false;
    }

    // 距上次尝试没有实质进展 → 这个视频是真的放不动，不要再花钱测速。
    // 缓冲饥饿的位置一直在被音频时钟推着走，通常能正常通过这一关。
    //
    // 解码错误是例外：它的病在**字节**上，跟位置动不动没关系，而画面冻住时
    // 位置也常常是冻的 —— 拿位置当门槛等于"冻得越死越不许救"。压住它的是
    // 播放器那边的 [_kDecodeErrorCooldown]（一次故障只报一次），这里不必再压。
    // 位置回退（用户回拖、playRepeat 循环）会让下面的差值恒为负，闸门就永远
    // 关上了 —— 直到播回上一次尝试的位置为止。回退一律当作新的播放区间，重开闸。
    // 放在这里（前面几道 return 之后）：被丢弃的触发不该改状态。
    if (_cdnLastAttemptPos != Duration.zero && position < _cdnLastAttemptPos) {
      _cdnLastAttemptPos = Duration.zero;
    }
    if (trigger != _CdnTrigger.decode &&
        _cdnLastAttemptPos != Duration.zero &&
        position - _cdnLastAttemptPos < _kCdnMinReProgress) {
      debugPrint(
        'CDN 自动切换: 距上次尝试只推进了 '
        '${(position - _cdnLastAttemptPos).inSeconds}s，忽略',
      );
      return false;
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
      force: trigger == _CdnTrigger.decode,
    ).whenComplete(() {
      // 只清**本代**的闸。中途换集/换画质会 generation++，那一轮已经作废，而新的
      // 一轮（新代）可能已经把 busy 置真 —— 陈旧的这里不能把它清掉，否则会出现
      // 两条 loop 并发跑。
      if (!isClosed && generation == _cdnGeneration) _cdnAutoBusy = false;
    });
    return true;
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
        _CdnTrigger.decode =>
          '解码错误 @${position.inSeconds}s，当前镜像给的是坏字节'
              '（画面已解不出来），直接换源、不看速度',
      };

  /// 启动后台测速：每 [_kCdnPreflightPoll] 检查一次，做完那一次预检之后就
  /// 改按 [_kCdnProbeInterval] 走。换 P / 换集（[onReset]）会重新计时。
  ///
  /// [armPreflight] 把"重新挂定时器"和"武装预检"两件事分开。回页（[attachCdnSwitch]
  /// 的第二次及以后）只要前者：那是"重新露面"，不是新视频，无条件再武装一次预检
  /// 等于每次从相关视频返回都白花一轮 ~6MB 的测速。传假时**不碰**
  /// [_cdnPreflightPending]，所以被顶掉期间还没做的那次预检照旧留着。传真（默认）
  /// 的是换 P / 换集（[onReset]）与页面的**首次**挂载。
  void restartCdnProbe({bool armPreflight = true}) {
    if (armPreflight) {
      _cdnPreflightPending = true;
      _cdnPreflightSince = null;
    }
    _cdnProbeTimer?.cancel();
    // 节拍跟着**当前 pending 状态**走，而不是跟着入参：回页时若预检还没做，就
    // 仍用 [_kCdnPreflightPoll] 让它尽快跑掉；做完了才降到 [_kCdnProbeInterval]。
    _cdnProbeTimer = Timer.periodic(
      _cdnPreflightPending ? _kCdnPreflightPoll : _kCdnProbeInterval,
      (_) => _onCdnProbeTick(),
    );
  }

  /// 本页是不是当前挂在播放器上的那一页。
  ///
  /// [PlPlayerController] 是**跨页单例**，而相关视频跳转会再 push 一个 `/videoV`
  /// （不 onClose 旧的），于是两个页面各有自己的 [_cdnProbeTimer]。后挂的那一页会
  /// 覆盖回调，所以"回调是不是我的"就等于"我是不是当前页"。
  /// [PlPlayerController._isCurrVideoPage] 判不了这件事 —— 新旧两页都是 `/videoV`。
  bool get _cdnIsAttached => plPlayerController.onStall == _onPlayerStall;

  /// 这一轮测速是不是已经作废：用户换了画质/换 P/换集（[resetCdnForNewObject]
  /// 推进了 [_cdnGeneration]、清空了 [_cdnObjectSize]），或者本页已经关了。
  ///
  /// 一轮要跑好几秒，中间全是 await，作废之后**一个字节的状态都不许提交**。
  /// 尤其是 [_cdnObjectSize]：它是**一次性**的（只有 `size == null` 才会去探），
  /// 一旦被旧对象的长度重新填上，这一集就再也不会探第二次；此后每一轮都拿旧
  /// 长度算 [CdnSpeedTest.targetOffset]，落到短一截的新对象上必得 416 →
  /// unmeasurable → 自动换源整集失效。这正是 [resetCdnForNewObject] 要防的那个
  /// 416 循环 —— 它清掉了缓存，却在几秒后被在途的那一轮又填回去。
  bool _roundVoided(int generation) => generation != _cdnGeneration || isClosed;

  /// [_roundVoided] 之外再补一条：本页**是不是还挂在播放器上**。
  ///
  /// 相关视频跳转会 push 一个新页而**不** onClose 旧页、也不换代 —— 于是旧页在
  /// 每一道"这一轮还有效吗"的闸门上仍然是有效的，可它已经不在台上了，而播放器
  /// 是跨页共享的那一个。前段的闸门（[_autoSwitchLoop] 的循环口与选完之后的
  /// 复查）早就用 [_cdnIsAttached] 了，**尾段漏了**：[_switchTo] 重载完之后的
  /// 位置纠正、[_awaitRecovery] 的恢复判定，都会让被顶掉的旧页拿旧视频的落点
  /// 去 seek 新视频的播放器。尾段里驱动播放器的调用点里，这三处正是原先漏掉的。
  bool _roundLive(int generation) => !_roundVoided(generation) && _cdnIsAttached;

  /// 把本页挂到播放器的上报口上（见 [detachCdnSwitch]）。
  ///
  /// **幂等**：已经在挂载状态时直接返回。调用方之一是页面重新露面（`didPopNext`，
  /// 关掉弹层/子页后回来），那里每次都调；不幂等的话，一次普通返回就会把正在攒
  /// 的解码风暴计数清空、把后台定时器重置。
  void attachCdnSwitch() {
    if (_cdnIsAttached) return;
    // 能走到这里，说明刚才回调不在我手上 —— 典型情形是相关视频跳转时新页抢走了
    // 共享播放器的回调，我又在用户退回来时重新挂上（`view.dart` 的 `didPopNext`）。
    // 这一挂就等于宣告"在台上的又是我"：被顶掉期间留下的那一轮已经跑在**别的视频**
    // 的地址上，必须当场作废，否则它醒来时会发现 `_cdnIsAttached` 又成了真，接着
    // 往下指挥播放器。推进代际只是让 [_roundVoided] 认得它；`_cdnAutoBusy` 必须
    // 同一口气清掉 —— 那一轮的 whenComplete（见 [_onPlayerStall]）只在代际没变时
    // 才放闸，代际一动就再也不放手，留着 busy 为真等于把本页的自动换源永久关掉。
    _cdnGeneration++;
    _cdnAutoBusy = false;
    // 一页 = 一个对象。相关视频跳转会再 push 一个 `/videoV` 而**不** onClose
    // 旧的，播放器却是同一个跨页单例，于是旧页留下的解码账会直接算到新视频
    // 头上：[_decodeErrors] 的残余让新视频几条零星报错就凑满风暴门槛（提前
    // 换源），没过期的 [_decodeErrorUntil] 又把新视频真正的风暴按下去（30s 内
    // 不换源），而一条陈旧的 [lastDecoderCorruptionAt] 会让新镜像的恢复判定
    // 立刻通过。挂载即换对象，重新记账。
    plPlayerController
      ..resetDecodeErrorAccounting()
      ..onStall = _onPlayerStall
      ..onBufferStarve = _onPlayerBufferStarve
      ..onRebuffer = _onPlayerRebuffer
      ..onDecodeError = _onDecodeError;
    // **首次挂载**（页面 `onInit`）要武装装载后那一次预检 —— 那正是"新视频装载
    // 后测一轮"的入口（初次装载走 `queryVideoUrl`，**不经过** `onReset`，所以不
    // 能指望 onReset 替它武装）。之后每次**回页**（`didPopNext`）只重挂定时器，
    // **不**重置 pending：那个视频的预检要么已经做过、要么还留着 pending 在等，
    // 无条件再武装等于每次从相关视频返回都白花一轮 ~6MB 的测速。两次调用的是
    // 同一个方法，只能靠"本页有没有挂载过"来分。
    restartCdnProbe(armPreflight: !_cdnAttachedOnce);
    _cdnAttachedOnce = true;
  }

  /// 页面销毁：只撤掉自己的回调，别把新页面的覆盖掉。
  void detachCdnSwitch() {
    // 先记下自己是不是现役页：下面把回调置空之后 _cdnIsAttached 就成了假，
    // 连"我是不是当前那页"都判不出来了。
    final wasAttached = _cdnIsAttached;
    if (plPlayerController.onStall == _onPlayerStall) {
      plPlayerController.onStall = null;
    }
    if (plPlayerController.onBufferStarve == _onPlayerBufferStarve) {
      plPlayerController.onBufferStarve = null;
    }
    if (plPlayerController.onRebuffer == _onPlayerRebuffer) {
      plPlayerController.onRebuffer = null;
    }
    if (plPlayerController.onDecodeError == _onDecodeError) {
      plPlayerController.onDecodeError = null;
    }
    _cdnProbeTimer?.cancel();
    _cdnProbeTimer = null;
    // 被顶掉的旧页关掉时（相关视频跳转后返回再退出），**共享播放器的**解码账
    // 是现役那一页的，不能被我这个正在退场的人清掉：清了会让它正攒的风暴从头
    // 再攒（推迟换源），或者让它在 _awaitRecovery 里因为 lastDecoderCorruptionAt
    // 被抹掉而提前宣布恢复。本页自己的状态照清。
    resetCdnAutoSwitch(resetPlayerAccounting: wasAttached);
  }

  /// 页面销毁。宿主 `controller.dart` 的 `onClose` 末尾会 `super.onClose()` 一路
  /// 走到这里（mixin 是 `with` 列表里的最后一个，排在 `BlockMixin` 之上）。
  ///
  /// 没有 `dispose` 可重写：GetX 的生命周期钩子是 `onClose`（`GetxController`
  /// 从 `ListenableMixin` 拿到的那个 `dispose()` 只是 ChangeNotifier 式的通知
  /// 清理，不是生命周期；Get 删除控制器走的是 `onDelete()` → `onClose()`）。所以
  /// 关 [Dio] 这件事挂在 `onClose` 上。除了撤回调（[detachCdnSwitch]），还要把
  /// 测速用的 [Dio] 关掉 —— [_cdnAutoDio] 一旦建起来就常驻（每轮复用它省掉重连
  /// 开销），不关就跟着页面泄漏。
  @override
  void onClose() {
    _cdnAutoDio?.close();
    _cdnAutoDio = null;
    super.onClose();
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
    // 新页面已经接管共享播放器（相关视频跳转会再 push 一个 /videoV，旧页面并不
    // onClose）：我这一拍只会用**旧视频的 URL** 去重载播放器。发现被顶掉就停掉
    // 自己的定时器。
    if (!_cdnIsAttached) {
      _cdnProbeTimer?.cancel();
      _cdnProbeTimer = null;
      return;
    }
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
    } else {
      if (floor == null) return;
      if (plPlayerController.bufferedAhead >= floor) return;
    }

    // **先过闸门，再决定要不要消费 pending。** 反过来（先把 pending 清掉、把
    // 定时器降到 [_kCdnProbeInterval] 档，再去调 [_onPlayerStall]）会漏：那一调
    // 可能被冷却/进展闸当场挡下，而 pending 已经清、定时器已经变慢，这次预检就
    // **静默消失**了 —— 要等整整一轮 2 分钟才轮到下一次。[_onPlayerStall] 返回的
    // 正是"有没有真的起步"，据此消费。
    final accepted = _onPlayerStall(
      Duration(seconds: plPlayerController.position.value),
      trigger: preflight ? _CdnTrigger.preflight : _CdnTrigger.probe,
    );
    if (preflight && accepted) {
      _cdnPreflightPending = false;
      _cdnPreflightSince = null;
      _cdnProbeTimer?.cancel();
      _cdnProbeTimer = Timer.periodic(
        _kCdnProbeInterval,
        (_) => _onCdnProbeTick(),
      );
    }
  }

  /// 判据 3 的回调，两头都走这里：前向缓冲在变少（供不上），或者余量涨到失真
  /// （音频在走、画面冻着 —— 播放器里的 `telemetryDiverged`）。换源型故障只在这
  /// 里露头，播放器只负责上报，怎么处理由本页决定（和 [onStall] 同一个决策链）。
  void _onPlayerBufferStarve(Duration position) =>
      _onPlayerStall(position, trigger: _CdnTrigger.starve);

  /// CDN 切换的三个 toast 都走这里，好让设置页一个开关就能全关掉。
  /// 关掉的只是提示：[debugPrint] 那一路日志不受影响。
  void _cdnToast(String message, {Duration? displayTime}) {
    if (!Pref.showCdnSwitchToast) return;
    SmartDialog.showToast(
      message,
      displayTime: displayTime ?? const Duration(seconds: 3),
    );
  }

  Future<void> _autoSwitchLoop(
    int generation,
    Duration stalledAt, {
    required String what,
    bool quick = false,
    bool force = false,
  }) async {
    var switched = false;
    // 记录本轮测到过的最好候选速率，用来判断"镜像没问题，是别处卡"。
    var bestBytes = 0;
    var bestMicros = 0;
    // 放弃时要说的话。测速给了明确结论就照实说，别让用户以为 CDN 有问题。
    String? giveUp;
    // 这一轮什么都没测出来时只锁 [_kCdnUnmeasuredCooldown]：详见那个常量的注释。
    var giveUpCooldown = _kCdnGiveUpCooldown;
    for (var attempt = 0; attempt < _kCdnMaxAttempts; attempt++) {
      if (generation != _cdnGeneration ||
          isClosed ||
          isQuerying ||
          // 本页已经被后挂的另一页顶掉了：回调早被覆盖，这一轮测的是**上一个
          // 视频**的地址，而播放器是同一个单例 —— 再往下走就会拿旧视频的 URL
          // 去 reload 新视频的播放器。除本节自己，谁都不该指挥这台播放器。
          !_cdnIsAttached ||
          !_cdnAutoEligible) {
        return;
      }
      // 用户中途手动换了 CDN，听他的。
      if (_cdnAutoServiceSnapshot != VideoUtils.cdnService) return;

      final round = await _pickFastestCdn(
        stalledAt,
        generation,
        quick: quick,
        force: force,
      );
      if (_roundVoided(generation) || isQuerying || !_cdnIsAttached) return;
      if (round == null) break;
      // 这一轮的结果已经拿到了，先给冠军位记账，再决定要不要切换。
      _noteChampionOutcome(round);
      if (round.verdict == _CdnRoundVerdict.unmeasurable) {
        // 这里说「CDN 都正常」是假话：根本没测出可比的数据。解码错误这一档
        // 更要说清楚病在哪 —— 字节是坏的这件事已经由解码器证实了，缺的是
        // "换到哪儿去"。
        giveUp = force
            ? '当前镜像的字节解不出画面，但没找到可换的镜像'
            : '无法测出更快的 CDN，暂不切换';
        giveUpCooldown = _kCdnUnmeasuredCooldown;
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
      _cdnToast('$what，尝试切换到 ${chosen.desc}\n$speed');

      // 强制换源这一档的账：解码器已经证明**正在播的这个 host** 给了坏字节，
      // 那这一集就别再回到它身上。只在第一次尝试时记 —— 那是触发这一轮的
      // 那条源；后面几次是"换过去仍没恢复"，那说明的是别的（落点、缓冲），
      // 不该拿来给新 host 定罪。
      if (force && attempt == 0) {
        final bad = Uri.tryParse(videoUrl ?? '')?.host;
        if (bad != null && bad.isNotEmpty && _cdnBadHosts.add(bad)) {
          debugPrint('CDN 自动切换: $bad 给的字节解不出画面，本集不再作为候选');
        }
      }

      switched = true;
      if (!await _switchTo(chosen, generation, resumeAt: stalledAt)) return;
      if (await _awaitRecovery(generation, stalledAt, decode: force)) {
        _cdnAutoAttempts = 0;
        _cdnLastAttemptPos = Duration.zero;
        _cdnTriedAt.clear();
        _cdnGiveUpUntil = null;
        debugPrint('CDN 自动切换: 成功，已切到 ${chosen.desc}');
        _cdnToast(
          '已切换到 ${chosen.desc}',
          displayTime: const Duration(seconds: 2),
        );
        return;
      }
      // 解码错误档：换过去仍在吐坏字节 ⇒ 这条镜像的字节也解不出画面。不记的话
      // 下一轮的**测速**又会把它评成最快候选（它真的快）而换回来，来回弹。
      //
      // 但"没恢复"不等于"这条镜像坏"：`_awaitRecovery(decode: true)` 返回 false
      // 还可能是这一轮作废了（用户换画质/换集，或本页被顶掉）—— 那时候新镜像
      // 根本没被播出过一秒，拿它头上定罪会凭空封掉一条好镜像 30 分钟。只有这一
      // 轮仍然有效，"换过去以后还在报错"才算证据。
      if (force && _roundLive(generation)) {
        final bad = chosen.host;
        if (bad != null && _cdnBadHosts.add(bad)) {
          debugPrint('CDN 自动切换: $bad 换过去仍解不出画面，本集不再作为候选');
        }
      }
      debugPrint('CDN 自动切换: ${chosen.desc} 未恢复，换下一个候选');
    }

    // 画面冻着、音频还在走的时候，上面那些"没找到更快的镜像"其实答非所问：
    // 用户已经看不到画面了，换不换 CDN 是次要的。测速没能给出更好的源，那就把
    // 当前源重载一遍 —— 重开连接会让音视频两条独立流重新对齐时钟，这是这个故障
    // 唯一不换源的解法（EDL 里视频和音频是两条流、两条连接，见播放器的 EDL 注释）。
    //
    // 用 [PLPlayerController.telemetryDiverged] **现场取值**而不是记下触发那一刻：
    // 一轮测速要跑好几秒，期间可能自己缓过来了，缓过来就不该动播放器。
    // 解码错误这一档**不走**这条覆写。它的病在**字节**上，不在"音视频两轨时间轴
    // 分家"上 —— 而 `telemetryDiverged` 在解码故障里恰恰常为真（坏镜像余量填得
    // 满、位置还被音频时钟推着走），于是原先这里会把"没找到可换的镜像"这个**正确
    // 的**结论改写成"重载当前源"，去对同一个**坏 Media** 再 refreshPlayer 一次：
    // 治错病 —— 本机解码会话真坏了的话，换源和重载同一个 Media 都不治。
    if (!switched && !force && plPlayerController.telemetryDiverged) {
      debugPrint('CDN 自动切换: 画面已冻（余量失真），重载当前源');
      plPlayerController.refreshPlayer();
      giveUp = '画面已冻，没有更快的镜像，已重载当前源';
    }

    _cdnGiveUpUntil = DateTime.now().add(giveUpCooldown);
    debugPrint(
      'CDN 自动切换: 放弃，${giveUpCooldown.inSeconds}s 内不再尝试'
      '${giveUp == null ? '' : '（$giveUp）'}',
    );
    final reason =
        giveUp ??
        (switched
            ? (force
                  // 解码错误这一档"都正常"是句错话：坏镜像的速度本来就是正常的，
                  // 它坏在字节上。照实说换了几处都没解出来。
                  ? '换了几处镜像，画面仍然解不出来，已暂停尝试'
                  : (bestMicros > 0 && bestBytes / bestMicros >= _kCdnHealthyMBps
                        ? 'CDN 都正常，可能是网络问题'
                        : '自动切换 CDN 未能改善，已暂停尝试'))
            : null);
    if (reason != null) {
      _cdnToast(reason);
    }
  }

  /// 在播放头即将需要的字节上做一轮测速：当前镜像（基线）+ 最多
  /// [CdnSpeedTest.autoCandidatesMax] 个轮换候选，同一批并发测完。
  ///
  /// 返回 null 表示这一轮无从下手（拿不到地址、没有候选），调用方静默放弃。
  /// [force] 为真时**跳过 [_kCdnStarveRatio] 那一关**（见 [_CdnTrigger.decode]）：
  /// 只要有候选拿得出可用样本，就选最快的那个换过去，不再问它比基线快多少倍。
  ///
  /// [generation] 是调用时那一轮的代号。本方法中间有两处长达数秒的 await（探
  /// 对象大小、并发测速），期间用户完全可能换画质/换集，把这轮测的东西整个换掉。
  /// 每一处 await 之后都用 [_roundVoided] 复查，作废就返回 null、一个格子都不落。
  Future<_CdnRound?> _pickFastestCdn(
    Duration position,
    int generation, {
    bool quick = false,
    bool force = false,
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
    final baseUrl = VideoUtils.cdnUrlFor(urls, CDNService.baseUrl);

    // 窗口就取 autoCandidatesMax = autoConcurrency - 1：基线要占掉一个并发位，
    // 剩下的才轮到候选，整轮必须挤进同一批。分两批的话，测基线的那几秒里缓冲
    // 已经又耗掉一截，结论就过时了 —— 饥饿时省下的每一秒都是画面。
    const limit = CdnSpeedTest.autoCandidatesMax;

    final now = DateTime.now();
    final candidates = <CDNService>[];

    // 记得最快的那个镜像固定占一个位子。轮换只保证"迟早轮到"，不保证"及时"：
    // 快的镜像正好排在下一格时，这一轮就会得出"没找到更快的镜像"。实测有一轮
    // 只轮到 hwov/ali，而 hw 就在下一格。
    //
    // 它**不是免检**：照样每轮实测，照样要赢 [_kCdnStarveRatio] 才切换。记录
    // 只决定"优先被想到"，不决定"优先被信任"，所以记录过期也不会造成误切。
    final champion = _cdnChampion(now, currentHost);
    if (champion != null) {
      // 与轮换路径同一条不变量（见下面那个 `url == baseUrl` 的 continue）：
      // host 替换不起作用时，这个"候选"跟基线是同一个 URL，测了也是自比。
      // 按代码推这条走不到（[_cdnChampion] 已经跳过 [currentHost]，而 [baseUrl]
      // 与 [videoUrl] 出自同一个 [VideoUtils.cdnUrlFor]）—— 这是防御，不是修
      // 一条已证实的故障。
      final championUrl = VideoUtils.cdnUrlFor(urls, champion);
      if (championUrl.isNotEmpty && championUrl != baseUrl) {
        candidates.add(champion);
      }
    }

    // 轮换相位在**完整镜像表**上推进，而不是在当前可用候选上。后者会随
    // `_cdnTriedAt` 收缩，两个模数（表长和候选数）对不上，窗口就会跳着走、
    // 整轮整轮地漏掉镜像 —— 实测 hw 和 cos 就是这样被跳过的。在完整表上按
    // 固定相位走，每个镜像都保证有轮到的时候。
    // 相位持久化：控制器随页面销毁，onReset(换P) 也会清状态，轮换要跨这些事件累积。
    final all = CdnSpeedTest.mirrors;
    final phase = Pref.cdnMirrorRotation % all.length;
    final rotationSlots = limit - candidates.length;

    var fromRotation = 0;
    // 三遍，一遍比一遍放宽：
    //   1) 尊重冷却；
    //   2) 忽略冷却，但仍躲开"上一轮零字节"的镜像 —— 让它们重新占掉唯一的候选位，
    //      等于每轮白搭两个 3s 超时（正是 [_kCdnDeadRetryAfter] 要避免的）；
    //   3) 全都不管，只求别出现"一轮没有候选"。
    // 只有前两遍都填不满窗口，才会走到第 3 遍。
    for (final pass in const [
      (ignoreCooldown: false, ignoreNoSample: false),
      (ignoreCooldown: true, ignoreNoSample: false),
      (ignoreCooldown: true, ignoreNoSample: true),
    ]) {
      for (var i = 0; i < all.length && fromRotation < rotationSlots; i++) {
        final service = all[(phase + i) % all.length];
        if (candidates.contains(service)) continue;
        final host = service.host;
        if (host == null || host == currentHost) continue;
        // 本集里给过坏字节的镜像不再进候选 —— 它的**速度**没问题，测速拦不住它，
        // 只有解码器认得出来（见 [_cdnBadHosts]）。
        if (_cdnBadHosts.contains(host)) continue;
        if (!pass.ignoreNoSample && _cdnNoSample.contains(service)) continue;
        if (!pass.ignoreCooldown && _cdnRecentlyTried(service, now)) continue;
        // host 替换不起作用（mcdn-only / edl:// 合成项），换过去也是同一个 URL。
        final url = VideoUtils.cdnUrlFor(urls, service);
        if (url.isEmpty || url == baseUrl) continue;
        candidates.add(service);
        fromRotation++;
      }
    }
    if (candidates.isEmpty) {
      debugPrint('CDN 自动切换: 没有可测的候选镜像');
      return null;
    }

    // 括号必须有：`??` 与 `??=` 混在一个表达式里不加括号会解析成非法左值。
    final dio = cdnAutoDioForTest ?? (_cdnAutoDio ??= CdnSpeedTest.createDio());

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
      // 探大小这几秒里用户可能换了画质/换集。作废了就一个格子都别落（见
      // [_roundVoided]），尤其不能把**旧对象**的长度写回 [_cdnObjectSize]。
      if (_roundVoided(generation)) return null;
      if (size != null && size > 0) _cdnObjectSize = size;
    }

    final readOffset = _starveOffset(position, size);
    debugPrint(
      'CDN 自动切换: 目标偏移 $readOffset/${size ?? '未知'} 字节 '
      '(位置 ${position.inMilliseconds}ms/'
      '${plPlayerController.durationInMilliseconds}ms)',
    );
    debugPrint(
      'CDN 自动切换: 测速 1 基线 + ${candidates.length} 候选'
      '${champion == null ? '' : '（含 1 个历史冠军）'} @$readOffset '
      '(轮换起点 $phase) '
      '${candidates.map((e) => e == champion ? '${e.desc}（历史冠军）' : e.desc).join(', ')}',
    );

    var offsetRejected = false;
    final tokens = <CancelToken>[];

    Future<CdnSample?> sample(String url, {required bool isBaseline}) async {
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
          // 挂载态而不是 isClosed：被顶掉的那一页（detach 但没换代）也该立刻停采样。
          // 真机是流式 socket，第一块到达就 stop()，省下这一轮 ~6MiB 的移动流量。
          isCancelled: () => !_roundLive(generation),
        );
      } on DioException catch (e) {
        // 偏移越界只对**基线**意味着整轮作废 —— 基线那份对象的长度是所有镜像的
        // 共同定义。候选回 416 只说明它自己那份短/不接受这个 range，丢掉它就行，
        // 不该连累另外两个已经测出可用样本的候选。
        if (isBaseline && e.response?.statusCode == 416) offsetRejected = true;
        rethrow;
      }
    }

    /// 兜住任何一路的失败，别让它变成未捕获的异步异常。
    Future<CdnSample?> guarded(
      String url,
      String label, {
      required bool isBaseline,
    }) async {
      try {
        return await sample(url, isBaseline: isBaseline);
      } catch (e) {
        debugPrint('CDN 测速失败 $label: $e');
        return null;
      }
    }

    // 先把请求全部发出去，再逐个 await，中间不插入任何等待。
    final label = currentHost ?? '当前';
    final baselineFuture = guarded(baselineUrl, '[基线 $label]', isBaseline: true);
    final candidateFutures = [
      for (final service in candidates)
        (
          service: service,
          future: guarded(
            VideoUtils.cdnUrlFor(urls, service),
            service.desc,
            isBaseline: false,
          ),
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

    // 测速又花了几秒，再复查一次：这一轮的读数属于**当时那个对象**。作废了就
    // 连速度记录也不该留下 —— 它会喂给下一轮的冠军位，而冠军位是"优先被信任"
    // 的候选（见 [_cdnChampion]）。
    if (_roundVoided(generation)) return null;

    // 轮换相位只能推进到这里为止。推进量必须跟随**实际从轮换取走的个数**，不能
    // 写死 `limit`：冠军占了位子时每轮只从轮换取 1 个，相位若仍推进 2，下标就永远
    // 落在偶数列 —— 奇数位的镜像再也不会被轮到，正是上面那段注释警告过的"跳着走"。
    //
    // 压在两道作废复查**之后**：探长和测速各要几秒，被作废的那一轮不该推进相位，
    // 否则它白拿走的那几个候选位会顶掉下一轮的轮换次序。
    Pref.cdnMirrorRotation = (phase + fromRotation) % all.length;

    // 无论测速成功与否，这一轮候选都进入冷却；[_kCdnRetryAfter] 之后可以重测。
    // 压在两道作废判断**之后**：给旧对象记的冷却，到了新对象手里只是凭白少几个
    // 候选（[_cdnTriedAt] 是刻意为换画质保留下来的）。
    for (final service in candidates) {
      _cdnTriedAt[service] = now;
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
        champion: champion,
      );
    }

    if (offsetRejected) return unmeasurable('目标偏移 $readOffset 越界(416)');
    if (readOffset > 0 && baseline != null && !baseline.ranged) {
      // 回 200 = 从头发的整个对象，那是在"面子区间"取样，没法跟偏移样本比。
      return unmeasurable('基线未遵守 Range(200)，样本作废');
    }

    // 一个字节都没到的候选进"死镜像"冷却，下一轮不再占候选位；下次出样本了就
    // 立刻恢复。不要拿 samples 里的"样本太小"去判死 —— 那是活着只是慢。
    //
    // 放在两道作废判断**之后**：整轮作废（416 / 基线未遵守 Range）时谁也没真测
    // 过东西，把所有人记成"死镜像"会白白锁掉 30 分钟。
    final gotSample = samples.map((e) => e.$1).toSet();
    for (final service in candidates) {
      if (gotSample.contains(service)) {
        _cdnNoSample.remove(service);
      } else {
        _cdnNoSample.add(service);
      }
    }

    /// 样本能不能拿来比较。判据在 [CdnSpeedTest.usableSample]：micros 必须为正
    /// （否则 `bytes / micros` 是 Infinity，排序里直接赢下 best），字节门槛跟档位
    /// 走（快速档只有 3 秒预算，用整轮的门槛会把最该采到的样本丢掉），offset > 0
    /// 时服务器必须真的按 Range 回 206。
    final minBytes = quick
        ? CdnSpeedTest.quickMinBytes
        : CdnSpeedTest.autoMinBytes;
    bool usable(CdnSample? s) =>
        CdnSpeedTest.usableSample(s, minBytes: minBytes, readOffset: readOffset);

    // 记下这一轮的速度当作历史。放在这几道作废判断**之后**：连这一轮自己都判
    // "没法比较"的样本（416、未遵守 Range），也没有资格去当下一轮的冠军。
    //
    // **快档（小卡顿）样本一律不记。** 原先的设想是"快档读数被争抢压低，赢不过
    // 一条干净记录"，实测证伪了：争抢只把读数**压低**，突发却把读数**抬高**，而
    // 记录取的是最大值 —— 专挑高的那个。@409s 一轮快档把 akam 记成 5.02MB/s
    // （519kB/0.11s，撞的是**字节上限**，只证明头 512KiB 快；同一链路同一深度
    // 6 秒窗口下只有 0.171MB/s），下一轮就把一个当候选时永远 403 的镜像送进了
    // 候选窗口。快档仍然可以**读**冠军，只是不能**写**记录。
    //
    // **基线样本也不记，只记候选。** 这也是实测推翻的：基线 URL 就是正在播的那
    // 条，播放器刚拉过的那个区段在边缘节点上是热的，于是基线读数是双模态的 ——
    // 热的时候 2MiB/0.12s（19.2MB/s），冷的时候才是真值（0.683MB/s）；候选测的
    // 是冷字节，从来没有这种突发。两者不是同一个测量，混进同一个格子取最大值，
    // 结果就是**当前镜像自我加冕**：记录里最快的那条永远是它自己。
    //
    // 不记也不损失什么：当前 host 本来就坐在基线位置上，[_cdnChampion] 也会跳过
    // 它，所以它不需要一条记录；等它哪天不再是当前 host，那条记录也只会是一份
    // 来自热缓存的虚高读数（`cosov` 留下的 19.2MB/s 正是如此，切走之后反而会
    // 把刚抛弃的镜像重新顶上冠军位）。
    if (!quick) {
      for (final entry in samples) {
        if (usable(entry.$2)) {
          _recordCdnSample(entry.$1, entry.$2, now, asCandidate: true);
        }
      }
    }

    final best = samples
        .where((e) => usable(e.$2))
        .sortedBy((e) => -(e.$2.bytes / e.$2.micros))
        .firstOrNull;
    // 这条流自己需要多快。这是播放的硬需求，不是 [_kCdnHealthyMBps] 那种经验值
    // —— 低于它，缓冲一定入不敷出。单位换算和那个 1e6 的坑都写在
    // [CdnSpeedTest.requiredMBps] 里，并在单测里钉住了。
    final needBps = CdnSpeedTest.requiredMBps(
      size ?? 0,
      plPlayerController.durationInMilliseconds,
    );

    if (best == null) {
      // 候选全废，但基线本身测出来了 —— 那说明当前镜像没问题，是别处卡
      // （实测里就有一次：基线 akam 3.92MB/s，两个候选一个超时一个握手失败）。
      // 这时候说"测不出更快的 CDN"会把用户引到 CDN 上去，而真正的线索在
      // 播放器日志里（Seek failed / partial file / 解码器报错）。
      final base = baseline;
      if (base != null && usable(base)) {
        // 解码错误这一档到这里就没什么可说的了：字节坏是解码器证实的，而这一
        // 轮连一个候选都没测到 —— 换无可换。基线健康 ≠ 画面健康，那两个数是
        // 两回事（坏字节是以健康的速度送过来的），所以不能借用下面那句
        // "卡顿多半不在 CDN"。
        if (force) {
          return unmeasurable('解码错误触发，但候选一个都没测到');
        }
        final baseBps = base.bytes / base.micros;
        // 喂不动这条流时它就不是"健康"。
        final starved = needBps > 0 && baseBps < needBps;
        final healthy = baseBps >= _kCdnHealthyMBps && !starved;
        // 这一句必须跟 verdict 一致：曾经无论基线多慢都印"正常"，于是同一轮里
        // 日志说"基线 0.304MB/s 正常 —— 卡顿多半不在 CDN"，紧跟着的 toast 却说
        // "当前 CDN 只有 0.304MB/s"。只有真的高于健康线才配说"正常"。
        debugPrint(
          healthy
              ? 'CDN 自动切换: 候选全无有效样本，但基线 [${currentHost ?? '当前'}] '
                    '${_fmtSpeed(base.bytes, base.micros)} 健康 —— 卡顿多半不在 CDN'
              : 'CDN 自动切换: 候选一个都没测到，基线 [${currentHost ?? '当前'}] '
                    '自己也只有 ${_fmtSpeed(base.bytes, base.micros)}'
                    '（${starved ? '这条流需要 ${needBps.toStringAsPrecision(3)}MB/s，喂不动' : '低于 ${_kCdnHealthyMBps}MB/s 健康线'}）'
                    '—— 没得换，不是没毛病',
        );
        return (
          verdict: healthy
              ? _CdnRoundVerdict.healthy
              : _CdnRoundVerdict.noBetter,
          service: null,
          bytes: base.bytes,
          micros: base.micros,
          champion: champion,
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
        champion: champion,
      );
    }

    final baseBps = base.bytes / base.micros;
    // 基线**喂不动**这条流：它不是"健康但有更好的"，而是确定要饿死。这时候
    // 1.5 倍的隐含前提（基线健康，只有明显更快才值得付一次重载）不成立。
    final starved = needBps > 0 && baseBps < needBps;
    final bar = starved ? _kCdnStarveRatioLow : _kCdnStarveRatio;
    final ratio = bestBps / baseBps;
    final faster = ratio >= bar;
    debugPrint(
      'CDN 自动切换: 判定 最快候选 ${best.$1.desc} '
      '${_fmtSpeed(best.$2.bytes, best.$2.micros)} / 基线 '
      '${_fmtSpeed(base.bytes, base.micros)} = '
      '${ratio.toStringAsPrecision(3)}x (阈值 $bar'
      '${starved ? '，需要 ${needBps.toStringAsPrecision(3)}MB/s，'
            '基线只到 ${(baseBps / needBps * 100).toStringAsFixed(0)}% 故放宽' : ''}'
      ') -> '
      '${faster ? '切换' : '不切换'} '
      '(有效候选样本 ${samples.where((e) => usable(e.$2)).length}/${candidates.length})',
    );
    if (!faster) {
      // 解码错误触发的这一档**不看这个门槛**：它比的是"谁的字节能解出画面"，
      // 而坏镜像的速度是正常的（实测 2~14MB/s，比健康镜像还高），拿速度当门槛
      // 等于永远换不动 —— 这正是修复前"基线健康 —— 卡顿多半不在 CDN"的来源。
      if (!force) {
        // 基线自己都低于健康线时不能说"CDN 都正常" —— 那是没得换，不是没毛病。
        // 喂不动这条流时同理：健康线是固定的 1MB/s，码率更高的流可以在"高于健康
        // 线"的同时依然喂不动，那也不是"没问题"。
        return (
          verdict: baseBps >= _kCdnHealthyMBps && !starved
              ? _CdnRoundVerdict.healthy
              : _CdnRoundVerdict.noBetter,
          service: null,
          bytes: base.bytes,
          micros: base.micros,
          champion: champion,
        );
      }
      debugPrint(
        'CDN 自动切换: 解码错误触发，不等 ${bar}x 门槛 —— 基线 '
        '${_fmtSpeed(base.bytes, base.micros)} 快是正常的（坏字节也是这么快'
        '送来的），只比谁的字节能解出画面',
      );
      // 绕过速度门槛，但**不绕过码率硬需求**：切换是为了躲开坏字节，而落到一条
      // 喂不动这条流的镜像上只是把"冻画面"换成"永远饿着"。needBps 未知
      // （size/duration 没探到）时退回原来的行为。
      if (needBps > 0 && bestBps < needBps) {
        return unmeasurable(
          '解码错误，但没有候选能满足 ${needBps.toStringAsPrecision(3)}MB/s 的码率',
        );
      }
    }
    return (
      verdict: _CdnRoundVerdict.better,
      service: best.$1,
      bytes: best.$2.bytes,
      micros: best.$2.micros,
      champion: champion,
    );
  }

  /// 本轮测速的目标字节偏移：只负责从播放器取现场，换算交给
  /// [CdnSpeedTest.targetOffset]（纯函数，能单测）。
  int _starveOffset(Duration position, int? size) {
    if (size == null) return 0;
    return CdnSpeedTest.targetOffset(
      size: size,
      playheadMs: position.inMilliseconds,
      // [buffered] 存的是秒，换算成毫秒才是同一个坐标。
      cacheEndMs: plPlayerController.buffered.value * 1000,
      durationMs: plPlayerController.durationInMilliseconds,
      onlyPlayAudio: plPlayerController.onlyPlayAudio.value,
    );
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
    final newVideo = VideoUtils.cdnUrlFor(firstVideo.playUrls, service);
    // 永远不要用空的 source 调 setDataSource。
    if (newVideo.isEmpty) {
      // 这是**真的失败**，不是作废轮：上面那句 generation 不符的 return 才是作废
      // （作废没试过任何东西，不装冷却是对的），而这里 host 改写对这条镜像压根
      // 不生效、一个可用 URL 都拿不出来。[_autoSwitchLoop] 拿到 false 后直接
      // return，既不写 [_cdnGiveUpUntil] 也没换过源 —— 于是下一次触发照样选中它、
      // 照样空手而归，无限重试。装一档冷却把这个死循环掐掉。
      _cdnGiveUpUntil = DateTime.now().add(_kCdnGiveUpCooldown);
      debugPrint(
        'CDN 自动切换: ${service.desc} host 改写后地址为空，放弃本次并冷却 '
        '${_kCdnGiveUpCooldown.inSeconds}s',
      );
      return false;
    }

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
      // disableAudioCDN 由 getCdnUrl 内部处理 —— 但**必须把 isAudio 传进去**：
      // 不传的话那个分支根本不成立，用户勾了「音频不跟随 CDN」，换源照样把音频
      // 的 host 改掉（正是这个设置存在要避免的"部分视频无声"）。
      final newAudio = VideoUtils.cdnUrlFor(
        firstAudio.playUrls,
        service,
        isAudio: true,
      );
      if (newAudio.isNotEmpty) audioUrl = newAudio;
    }

    // 保留用户的播放/暂停意图：解码错误档是事件驱动的，用户暂停后缓冲里残留的
    // 坏字节仍可能凑够一次风暴 —— 那时候不该把播放重新拉起来。
    final wasPlaying = plPlayerController.playerStatus.isPlaying;
    playedTime = pos;
    // 清掉它，让 playerInit 走 playedTime 分支 seek 回原位置。
    defaultST = null;

    await playerInit(autoplay: wasPlaying);
    if (!_roundLive(generation)) return false;
    await _restoreResumePosition(pos, generation);
    return _roundLive(generation);
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
      if (!_roundLive(generation)) return;
      if (player.positionInMilliseconds >=
          (target - _kCdnResumeTolerance).inMilliseconds) {
        return;
      }
      debugPrint(
        'CDN 自动切换: 落点 ${player.positionInMilliseconds}ms 落后于 '
        '${target.inMilliseconds}ms，补一次 seek',
      );
      // 必须 isSeek: false。默认档（[seekTo] 的 `isSeek = true`）在
      // `lib/plugin/pl_player/controller.dart:2004-2007` 会先
      // `await _videoPlayerController?.stream.buffer.first` 才把 seek 发出去，
      // 而换源重载期间那条流要几秒才吐第一个 buffer —— 这一发于是整段悬着
      // （真机 pili-console-3：22:00:54.646~57.054 连打四发"补一次 seek"，而 mpv
      // 到 22:00:57.497 才 `queuing seek`）。悬着的这几秒里用户跳去相关视频，
      // 它醒来时 `_videoPlayerController` 已经是**新页**的视频了，seek 就落到新页
      // 的片上，还顺手清掉新页的弹幕（`seek()` 里 `danmakuController?.clear()`）。
      // `_roundLive` 拦不住一发已经发出去的调用 —— 这里把等待去掉，窗口从
      // "整个重载期"压到"一条 mpv 命令"。**注意这只是收窄，不是根治**：根治要给
      // [PlPlayerController] 加"发起者身份"，与重载本身拦不住那条同源（见清单第三批）。
      await player.seekTo(target, isSeek: false);
    }
  }

  /// 判断"是否恢复"看的是切换之后位置有没有真的推进，而不是 isBuffering。
  ///
  /// 位置之外再认一条：**缓冲补回到 mpv 的回填水位**。换源成没成功，最直接的
  /// 证据是这条镜像喂不喂得饱播放器。实测 hw 换过去之后余量 32s（满的），却因为
  /// 落点不是 [from] 被判成"未恢复"，于是又换下一个候选、再重载一次 —— 每重载
  /// 一次位置就丢一次，这就是"换 CDN 会回到前面"的来源。位置对不对是
  /// [_restoreResumePosition] 的事，不该由这里兼任。
  ///
  /// [decode] 为真时（解码错误档触发的换源）上面两条判据都不可信：坏镜像的余量
  /// 填得满（它是**快**的），位置又被音频时钟推着走 —— 两条都会把"画面还冻着"
  /// 判成已恢复。这一档只看"换过去之后还吐不吐坏字节"。
  Future<bool> _awaitRecovery(
    int generation,
    Duration from, {
    bool decode = false,
  }) {
    final player = plPlayerController;
    final completer = Completer<bool>();
    final start = DateTime.now();

    void listener(Duration position) {
      if (completer.isCompleted || decode || !_roundLive(generation)) return;
      if (position - from >= _kCdnRecoverProgress) {
        completer.complete(true);
      }
    }

    player.addPositionListener(listener);
    final window = decode ? _kCdnDecodeRecoverWindow : _kCdnRecoverWindow;
    final timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (completer.isCompleted) return;
      final elapsed = DateTime.now().difference(start);
      if (!_roundLive(generation) || elapsed >= window) {
        completer.complete(false);
        return;
      }
      if (decode) {
        // 前 [_kCdnDecodeRecoverGrace] 秒是旧流在排空：那段时间里解码器报的错
        // 算不到新镜像头上，要**按时刻**滤掉。只用一个 `since` 是不够的 ——
        // grace 和 cleanWindow 等长时，"离最近一次报错满 4 秒"会被一条来自旧流
        // 的报错重置，判据实际退化成"离**那次旧报错**满 4 秒"，grace 想区分的
        // 那件事被它自己抹平了。
        final drain = start.add(_kCdnDecodeRecoverGrace);
        final last = player.lastDecoderCorruptionAt;
        final lastReal = last != null && last.isAfter(drain) ? last : null;
        // 滤掉旧流的报错之后，安静时长必须从**宽限期结束**算起，不能从 [start]
        // 算起。从 start 算的话 `elapsed >= grace && since >= cleanWindow` 会在
        // elapsed 刚够 grace 那一刻同时成立（since == elapsed == 4s）—— 也就是
        // **一秒安静都没观察到**就宣布恢复，grace 又从另一头变成了空转，而且跟
        // [_kCdnDecodeRecoverWindow] 注释里写的"宽限 + 干净窗口（≈8s）"对不上。
        final since = lastReal == null
            ? elapsed - _kCdnDecodeRecoverGrace
            : DateTime.now().difference(lastReal);
        if (elapsed >= _kCdnDecodeRecoverGrace &&
            since >= _kCdnDecodeCleanWindow) {
          debugPrint(
            'CDN 自动切换: 解码错误档换源后 ${since.inSeconds}s 无新报错，判定已恢复',
          );
          completer.complete(true);
        }
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

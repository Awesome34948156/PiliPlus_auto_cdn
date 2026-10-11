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
    final stale =
        now.difference(
          DateTime.fromMillisecondsSinceEpoch(record[at + 1] * 1000),
        ) >=
        _kCdnRecordReset;
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
      final age = now.difference(
        DateTime.fromMillisecondsSinceEpoch(record[at + 1] * 1000),
      );
      if (age > _kCdnRecordExpiry) continue;
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
  void resetCdnAutoSwitch() {
    _cdnGeneration++;
    _cdnAutoBusy = false;
    _cdnAutoAttempts = 0;
    _cdnTriedAt.clear();
    _cdnNoSample.clear();
    // 换集/换画质是新的比较对象，冠军位的欠账重新计。
    _cdnChampionMisses.clear();
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
          !_cdnAutoEligible) {
        return;
      }
      // 用户中途手动换了 CDN，听他的。
      if (_cdnAutoServiceSnapshot != VideoUtils.cdnService) return;

      final round = await _pickFastestCdn(stalledAt, quick: quick);
      if (generation != _cdnGeneration || isClosed || isQuerying) return;
      if (round == null) break;
      // 这一轮的结果已经拿到了，先给冠军位记账，再决定要不要切换。
      _noteChampionOutcome(round);
      if (round.verdict == _CdnRoundVerdict.unmeasurable) {
        // 这里说「CDN 都正常」是假话：根本没测出可比的数据。
        giveUp = '无法测出更快的 CDN，暂不切换';
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

      switched = true;
      if (!await _switchTo(chosen, generation, resumeAt: stalledAt)) return;
      if (await _awaitRecovery(generation, stalledAt)) {
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
      debugPrint('CDN 自动切换: ${chosen.desc} 未恢复，换下一个候选');
    }

    // 画面冻着、音频还在走的时候，上面那些"没找到更快的镜像"其实答非所问：
    // 用户已经看不到画面了，换不换 CDN 是次要的。测速没能给出更好的源，那就把
    // 当前源重载一遍 —— 重开连接会让音视频两条独立流重新对齐时钟，这是这个故障
    // 唯一不换源的解法（EDL 里视频和音频是两条流、两条连接，见播放器的 EDL 注释）。
    //
    // 用 [PLPlayerController.telemetryDiverged] **现场取值**而不是记下触发那一刻：
    // 一轮测速要跑好几秒，期间可能自己缓过来了，缓过来就不该动播放器。
    if (!switched && plPlayerController.telemetryDiverged) {
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
            ? (bestMicros > 0 && bestBytes / bestMicros >= _kCdnHealthyMBps
                  ? 'CDN 都正常，可能是网络问题'
                  : '自动切换 CDN 未能改善，已暂停尝试')
            : null);
    if (reason != null) {
      _cdnToast(reason);
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

    final now = DateTime.now();
    final candidates = <CDNService>[];

    // 记得最快的那个镜像固定占一个位子。轮换只保证"迟早轮到"，不保证"及时"：
    // 快的镜像正好排在下一格时，这一轮就会得出"没找到更快的镜像"。实测有一轮
    // 只轮到 hwov/ali，而 hw 就在下一格。
    //
    // 它**不是免检**：照样每轮实测，照样要赢 [_kCdnStarveRatio] 才切换。记录
    // 只决定"优先被想到"，不决定"优先被信任"，所以记录过期也不会造成误切。
    final champion = _cdnChampion(now, currentHost);
    if (champion != null) candidates.add(champion);

    // 轮换相位在**完整镜像表**上推进，而不是在当前可用候选上。后者会随
    // `_cdnTriedAt` 收缩，两个模数（表长和候选数）对不上，窗口就会跳着走、
    // 整轮整轮地漏掉镜像 —— 实测 hw 和 cos 就是这样被跳过的。在完整表上按
    // 固定相位走，每个镜像都保证有轮到的时候。
    // 相位持久化：控制器随页面销毁，onReset(换P) 也会清状态，轮换要跨这些事件累积。
    final all = CdnSpeedTest.mirrors;
    final phase = Pref.cdnMirrorRotation % all.length;
    final rotationSlots = limit - candidates.length;

    var fromRotation = 0;
    // 第二遍忽略冷却：宁可重测刚测过的，也不要出现"一轮没有候选"。
    for (final ignoreCooldown in const [false, true]) {
      for (var i = 0; i < all.length && fromRotation < rotationSlots; i++) {
        final service = all[(phase + i) % all.length];
        if (candidates.contains(service)) continue;
        final host = service.host;
        if (host == null || host == currentHost) continue;
        if (!ignoreCooldown && _cdnRecentlyTried(service, now)) continue;
        // host 替换不起作用（mcdn-only / edl:// 合成项），换过去也是同一个 URL。
        final url = CdnSpeedTest.urlFor(urls, service);
        if (url.isEmpty || url == baseUrl) continue;
        candidates.add(service);
        fromRotation++;
      }
    }
    // 推进量必须跟随**实际从轮换取走的个数**，不能写死 `limit`。冠军占了位子
    // 时每轮只从轮换取 1 个，相位若仍推进 2，下标就永远落在偶数列 —— 奇数位
    // 的镜像再也不会被轮到，正是上面那段注释警告过的"跳着走"。
    Pref.cdnMirrorRotation = (phase + fromRotation) % all.length;

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
      'CDN 自动切换: 测速 1 基线 + ${candidates.length} 候选'
      '${champion == null ? '' : '（含 1 个历史冠军）'} @$readOffset '
      '(轮换起点 $phase) '
      '${candidates.map((e) => e == champion ? '${e.desc}（历史冠军）' : e.desc).join(', ')}',
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
        champion: champion,
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
    return (
      verdict: _CdnRoundVerdict.better,
      service: best.$1,
      bytes: best.$2.bytes,
      micros: best.$2.micros,
      champion: champion,
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

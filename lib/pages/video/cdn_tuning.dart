/// 这里只放**证据背书的调参值**，不放逻辑。
///
/// 每个数字的来历都写在它自己的注释里（真机日志、实测样本、为什么是这个
/// 量级）。改之前先读注释 —— 这些不是"看着顺眼"的默认值，窗口开短一点
/// 就会误伤健康装载，开长一点那族病就永远等不到救援。
///
/// 需要读取它们的地方（页面、测试、脚本）一律用 `CdnTuning.xxx`，不要再抄一遍
/// 数字。
library;

/// 播放器看门狗的调参值。
abstract final class CdnTuning {
  /// 单次卡顿最多尝试几个镜像。
  static const int maxAttempts = 3;

  /// 候选必须比当前镜像快这么多倍才值得切换。切换是一次真实的重新加载
  /// （playerInit + seek 回原位），画面会闪一下，所以宁可少切。
  ///
  /// 解码错误那一档不走这条（见 [_CdnTrigger.decode]）：那里的病不在速度上。
  static const double starveRatio = 1.5;

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
  static const double starveRatioLow = 1.2;

  /// 测到高于这个速率就认为镜像本身不是瓶颈：1MB/s ≈ 8Mbps，远高于 1080P 码率。
  static const double healthyMBps = 1.0;

  /// 距上次尝试必须又真实播放了这么久，才允许新的尝试，避免死链无限重试。
  static const Duration minReProgress = Duration(seconds: 3);

  /// 放弃后冷却多久才允许再次自动切换。
  static const Duration giveUpCooldown = Duration(seconds: 60);

  /// 一轮下来**一个有效样本都没测到**时的冷却，比 [CdnTuning.giveUpCooldown] 短。
  ///
  /// "测不出来"是不知道，不是"测过了没问题"，不该跟 healthy/noBetter 共用
  /// 一把锁：实测 @350s 一轮 0 样本锁了 60s，紧接着 @353 缓冲饥饿、@357
  /// 小卡顿、@362 卡顿、@363、@364 全被丢掉，而那 60 秒墙钟里画面一直是冻的
  /// （卡顿时墙钟约是视频位置的 7 倍）。
  ///
  /// 也不设成 0：卡顿触发会反复来，每次都是一整轮（3 条流 × 2MiB ≈ 6MB），
  /// 在一条连码率都喂不动的链路上按触发频率打是雪上加霜。
  static const Duration unmeasuredCooldown = Duration(seconds: 20);

  /// 小卡顿探测的节流。它比 [CdnTuning.probeInterval] 敏感得多，所以靠这个间隔
  /// 而不是靠判据来限流：两次探测之间至少隔这么久，免得一次持续抖动被拆成
  /// 十几轮测速，反而把带宽全抢走。
  static const Duration rebufferCooldown = Duration(seconds: 30);

  /// 同一个镜像隔多久允许重测。
  static const Duration retryAfter = Duration(minutes: 3);

  /// 上一轮连一个字节都没测到的镜像，隔多久才允许再进候选窗口。
  ///
  /// 和"测到了但慢"分开对待：慢是随时会变的（同一个偏移隔几分钟能差 4 倍），
  /// 所以 3 分钟重测是对的；一个字都没到多半是硬性的。实测 akamai
  /// (upos-hz-mirrorakam) 每轮都是 403、akamai_sz 每轮都是连接失败，而
  /// hw/ali/cos/tf_* 用同样的 host 改写都能正常出样本 —— 那是 Akamai 边缘不
  /// 接受在原始签名下换 host，不是网络抖。窗口只有 2 个候选位，让它每 3 分钟
  /// 占掉一位，等于整轮只剩一个候选可挑，而这正是之前修过的"候选组成"缺陷。
  static const Duration deadRetryAfter = Duration(minutes: 30);

  /// 切换后等待恢复的最长时间。
  static const Duration recoverWindow = Duration(seconds: 12);

  /// 切换后位置推进这么多即认为已恢复。
  static const Duration recoverProgress = Duration(seconds: 2);

  /// 解码错误档换源后，要求"干净"多久才认定恢复。
  ///
  /// 这一档不能用位置或余量判恢复：坏镜像的特征恰恰是余量填得满、位置还被
  /// 音频时钟推着走，两者都"看着正常"。唯一的真话是换了之后**不再吐坏字节**
  /// （[PlPlayerController.lastDecoderCorruptionAt]）。
  static const Duration decodeCleanWindow = Duration(seconds: 4);

  /// 上面那个干净窗口的宽限：换源重载期间旧流还在吐报错（解码器在消化旧字节），
  /// 这段时间的报错不算新镜像的账。
  static const Duration decodeRecoverGrace = Duration(seconds: 4);

  /// 解码错误档等待恢复的最长时间，比 [CdnTuning.recoverWindow] 长：一次重载
  /// （实测 5~10s）之后还要走完"宽限 + 干净窗口"（≈8s）才敢下结论。
  static const Duration decodeRecoverWindow = Duration(seconds: 18);

  /// 换源重载后，落点离目标多远之内算"还在原处"，不必补 seek。
  static const Duration resumeTolerance = Duration(seconds: 5);

  /// 落点检查的轮询间隔与最多补几次 seek。
  ///
  /// 8 × 800ms ≈ 6.4s 不是随手取的：重载后 duration 要过几秒才知道，而
  /// `seekTo` 在 duration 为 0 时只是挂到 `duration.listen` 上等（多次调用会互相
  /// 顶掉），所以前几次补 seek 期间位置会一直读到 0（实测连续 4 次都是 0ms）。
  /// 预算给到 6.4s，才覆盖得住"duration 到位 → 真正 seek → 落点正确"这条链。
  static const Duration resumePoll = Duration(milliseconds: 800);
  static const int resumeAttempts = 8;

  /// 后台测速的间隔。一轮真实开销是 1 基线 + 2 候选 × 2MB，但只有缓冲掉到
  /// mpv 回填水位以下时才会真的花这笔流量（见 [_onCdnProbeTick]），所以健康
  /// 播放的代价是 0。
  static const Duration probeInterval = Duration(minutes: 2);

  /// 预检的检查间隔：等缓冲补满就动手，不干等。
  static const Duration preflightPoll = Duration(seconds: 2);

  /// 预检最晚什么时候做。缓冲一直补不满（镜像本就是坏的）也要测。
  static const Duration preflightDeadline = Duration(seconds: 10);

  /// 历史速度记录多久没被刷新就重新开一个窗口。
  ///
  /// 只保留"最大值"会让一个早先的高峰永远占着冠军位子：09:00 测到 5MB/s、
  /// 之后实测只有 0.3MB/s，仍会被每轮送进候选窗口白占一个位子。所以超过这个
  /// 时间没刷新过就直接覆盖，而不是取最大值 —— 峰值会自然老去。
  static const Duration recordReset = Duration(minutes: 30);

  /// 历史速度记录超过这么久就作废，不再参与冠军评选。网络状况是随时间变的，
  /// 昨天的冠军今天未必还是。
  static const Duration recordExpiry = Duration(hours: 6);

  /// 历史冠军连着这么多轮**没能成为切换目标**，就把它从冠军位请出去，把那个
  /// 候选位让给轮换。判定与理由见 [_cdnChampionMisses] 和 [_noteChampionOutcome]。
  ///
  /// 取 2 而不是更大：误降级的代价只是"这一集少一张保留票"，而它照样能被轮换
  /// 窗口取到、照样能靠被选中重新挣回来；而漏降级的代价是每轮白少测一个镜像，
  /// 实测能连任 25 轮。宁可早点让位。
  static const int championMisses = 2;
}

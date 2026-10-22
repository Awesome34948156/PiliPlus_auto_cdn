import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/pages/video/cdn_tuning.dart';
import 'package:PiliPlus/utils/cdn_speed_test.dart';
import 'package:flutter/foundation.dart' show debugPrint;

/// 自动换源的**链路层历史账**：谁测过、谁连不上、谁给过坏字节、谁占着冠军位。
///
/// 这四本账与"这一集"无关 —— 换集、换画质都不换链路，账要跨集延续、靠时间戳
/// 自然过期（见 [_CdnSwitchState] 的 `resetEpisode` / `resetForNewObject`）。
/// 所以它们不跟页面状态挤在一起，独立成一个类。
///
/// 2026-10-22 评审 Phase 5 / 4.2 从 `_CdnSwitchState` 与 `CdnSwitchMixin` 搬出，
/// 是纯搬移：判据、阈值、顺序一行未改。
final class CdnHistoryBook {
  CdnHistoryBook({required this.readRecord, required this.writeRecord});

  /// 速度记录的读写口子。
  ///
  /// 由调用方注入而不是直接 import `Pref`：`storage_pref.dart` 反过来依赖
  /// 页面层，本文件一旦 import 它就会跟着进最大强连通分量（分层 ratchet 红）。
  /// 这两条边留在页面层里，账本本身不认识"偏好设置"。
  final List<int> Function() readRecord;
  final void Function(List<int> record) writeRecord;

  /// 测过的镜像以及测的时间。原来是永久的 Set：一个镜像测过一次，整集就
  /// 再不考虑。长时间播放里那是致命的 —— 轮换窗口一路滑下去，实测第 4 轮
  /// 只剩 aliov/hwov 两个海外节点，而真正快的国内节点早在网络还正常的时候
  /// 就被"测过"并永久拉黑，此后每次卡顿都只能在这两个最差的里面挑。CDN 的
  /// 快慢是随时间变的（同一个偏移隔几分钟实测能差 4 倍），所以改成冷却重测。
  final Map<CDNService, DateTime> triedAt = {};

  /// 上一轮一个字节都没到的候选。见 [CdnTuning.deadRetryAfter]。
  final Set<CDNService> noSample = {};

  /// 本集里给过**坏字节**的镜像 host。
  ///
  /// 和 [noSample] 的区别是正好相反的两种病：那是"一个字节都到不了"，这是
  /// "字节到得又快又好，只是解不出画面"。所以测速两种都测不出来 —— 坏镜像的
  /// 吞吐实测 2~14MB/s，比健康镜像还高。这笔账只能由解码器来记。
  ///
  /// **不记的话会来回弹**：坏镜像当基线时被强制换走，下一轮**测速**又会把它评成
  /// 最快候选（它是真的快），于是换回去、画面再冻一次。按 host 记而不是按
  /// [CDNService]：基线那个 host 是 API 分的，不一定来自枚举表，而候选一律来自
  /// 枚举表，两边对不上就没法比。
  ///
  /// 只在换集/换 P/换画质时清（[clearObjectScoped]）：换一个视频就是另一个
  /// 对象，同一条边完全可能是好的。
  final Set<String> badHosts = {};

  /// 历史冠军的"欠账"：连着多少轮**没能成为切换目标**。达到
  /// [CdnTuning.championMisses] 就不再给它留候选位。
  ///
  /// 冠军位是一张**保留票** —— 让快的镜像不必等轮换排到。但保留票的前提是
  /// "迟早能兑现"。[recordSample] 只留最大值、且只在**刷新纪录**时才续
  /// 30 分钟的时钟，于是当一条记录是靠一次突发立起来的、此后每轮实测都更慢
  /// 时，它既不更新也不作废（覆盖不了自己，也够不着 6 小时的作废线），冠军位
  /// 就被永久占住。
  ///
  /// 实测 2026-10-11 一局 25 轮：`ali（阿里云）` 连任 25/25 轮冠军，轮轮实测
  /// 0.475–0.879MB/s，而同一轮的基线有 1.7–6.1MB/s（比值 0.12–0.47，门槛 1.5）
  /// —— 一个候选位白占到底，轮换一轮只够走一个镜像。
  ///
  /// 用**结果**记这个账，而不是拿记录去比当下基线：基线每轮都在变（实测同一条
  /// 链路隔几分钟能差 4 倍），静态记录比动态读数本来就没有可靠门限；而"这一轮
  /// 它有没有被选中"是确定的事实。被选中就清零，所以降级可逆 —— 它还能从轮换
  /// 窗口里被取到，并靠被选中重新挣回冠军位（见 [noteOutcome]）。
  final Map<CDNService, int> championMisses = {};

  /// 这一轮候选都进冷却：[CdnTuning.retryAfter] 之后可以重测。
  void noteTried(Iterable<CDNService> services, DateTime at) {
    for (final service in services) {
      triedAt[service] = at;
    }
  }

  /// 测到了样本 —— 立刻解除"死镜像"嫌疑。
  void noteSample(CDNService service) {
    noSample.remove(service);
  }

  /// 一个字节都没到 —— 进"死镜像"冷却，下一轮不再占候选位。
  ///
  /// 不要拿"样本太小"去判死 —— 那是活着只是慢。
  void noteNoSample(CDNService service) {
    noSample.add(service);
  }

  /// 记一条坏字节的账。返回 true = 这条 host 是新账。
  bool noteBadHost(String? host) =>
      host != null && host.isNotEmpty && badHosts.add(host);

  bool isBadHost(String? host) => host != null && badHosts.contains(host);

  /// 冷却窗口还没过（时长取决于上一轮的样本是"慢"还是"一个字都没有"）。
  bool recentlyTried(CDNService service, DateTime now) {
    final at = triedAt[service];
    if (at == null) return false;
    final window = noSample.contains(service)
        ? CdnTuning.deadRetryAfter
        : CdnTuning.retryAfter;
    return now.difference(at) < window;
  }

  /// [service] 是不是"这一阵子连不上"：上一轮一个字节都没到，且还在
  /// [CdnTuning.deadRetryAfter] 之内。
  ///
  /// 和 [recentlyTried] 的区别是它**不看胜负、只看这一条链路**：候选池和冠军位
  /// 都用它，而不是直接查 [noSample]。只查集合的话，一旦连不上就再也轮不到它取样
  /// （它正是靠这两处跳过才进不了候选），而 [noSample] 只在**测到样本**时移除
  /// —— 于是"30 分钟后自然重试"永远不会发生，死镜像在整页生命周期里永久出局。
  /// 时刻取 [triedAt]，就是上一轮真去连它的那一刻。
  bool deadRecently(CDNService service, DateTime now) {
    if (!noSample.contains(service)) return false;
    final at = triedAt[service];
    // 没有时刻就保守当"仍连不上"：真出现了这种情况（正常路径不会），
    // 让它再等一次成功的轮次，而不是凭一条无凭据的记录回到候选池。
    if (at == null) return true;
    return now.difference(at) < CdnTuning.deadRetryAfter;
  }

  /// 记下一个镜像这一轮实测到的速度，供 [champion] 每轮把冠军送进候选窗口。
  ///
  /// 两条规则：超过 [CdnTuning.recordReset] 没刷新过就**整个覆盖**（旧窗口作废，峰值
  /// 自然老去），否则只留最大值。只留最大值而没有第一条的话，一个早先的高峰
  /// 会永远占着冠军位子：09:00 测到 5MB/s、之后实测只有 0.3MB/s，仍会被每轮
  /// 送进候选窗口白占一个位子。
  void recordSample(
    CDNService service,
    CdnSample sample,
    DateTime now, {
    bool asCandidate = false,
  }) {
    if (sample.micros <= 0) return;
    final speed = sample.bytes * 1000000 ~/ sample.micros;
    // 0 天然就是"没记录过"，所以绝不能把 0 写进去。
    if (speed <= 0) return;

    final record = readRecord();
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
      CdnTuning.recordReset,
    );
    if (stale || speed > record[at]) {
      record[at] = speed;
      record[at + 1] = now.millisecondsSinceEpoch ~/ 1000;
      changed = true;
    }
    if (changed) writeRecord(record);
  }

  /// 记录里速度最高、且**当过候选**的那个镜像，还没有超过 [CdnTuning.recordExpiry]。
  ///
  /// 冠军**不免检**：它照样每轮实测，照样要赢 [CdnTuning.starveRatio] 倍才切换。
  /// 记录只决定"优先被想到"，不决定"优先被信任"，所以记录过期或不准也不会
  /// 造成误切，只是白占一个位子。
  ///
  /// 但"只是白占一个位子"这件事本身是要还的：连着 [CdnTuning.championMisses] 轮没能
  /// 成为切换目标就不再发这张保留票，见 [championMisses]。
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
  CDNService? champion(DateTime now, String? currentHost) {
    final record = readRecord();
    CDNService? best;
    var bestSpeed = 0;
    for (final service in CdnSpeedTest.mirrors) {
      // 当前在播的已经坐在基线位置上了，再占一个候选位子等于白少测一个镜像。
      if (service.host == currentHost) continue;
      // 给过坏字节的镜像不是"快不快"的问题，历史记录里它可能正是最快的那个
      // （见 [badHosts]）。留着它等于每一轮都白占一个候选位。
      if (service.host == null || badHosts.contains(service.host)) {
        continue;
      }
      // 上一轮一个字节都没到（连接超时 / 403 / 0 样本）：这是"这条链路连不上"
      // 而不是"慢"，跟换集换对象无关。让它占着冠军位等于每轮白赔一次超时、白占
      // 一个候选位。跳过它、让位给轮换；[CdnTuning.deadRetryAfter] 之后按时刻
      // 放行重试，真出样本就自动恢复（见 `_pickFastestCdn` 里的
      // `noSample.remove`）。
      if (deadRecently(service, now)) continue;
      // 连着几轮没被选中，这张保留票它兑现不了，让给轮换。见 [championMisses]。
      if ((championMisses[service] ?? 0) >= CdnTuning.championMisses) {
        debugPrint(
          'CDN 自动切换: 历史冠军候选 ${service.desc} 已降级，本轮不发保留票 '
          '(欠账 ${championMisses[service]}/${CdnTuning.championMisses})',
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
        CdnTuning.recordExpiry,
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
  void noteOutcome({
    required CDNService? service,
    required CDNService? champion,
    required bool improved,
    required bool unmeasurable,
  }) {
    if (improved) {
      championMisses.remove(service);
    }
    if (champion == null || unmeasurable || service == champion) {
      return;
    }
    final misses = (championMisses[champion] ?? 0) + 1;
    championMisses[champion] = misses;
    debugPrint(
      misses >= CdnTuning.championMisses
          ? 'CDN 自动切换: 历史冠军 ${champion.desc} 连续 $misses 轮没能成为切换目标，'
                '退出冠军位让给轮换'
          : 'CDN 自动切换: 历史冠军 ${champion.desc} 本轮没能成为切换目标 '
                '($misses/${CdnTuning.championMisses})',
    );
  }

  /// 换集/换 P/换画质：**换了对象**。坏 host 与冠军欠账作废重来。
  ///
  /// **保留** [triedAt] / [noSample]：慢（[CdnTuning.retryAfter]）和连不上
  /// （[CdnTuning.deadRetryAfter]）是**链路层**状态，换集/换 P 不换链路，冷却
  /// 应当跨集延续、靠时间戳自然过期。否则短视频连划时每集都清空，"冠军连不上
  /// （一个字节都没到）"的账记不住，30 分钟冷却形同虚设 —— 冠军每集都白占一个
  /// 候选位、还白赔一次超时。
  void clearObjectScoped() {
    badHosts.clear();
    championMisses.clear();
  }

  /// 换源后恢复：慢的冷却清掉 —— 这一轮已经证明有得换。
  ///
  /// 但"连不上"的时刻要留着：那是 [deadRecently] 计算死镜像窗口的起点，
  /// 一起清掉就等于让它们**永久**出局（成了 noSample 却永远没有一个到期时刻）。
  void forgetSlowCooldowns() {
    triedAt.removeWhere((service, _) => !noSample.contains(service));
  }

  /// 测试用：把某个镜像"上次测过"的时刻往回拨。
  void backdate(CDNService service, DateTime at) {
    triedAt[service] = at;
  }
}

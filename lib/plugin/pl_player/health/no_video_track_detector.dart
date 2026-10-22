import 'package:PiliPlus/plugin/pl_player/player_tuning.dart';

/// 一次采样的判决。
enum NoVideoVerdict {
  /// 还没攒满窗口、或刚被复位：什么都别做。
  none,

  /// 攒满长窗（[PlayerTuning.noVideoWindowWeak]）：强指纹不成立，照旧定罪。
  weak,

  /// 攒满短窗（[PlayerTuning.noVideoWindow]）：强指纹成立 + 位置在推进。
  strong,
}

/// 「闸门全开 + 画面为空」的时间窗状态机。
///
/// 只做窗口的开关与攒窗，不碰播放器、不打日志、不做动作 —— 八道闸的求值、
/// 强指纹怎么算、定罪之后干什么，全部由调用方负责。所以它没有宿主接口，
/// 也不 import `controller.dart`（分层闸门要求 health/ 不成环）。
///
/// 2026-10-22 评审 Phase 5 / S2 从 `PlPlayerController` 整块搬出。
final class NoVideoTrackDetector {
  /// 「闸门全开 + 画面为空」这段状态的起点；null = 没有正在累积的窗口。
  ///
  /// 每一个调用方把旧计数清零的返回点，现在都改成调 [reset] 或
  /// [clearWindowStart]。**一处都不能漏** —— 漏了窗口就会跨装载存活，
  /// 新装载第一拍就定罪。
  DateTime? _windowStart;

  /// 上一拍时的播放位置，给"强指纹"加一条"位置真的在推进"的保险。
  ///
  /// 位置冻住**不关窗**，只是让强指纹不成立 ⇒ 这次定罪自动落到长窗那一档。
  /// 别改成"冻住就关窗"：位置冻住 + 不在缓冲正是卡顿看门狗抓不到的盲区，
  /// 那样会静默地收窄这张网。
  int _lastPosition = 0;

  DateTime? get windowStart => _windowStart;

  /// 关掉正在累积的窗口，连上一拍的位置一起忘掉。
  ///
  /// 任何一道门成立、或画面起来了，都必须调它。
  void reset() {
    _windowStart = null;
    _lastPosition = 0;
  }

  /// 只关窗、留着上一拍的位置。
  ///
  /// 供渲染上下文重建流程里那两个散点用（拆旧之后、`finally` 里）：那里原本
  /// 就只写 `_noVideoWindowStart = null`。语义上 [reset] 在这里也等价 ——
  /// 窗口没开时下一拍会先写位置再返回，旧值读不到 —— 但保持与旧代码逐字对应，
  /// 将来给 [reset] 加东西时不会顺手改了重建路径的行为。
  void clearWindowStart() {
    _windowStart = null;
  }

  /// 采一拍。
  ///
  /// - [shouldReset]：八道闸任一成立、或画面已经起来（由调用方短路求值，
  ///   顺序与旧代码一致）。
  /// - [strongFingerprint]：惰性求值，只在窗口已经开着的那一拍才调用 ——
  ///   旧代码就是这样，它要读两个 mpv 属性，别在闸门关着时白读。
  ///
  /// 返回 [NoVideoVerdict.none] 表示"这一拍什么都不用做"；返回另外两档时
  /// 窗口已经重新打开，下一次定罪要再攒满一个窗口。
  NoVideoVerdict sample({
    required DateTime now,
    required int positionSecs,
    required bool shouldReset,
    required bool Function() strongFingerprint,
  }) {
    if (shouldReset) {
      reset();
      return NoVideoVerdict.none;
    }
    final start = _windowStart;
    if (start == null) {
      // 开窗那一拍不定罪：这一拍之前画面空了多久是无从知道的（最多一拍），
      // 拿它当账去凑窗口就是白送。
      _windowStart = now;
      _lastPosition = positionSecs;
      return NoVideoVerdict.none;
    }
    // 强指纹每拍重算（不跨拍记忆），再叠一条"位置真的比上一拍大"做双保险。
    // 指纹不成立（含位置冻住）就走长窗那一档。
    final strong = strongFingerprint() && positionSecs > _lastPosition;
    _lastPosition = positionSecs;
    if (now.difference(start) <
        (strong
            ? PlayerTuning.noVideoWindow
            : PlayerTuning.noVideoWindowWeak)) {
      return NoVideoVerdict.none;
    }
    // 重新开窗：下一次定罪要再攒满一个窗口。额度用尽之后就靠这个节奏在日志里
    // 留痕（每窗一行）。**这里不需要"距上次重建至少隔多久"的冷却** —— 窗口长度
    // 本身就是那个冷却，理由见 [PlayerTuning.noVideoWindow]。
    _windowStart = now;
    return strong ? NoVideoVerdict.strong : NoVideoVerdict.weak;
  }
}

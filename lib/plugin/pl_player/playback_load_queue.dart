import 'dart:async';

/// 播放器装载队列：串行执行 native 装载，并让最后一次请求获胜。
///
/// 只合并 `Player` 创建还不够：两个 `setDataSource` 仍可能 concurrently 走到
/// `open()` / `replaceSingle()`，后完成的旧请求会覆盖新视频。这里把完整装载事务
/// 排成一条队；新请求入队时同步推进代际，正在执行的旧请求通过 [isCurrent]
/// 在下一个 `await` 后止损。
///
/// `busy` 在请求入队时立刻为真，直到该请求真正离开队列才变假，因此不会出现
/// “第一个请求先结束、第二个仍在跑，却短暂报告 processing=false”的窗口。
final class PlaybackLoadQueue {
  int _generation = 0;
  int _active = 0;
  Future<void> _tail = Future.value();

  bool get busy => _active > 0;

  /// [body] 只在轮到它且仍是最新请求时执行。
  ///
  /// 队列槽即使在 [body] 抛异常时也会释放；异常只回给当前调用方，不会毒化
  /// 后面的请求。
  Future<void> run(
    Future<void> Function(bool Function() isCurrent) body,
  ) async {
    final generation = ++_generation;
    _active++;
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    try {
      await previous;
      if (generation != _generation) return;
      await body(() => generation == _generation);
    } finally {
      _active--;
      done.complete();
    }
  }
}

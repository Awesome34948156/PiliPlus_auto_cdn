/// "这次装载该从哪一秒起播"的推导 —— 从 `VideoDetailController.playerInit`
/// 里抠出来的**纯函数**，唯一目的是让这条推导进得了自动化测试（`playerInit`
/// 本体第一句就是 `Player.create`，要 libmpv，测试进程里跑不动）。
///
/// 背景（真机 log 14）：P3 的「就地重建渲染上下文」会把续播点丢掉 —— 三次重建里
/// 只有第一次的新 player 带了 `Setting option 'start'`，第二次从 1237s 掉到 763s
/// （**倒退 474 秒**），第三次从 29s 掉到 0。
///
/// **为什么原推导在重建这条路上推不出来**（核过代码的那一半）：重建的前提是"这个
/// 媒体已经成功装载过一次"，而每次成功装载的收尾都 `defaultST = null;`
/// （`pages/video/controller.dart:814`，`playerInit` 的最后一行）—— 此后还能写它的
/// 只有换集/换画质（`_queryVideoUrl`）与 `onReset`，重建路一个都不触发。**所以重建
/// 那一刻 `defaultST` 恒为 null，落点全由 `playedTime` 决定**，而它并不是个可靠的
/// 载体：位置流**无条件**写它（`view.dart` 的 `positionListener`），新装载开头那个
/// 0 位置事件、以及位置流本身的停摆都会让它变成 0 或停在旧值。重建的发起方（播放器）
/// 手里明明还攥着位置（`position.value`，拆之前就冻住），却让页面重新推导一遍。
/// ⚠️ 第二次那 763s 的**具体来历未证实**（它是落点纠正 `_restoreResumePosition` 连打
/// 8 发之后的落点，不是新 player 的初始 `start`）—— 别把它当成某条机制的铁证。
///
/// 所以加了显式来源 [resumeAt]：由重建发起方在**拆之前**捕获
/// （`_runRenderContextRebuild` 先 `_removeListeners()`，写 `position` 的那条订阅
/// 随之取消 → `position.value` 冻在拆之前最后一拍），优先级最高。
library;

/// 解析本次装载的起播点。优先级：`resumeAt` > `defaultST` > `playedTime`。
///
/// **零值一律等于"没有续播意图"**（返回 null）—— 调用方接着会问 sponsor block 的
/// `getFirstSegment()`，也就是"从 0 起播时仍允许跳片头"。
///
/// ⚠️ [resumeAt] **不许**写成 `resumeAt ?? defaultST ?? playedTime`：`??` 只看
/// null，而 `Duration.zero` 是**非空**的。播放头落在第一秒内时它天然就是 0
/// （`PlPlayerController.position` 是整秒 `RxInt`），那样会把 `defaultST` /
/// `playedTime` 里本来有效的那份一起盖掉 —— 续播点反而丢得更彻底。判据必须落到
/// **值**上（`> Duration.zero`），不是落到 null 上。`defaultST` 真的会是零：本地
/// 文件播完、`progress == 0`、服务端 `lastPlayTime == 0` 这几处都显式赋
/// `Duration.zero`（见 `pages/video/controller.dart` 里它的各个写点）。
///
/// [resumeAt] 判负：`> Duration.zero` 是**值**判据，负值同样算"没捕获到"。真机
/// 到不了（`position.value` 是整秒非负），留着是给这条设计一个哨兵
/// （变异测试发现"`>` 改成 `!=`"曾无人约束）。而 `defaultST` / `playedTime`
/// **不在此列**：负值不在它们的契约内，本函数不做归一（旧那句内联式也只归一零），
/// 那是"不传 resumeAt 时逐位等价"这条不变量的一部分。
///
/// [resumeAt] 为 null 时，本函数与原先那句内联的 `defaultST ?? playedTime`
/// 加 `if (seek == .zero) seek = null` **逐位等价**（测试里有一条专门钉这个不变量的
/// 用例）—— 不传就是零回归。
///
/// 精度提醒：[resumeAt] 的实际来源是整秒的 `position.value`，比 `refreshPlayer`
/// 的 `media.copyWith(start:)` 与换源路的 `state.position` 粗（那两条是毫秒级）。
/// 换来的好处是"拆之后这下仍然读得到"：更准的那份是页面级的 `playedTime`（毫秒），
/// 但它**不可靠** —— 见上文，它会被钉成 0 或停在旧值。读秒级的 `position.value`
/// 是拿精度换可靠性。黑屏重建后差不到 1 秒，不可感知。
///
/// **已知救不了的一次**：同一轮里的**第 2 次**重建（`_kNoVideoRebuildMax = 2`）。
/// 那时读到的 `position.value` 已经是第 1 次重建那轮新装载的值 —— 若它已被新一轮
/// 开头那个 0 位置事件推翻，`resumeAt` 就是 0，本函数按"没捕获到"回落，那一次照旧
/// 丢点。真机 log 13 的 17:43 段里第 2/2 次反而带上了 `start='286.000'`（说明不是
/// 必然丢）—— 验收时**别把第 2 次的失败算到这次修复头上**。
Duration? resolveResumeSeek({
  Duration? resumeAt,
  Duration? defaultST,
  Duration? playedTime,
}) {
  // 零值不算数：非空但为 0 的 resumeAt 视为"没捕获到"，回落既有推导。
  final explicit =
      (resumeAt != null && resumeAt > Duration.zero) ? resumeAt : null;
  final seek = explicit ?? defaultST ?? playedTime;
  // `Duration` 的 `==` 是按值（microseconds）比较的，所以 `.zero` 这个等号是准的。
  return seek == Duration.zero ? null : seek;
}

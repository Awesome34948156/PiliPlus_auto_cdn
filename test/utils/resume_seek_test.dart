import 'package:PiliPlus/utils/resume_seek.dart';
import 'package:flutter_test/flutter_test.dart';

/// `resolveResumeSeek` 的真值表 —— 这是 P3「就地重建丢续播点」那条修复里
/// **唯一**进得了自动化测试的一片。
///
/// 为什么不测端到端：`playerInit` 本体第一句就是 `setDataSource` → `Player.create`
/// （libmpv），测试进程里 `_videoPlayerController` 恒 null；重建那道门更是要求真的
/// 拆掉一个 Player，见 `test/pages/cdn_switch_mixin_test.dart` 里 P3 group 头上的
/// 盲区声明。所以**测得到的只有这条推导**：`view.dart` 里"在拆之前捕获 `position.value`"
/// 与"重建后真的从续播点起播"两项**只能真机验**（判据：重建那几次的新 player 有没有
/// `Setting option 'start'`）。
///
/// 真机现场（log 14，2026-10-12）：三次重建里只有第一次带了 `start`，第二次从
/// 1237s 掉到 763s（**倒退 474 秒**）、第三次从 29s 掉到 0。
void main() {
  group('续播点推导', () {
    test('resumeAt 是唯一来源时也认（log 14 三次重建的现场）', () {
      // 重建时 defaultST 早被 playerInit 收尾清空（controller.dart:814），
      // 页面这一世也可能从没收到过位置回调 —— 两个回落来源都是 null。
      expect(
        resolveResumeSeek(
          resumeAt: const Duration(seconds: 1237),
          defaultST: null,
          playedTime: null,
        ),
        const Duration(seconds: 1237),
        reason: '不带 resumeAt 时这里会返回 null → 从 0 起播，就是 log 14 那 474 秒',
      );
    });

    test('零值不算数：resumeAt 为 0 不许盖掉 defaultST 里有效的那份', () {
      // 🔴 这就是"别写成 `resumeAt ?? defaultST ?? playedTime`"那条警告。
      // `??` 只看 null，而 Duration.zero 是非空值；position 是整秒 RxInt，
      // 播放头落在第一秒内时它天然就是 0。
      // 红证：把 resume_seek.dart 里的判据从 `resumeAt > Duration.zero` 改回
      // `resumeAt != null`，本用例立刻变红（返回 null 而不是 300s）。
      expect(
        resolveResumeSeek(
          resumeAt: Duration.zero,
          defaultST: const Duration(seconds: 300),
          playedTime: const Duration(seconds: 200),
        ),
        const Duration(seconds: 300),
        reason: 'resumeAt=0 该被当成"没捕获到"，回落 defaultST，而不是把续播点推成 null',
      );
    });

    test('零值/负值都不算数，且零值要能一路落到 playedTime', () {
      // 第二格是变异测试捞出来的：原用例只喂了 `resumeAt == Duration.zero`
      // （`!= Duration.zero` 与 `> Duration.zero` 在那一格上都判 false），
      // 于是"判据落在值上而不是落在 null 上"这句话**没有被任何用例约束** ——
      // 把判据改成 `resumeAt != Duration.zero` 时 5 条全绿。负值这一格是唯一
      // 能杀掉那个变异的地方（实测：改掉即红，Actual = -0:00:00.001）。
      // ⚠️ 这一格在真机上到不了（`position.value` 是整秒非负），留着是给
      // "判据必须落在值上"这条设计留个哨兵。
      expect(
        resolveResumeSeek(
          resumeAt: const Duration(milliseconds: -1),
          defaultST: const Duration(seconds: 300),
          playedTime: const Duration(seconds: 200),
        ),
        const Duration(seconds: 300),
        reason: '负值也是"没捕获到"，不许当成合法的续播点原样返回',
      );
      expect(
        resolveResumeSeek(
          resumeAt: Duration.zero,
          defaultST: null,
          playedTime: const Duration(seconds: 200),
        ),
        const Duration(seconds: 200),
        reason: '零值回落要一路落到 playedTime（上一条只验了 defaultST 那一档）',
      );
    });

    test('resumeAt 的优先级是绝对的，不按数值大小', () {
      expect(
        resolveResumeSeek(
          resumeAt: const Duration(seconds: 100),
          defaultST: const Duration(seconds: 300),
          playedTime: const Duration(seconds: 200),
        ),
        const Duration(seconds: 100),
        reason: '比 defaultST 小也得听它的 —— 否则等于又回到了"谁大听谁"的推导',
      );
    });

    test('优先级：resumeAt > defaultST > playedTime', () {
      expect(
        resolveResumeSeek(
          resumeAt: const Duration(seconds: 474),
          defaultST: const Duration(seconds: 300),
          playedTime: const Duration(seconds: 200),
        ),
        const Duration(seconds: 474),
      );
      expect(
        resolveResumeSeek(
          defaultST: const Duration(seconds: 300),
          playedTime: const Duration(seconds: 200),
        ),
        const Duration(seconds: 300),
        reason: '旧行为：defaultST 压过 playedTime',
      );
      expect(
        resolveResumeSeek(playedTime: const Duration(seconds: 200)),
        const Duration(seconds: 200),
      );
    });

    test('非零值原样透传，不截断不改值', () {
      expect(
        resolveResumeSeek(resumeAt: const Duration(milliseconds: 898880)),
        const Duration(milliseconds: 898880),
        reason: '截成整秒是调用方（view.dart 传 seconds）的事，推导本身不碰数值',
      );
    });

    test('不传 resumeAt 时逐位等于改造前那句内联推导', () {
      // 改造前（controller.dart，改造前 747-748 行）：
      //   Duration? seek = defaultST ?? playedTime;
      //   if (seek == .zero) seek = null;
      // 这条不变量是"提取未改行为"的护栏 —— 只要它绿，九个既有调用点（都不传
      // resumeAt）就是零回归。红证：让函数在 resumeAt 为 null 时多走一步
      // （例如把 explicit 写成 `resumeAt ?? Duration.zero`），本用例即红。
      Duration? oldWay(Duration? defaultST, Duration? playedTime) {
        var seek = defaultST ?? playedTime;
        if (seek == Duration.zero) seek = null;
        return seek;
      }

      const cases = <(Duration?, Duration?)>[
        (null, null),
        (Duration.zero, null),
        (null, Duration.zero),
        (Duration.zero, Duration.zero),
        (Duration(seconds: 300), null),
        (null, Duration(seconds: 200)),
        (Duration(seconds: 300), Duration(seconds: 200)),
      ];
      for (final (defaultST, playedTime) in cases) {
        expect(
          resolveResumeSeek(defaultST: defaultST, playedTime: playedTime),
          oldWay(defaultST, playedTime),
          reason: 'defaultST=$defaultST playedTime=$playedTime 这一格与旧式不一致',
        );
      }
    });
  });
}

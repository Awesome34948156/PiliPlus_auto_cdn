import 'package:PiliPlus/plugin/pl_player/health/decode_ledger.dart';
import 'package:PiliPlus/plugin/pl_player/player_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

/// 全部门都放开的宿主；每条用例只改它关心的那几项。
///
/// 这些闸门在真机上都是 `PlPlayerController` 的实时读数，账本刻意不缓存
/// （见 [DecodeLedgerHost]），所以这里也用可变字段模拟"下一拍就变了"。
class _FakeHost implements DecodeLedgerHost {
  @override
  Duration reportPosition = Duration.zero;
  @override
  bool isSeeking = false;
  @override
  bool processing = false;
  @override
  bool onlyPlayAudio = false;
  @override
  bool isBuffering = false;
  @override
  int bufferedAhead = 28;
  @override
  bool hasVideoTrack = true;
  @override
  bool appInBackground = false;
  @override
  bool isLive = false;
  @override
  DateTime? backgroundEnteredAt;
  @override
  DateTime? backgroundExitedAt;
  @override
  bool pipActive = false;

  int reportCount = 0;
  int refreshCount = 0;
  int remountCount = 0;

  @override
  bool reportDecodeError(Duration at) {
    reportCount++;
    return true;
  }

  @override
  void refreshMedia() => refreshCount++;

  @override
  void remountVideoTrack() => remountCount++;
}

/// 会话族种子：`invalid session` 是实测里 VideoToolbox 作废时的原话。
const _seed = 'av1: Failed to decode frame (invalid session, -12903)';

/// 回前台续播窗口里那族（`sampleCorruption` 认的续解签名）。
const _continuation = 'Missing Sequence Header';

void main() {
  final t0 = DateTime(2026, 10, 22, 13, 0, 0);

  /// 一拍一条，间隔 10ms（大于 [PlayerTuning.decodeLineDedupe]），连喂 [count] 条。
  void feed(
    DecodeLedger ledger,
    String line, {
    required int count,
    DateTime? from,
    bool corruption = true,
  }) {
    final start = from ?? t0;
    for (var i = 0; i < count; i++) {
      final at = start.add(Duration(milliseconds: 10 * i));
      if (corruption) {
        ledger.sampleCorruption(line, at: at);
      } else {
        ledger.sampleSession(line, at: at);
      }
    }
  }

  group('回前台续播：后台 / 装载在途时不动手，也不烧冷却（评审 §2.4）', () {
    test('已经在后台：只记账，不重建', () {
      final host = _FakeHost()..appInBackground = true;
      final ledger = DecodeLedger(host)..noteForegroundResumeAt(t0);
      feed(
        ledger,
        _continuation,
        count: PlayerTuning.sessionFailBurst,
      );
      expect(host.refreshCount, 0);
    });

    test('被后台挡下的那些不烧 30 秒冷却：回前台的下一条立刻能动手', () {
      final host = _FakeHost()..appInBackground = true;
      final ledger = DecodeLedger(host)..noteForegroundResumeAt(t0);
      feed(ledger, _continuation, count: PlayerTuning.sessionFailBurst);
      expect(host.refreshCount, 0);

      host.appInBackground = false;
      feed(
        ledger,
        _continuation,
        count: 1,
        from: t0.add(const Duration(milliseconds: 200)),
      );
      expect(host.refreshCount, 1, reason: '冷却没被白烧，这一条就该救');
    });

    test('装载在途（processing）：只记账，不重建，也不烧冷却', () {
      final host = _FakeHost()..processing = true;
      final ledger = DecodeLedger(host)..noteForegroundResumeAt(t0);
      feed(ledger, _continuation, count: PlayerTuning.sessionFailBurst);
      expect(host.refreshCount, 0);

      host.processing = false;
      feed(
        ledger,
        _continuation,
        count: 1,
        from: t0.add(const Duration(milliseconds: 200)),
      );
      expect(host.refreshCount, 1);
    });

    test('都不挡时照旧重建（上面几条的否定不是空的）', () {
      final host = _FakeHost();
      final ledger = DecodeLedger(host)..noteForegroundResumeAt(t0);
      feed(ledger, _continuation, count: PlayerTuning.sessionFailBurst);
      expect(host.refreshCount, 1);
    });
  });

  group('后台推迟重建：直播不推迟（评审 §2.7）', () {
    void enterBackground(_FakeHost host) {
      host
        ..backgroundEnteredAt = t0
        ..appInBackground = true;
    }

    test('直播：不推迟 —— 回前台那一下 vid=no → auto 在直播上是"跳到最新"', () {
      final host = _FakeHost()..isLive = true;
      enterBackground(host);
      final ledger = DecodeLedger(host);
      feed(
        ledger,
        _seed,
        count: PlayerTuning.sessionFailBurst,
        corruption: false,
      );
      expect(ledger.deferredRebuild, isFalse);
      expect(host.remountCount, 0);
    });

    test('点播：推迟到回前台再重建', () {
      final host = _FakeHost();
      enterBackground(host);
      final ledger = DecodeLedger(host);
      feed(
        ledger,
        _seed,
        count: PlayerTuning.sessionFailBurst,
        corruption: false,
      );
      expect(ledger.deferredRebuild, isTrue);
      expect(host.remountCount, 0, reason: '推迟的意思是这一拍什么都不做');
    });
  });

  group('画中画在显示时让位（评审 §2.3）', () {
    test('回前台过渡窗里 PiP 小窗在显示：不重挂视频轨', () {
      final host = _FakeHost()
        ..backgroundEnteredAt = t0.subtract(const Duration(seconds: 30))
        ..backgroundExitedAt = t0
        ..pipActive = true;
      final ledger = DecodeLedger(host);
      feed(
        ledger,
        _seed,
        count: PlayerTuning.sessionFailBurst,
        corruption: false,
      );
      expect(host.remountCount, 0);
      expect(host.refreshCount, 0);
    });

    test('同一个窗里小窗没在显示：只重挂视频轨（比刷新 Media 便宜）', () {
      final host = _FakeHost()
        ..backgroundEnteredAt = t0.subtract(const Duration(seconds: 30))
        ..backgroundExitedAt = t0;
      final ledger = DecodeLedger(host);
      feed(
        ledger,
        _seed,
        count: PlayerTuning.sessionFailBurst,
        corruption: false,
      );
      expect(host.remountCount, 1);
      expect(host.refreshCount, 0);
    });
  });
}

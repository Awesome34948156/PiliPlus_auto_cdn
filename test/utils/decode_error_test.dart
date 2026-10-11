import 'package:PiliPlus/utils/decode_error.dart';
import 'package:flutter_test/flutter_test.dart';

/// 判定用的样本全部是**逐字抄下来的实测日志行**（2026-10-11 从 iPhone 上取回的
/// `pili-console.log`），不是编的：AV1 那一族来自那次 400+ 条的刷屏，H.264 的
/// 两条来自同一份日志里换集边界上的零星报错，下面的反例来自同一份日志里那些
/// **不该**触发换源的行。
void main() {
  group('isDecoderCorruptionLog 认得坏字节', () {
    test('the AV1 storm that froze the picture', () {
      const lines = [
        'av1: obu_forbidden_bit out of range: 1, but must be in [0,0].',
        'av1: Failed to read packet.',
        'av1: Invalid leb128 at obu_size: bitstream ended.',
        // 硬解放弃之后的软解回退，同一份数据换了个解码器照样报。
        'libdav1d: Error parsing OBU data',
        'libdav1d: Overrun in OBU bit buffer',
        'libdav1d: Unknown OBU type 13 of size 124',
        'libdav1d: Error parsing sequence header',
        'libdav1d: Unknown Metadata OBU type 1824451',
        // 还没绑上解码器的那几行，前缀是光秃秃的 `NULL:`。
        'NULL: Failed to parse temporal unit.',
        'NULL: extension_header_reserved_3bits out of range: 4, but must be in [0,0].',
        'NULL: obu_reserved_1bit out of range: 1, but must be in [0,0].',
      ];
      for (final line in lines) {
        expect(isDecoderCorruptionLog(line), isTrue, reason: line);
      }
    });

    test('the stray errors at a stream boundary', () {
      // 换集/seek 边界上单个损坏的 GOP。它们只值一两条，凑不满风暴门槛，
      // 但必须被认出来 —— 否则一条长期播放里迟早攒够。
      expect(isDecoderCorruptionLog('Invalid NAL unit size (34817 > 5117).'), isTrue);
      expect(
        isDecoderCorruptionLog('missing picture in access unit with size 5121'),
        isTrue,
      );
    });

    test('大小写无关：mpv/ffmpeg 的输出大小写并不稳定', () {
      // 签名是从某一次实测日志逐字抄下来的，对方改一次大小写，区分大小写的
      // 匹配就静默失效 —— 在 release 里没有任何提示。
      const lines = [
        'av1: OBU_Forbidden_Bit Out Of Range: 1, but must be in [0,0].',
        'libdav1d: error PARSING obu DATA',
        'NULL: fAILED to READ Packet.',
        'INVALID NAL UNIT SIZE (34817 > 5117).',
        'MISSING PICTURE IN ACCESS UNIT with size 5121',
      ];
      for (final line in lines) {
        expect(isDecoderCorruptionLog(line), isTrue, reason: line);
      }
    });
  });

  group('不该认的', () {
    test('network failures are "did not arrive", not "cannot be decoded"', () {
      // 这些是"没喂到"，另有 stream.error 那条恢复路径管；算进风暴会让一次
      // 普通网络抖动触发换源。
      const lines = [
        'tcp: ffurl_read returned 0xdfb9b0bb',
        'Stream ends prematurely at 0, should be 543447102',
        "Failed to open https://upos-sz-mirrorhw.bilivideo.com/upgcxcode/x",
        "Can not open external file https://upos-sz-mirrorcosov.bilivideo.com/x",
        'https: Error reading HTTP response: Input/output error',
        'tls: Error decoding the received TLS packet.',
      ];
      for (final line in lines) {
        expect(isDecoderCorruptionLog(line), isFalse, reason: line);
      }
    });

    test('unrelated player errors are untouched', () {
      const lines = [
        // 这一条在同一份日志里出现过两次，都跟字节无关。
        'Vulkan: Unable to open the libvulkan library!',
        "EDL: Could not open source file 'https://upos-sz-mirrorhw.bilivideo.com/x'",
        'stream 0, offset 0x9b0962: partial file',
        // 应用自己的那几行。它们和 mpv 走同一个日志文件。
        'CDN 自动切换: 判定 最快候选 hw（华为云，融合CDN） 2.94MB/s / 基线 2.04MB/s = 1.44x (阈值 1.5) -> 不切换',
        '',
      ];
      for (final line in lines) {
        expect(isDecoderCorruptionLog(line), isFalse, reason: line);
      }
    });
  });

  test('matching is on substrings, so the level/prefix wrapper cannot hide it', () {
    // 实际送进来的是 `log.text`（没有 `mpv [error] ffmpeg/video: ` 前缀），
    // 但前缀本来就没有区分度：同一个故障在三层上报时前缀各不相同。
    expect(
      isDecoderCorruptionLog(
        'mpv [error] ffmpeg/video: libdav1d: Error parsing OBU data',
      ),
      isTrue,
    );
  });

  group('isDecoderSessionFailureLog 认得本机硬解会话废了', () {
    test('2026-10-11 那一局：退后台 6 分钟，回前台 0.881 秒刷了 78 行', () {
      // 逐字抄自 iPhone 上取回的 pili-console.log（行 599–676）。这一族和坏字节
      // 那族**症状完全相同、该做的事相反**：字节是好的，换源治不了，只能重建
      // 本机解码器。所以它必须是**独立**的判据，不能并进上面那张签名表。
      const lines = [
        'av1: Failed to decode frame (invalid session, -12903)',
        'av1: vt decoder cb: output image buffer is null: -12909, reconfig 1',
      ];
      for (final line in lines) {
        expect(isDecoderSessionFailureLog(line), isTrue, reason: line);
      }
    });

    test('大小写无关：mpv/ffmpeg 的输出大小写并不稳定', () {
      const lines = [
        'av1: FAILED TO DECODE FRAME (INVALID SESSION, -12903)',
        'AV1: VT DECODER CB: OUTPUT IMAGE BUFFER IS NULL: -12909, RECONFIG 1',
      ];
      for (final line in lines) {
        expect(isDecoderSessionFailureLog(line), isTrue, reason: line);
      }
    });
  });

  group('会话失效不该认的', () {
    test('坏字节那一族的行，一条都不算会话失效', () {
      // 收进来就会在**真正的坏字节风暴**里（那一族本该命中 400+ 条并换源）把动作
      // 从"换源"改成"重建解码器" —— 治错了病。
      const lines = [
        'av1: obu_forbidden_bit out of range: 1, but must be in [0,0].',
        'libdav1d: Error parsing OBU data',
        'Invalid NAL unit size (34817 > 5117).',
        'missing picture in access unit with size 5121',
      ];
      for (final line in lines) {
        expect(isDecoderSessionFailureLog(line), isFalse, reason: line);
      }
    });

    test('通用症状不收 —— 坏字节时也刷，5484 那次我们自己重载弄出的 92 条正是它们', () {
      // 这两条和上面那两条在**同一场**风暴里成对出现（实测各 ×26）。只认会话层
      // 那两条，是为了保证"坏字节 → 换源"这条路不被抢走动作。
      const lines = [
        'vd: Error while decoding frame (hardware decoding)!',
        'av1: HW accel end frame fail.',
      ];
      for (final line in lines) {
        expect(isDecoderSessionFailureLog(line), isFalse, reason: line);
      }
    });

    test('网络族的行也不算', () {
      const lines = [
        'tls: IO error: Socket is not connected',
        'ffmpeg: https: Will reconnect at 366404 in 0 second(s), '
            'error=Socket is not connected.',
        'Stream ends prematurely at 0, should be 543447102',
      ];
      for (final line in lines) {
        expect(isDecoderSessionFailureLog(line), isFalse, reason: line);
      }
    });

    test('两族的判据互不重叠（同一条日志不可能两边都算）', () {
      // 这两族被两个采样器分别喂进去，动作相反（换源 vs 重建本机解码器）。
      // 有交叠就会出现"一边换源一边重建"，两个动作互相拆台。
      const lines = [
        'av1: Failed to decode frame (invalid session, -12903)',
        'av1: vt decoder cb: output image buffer is null: -12909, reconfig 1',
        'av1: obu_forbidden_bit out of range: 1, but must be in [0,0].',
        'libdav1d: Error parsing OBU data',
        'Invalid NAL unit size (34817 > 5117).',
        'missing picture in access unit with size 5121',
      ];
      for (final line in lines) {
        expect(
          isDecoderSessionFailureLog(line) && isDecoderCorruptionLog(line),
          isFalse,
          reason: line,
        );
      }
    });
  });

  group('recordDecodeErrorHit 攒风暴', () {
    // 播放器那边用的就是这三个数（PlPlayerController）。
    const window = Duration(seconds: 6);
    const burst = 12;
    const dedupe = Duration(milliseconds: 5);
    final t0 = DateTime(2026, 10, 11, 12);

    bool hit(List<DateTime> hits, DateTime now) => recordDecodeErrorHit(
      hits,
      now,
      window: window,
      burst: burst,
      lineDedupe: dedupe,
    );

    test('the 12th line inside the window is the one that fires', () {
      // 门槛卡在"一两条就停的偶发报错"和"400+ 条的刷屏"之间。
      final hits = <DateTime>[];
      for (var i = 0; i < 11; i++) {
        expect(
          hit(hits, t0.add(Duration(milliseconds: 100 * i))),
          isFalse,
          reason: '第 ${i + 1} 条不该触发',
        );
      }
      expect(hit(hits, t0.add(const Duration(milliseconds: 1100))), isTrue);
    });

    test('one bad packet reported by three ffmpeg layers counts once', () {
      // 实测：同一个坏包在 `av1:` / `libdav1d:` / `NULL:` 上各记一行，相隔不到
      // 5ms。不合并的话 12 条的门槛只等于 4 个坏包。
      final hits = <DateTime>[];
      hit(hits, t0);
      hit(hits, t0.add(const Duration(milliseconds: 1)));
      hit(hits, t0.add(const Duration(milliseconds: 3)));
      expect(hits.length, 1);

      // 过了去重窗就是**另一个**包。
      hit(hits, t0.add(const Duration(milliseconds: 6)));
      expect(hits.length, 2);
    });

    test('hits older than the window are evicted, so a slow trickle never fires', () {
      // 判据是"6 秒内 12 条"，不是"累计 12 条"：一次长时间播放里的零星报错
      // 不该攒成一场风暴。
      final hits = <DateTime>[];
      // 11 条挤在 1.1 秒里 —— 窗口是 6 秒，所以它们都还在窗内。
      for (var i = 0; i < 11; i++) {
        hit(hits, t0.add(Duration(milliseconds: 100 * i)));
      }
      expect(hits.length, 11);

      // 隔了将近 17 秒 —— 前 11 条全部出窗，只剩这一条，离门槛还远。
      expect(hit(hits, t0.add(const Duration(seconds: 18))), isFalse);
      expect(hits.length, 1);
    });

    test('a hit exactly at the window edge still counts', () {
      // 淘汰用严格 `>`：正好 6 秒前的那条还算数，边界上不抖。
      final hits = <DateTime>[];
      hit(hits, t0);
      hit(hits, t0.add(window));
      expect(hits.length, 2);
    });

    test('reaching the burst does not clear the window', () {
      // 清空是调用方的事（真的上报之后才清）：静默期内攒下的这批必须留着，
      // 静默期一过立刻兑现，而不是从头再攒。
      final hits = <DateTime>[];
      for (var i = 0; i < 12; i++) {
        hit(hits, t0.add(Duration(milliseconds: 100 * i)));
      }
      expect(hits.length, 12);
    });

    test('会话失效那一档用的是 6 条 / 3 秒，不是 12 条 / 6 秒', () {
      // 两个采样器共用这个纯函数，只是传进来的窗口和门槛不同（会话失效那一档见
      // PlPlayerController._kSessionFailBurst / _kSessionFailWindow）。实测那一场
      // 是 0.881 秒 26 条，6 条 / 3 秒有 4 倍余量 —— 而单条 `invalid session`
      // 在 seek / 拆链的缝隙里也会冒出来，所以门槛不能低到一条就动手。
      final hits = <DateTime>[];
      bool hit(DateTime now) => recordDecodeErrorHit(
        hits,
        now,
        window: const Duration(seconds: 3),
        burst: 6,
        lineDedupe: dedupe,
      );
      for (var i = 0; i < 5; i++) {
        expect(hit(t0.add(Duration(milliseconds: 30 * i))), isFalse,
            reason: '第 ${i + 1} 条不该触发');
      }
      expect(hit(t0.add(const Duration(milliseconds: 150))), isTrue);
    });

    test('a backwards clock step does not silence the criterion', () {
      // NTP 校正把时钟往回拨之后，hits.last 落在"未来"：差值成负数、去重分支会
      // 把此后**每一条**都当成同一个坏包的副本吞掉，而淘汰条件对未来时刻也不
      // 成立 —— 那条记录永远清不掉，判据整个 session 静默失效。这里要求回拨后
      // 的那条算**新的一条**，并且落在未来的旧记录被清掉。
      final hits = <DateTime>[];
      hit(hits, t0.add(const Duration(seconds: 10)));
      // 回拨 10 秒：现在比记录还早。
      final back = t0;
      expect(hit(hits, back), isFalse);
      expect(hits, [back]);

      // 之后照常攒，照样能触发 —— 判据没有被那一下静默掉。
      for (var i = 1; i < 12; i++) {
        hit(hits, back.add(Duration(milliseconds: 100 * i)));
      }
      expect(hit(hits, back.add(const Duration(milliseconds: 1200))), isTrue);
    });
  });

  group('密集档：不去重，抓稀疏档数不到的短促爆发', () {
    // 稀疏档的三个数（PlPlayerController._kDecodeErrorBurst / _kDecodeErrorWindow
    // / _kDecodeLineDedupe）与密集档的两个数（_kDecodeErrorDenseBurst /
    // _kDecodeErrorDenseWindow）。两档喂的是同一个纯函数，只是参数不同。
    const sparseWindow = Duration(seconds: 6);
    const sparseBurst = 12;
    const dedupe = Duration(milliseconds: 5);
    const denseWindow = Duration(milliseconds: 100);
    const denseBurst = 20;

    // 逐字复刻 2026-10-11 那一场：日志 4 的 `22:53:59.334` → `.378`，
    // **260 条坏字节挤在 44 毫秒里**（`NULL: Failed to parse temporal unit` 一族）。
    // 它当时一条 `解码错误风暴` 都没出 —— 这就是要修的盲区。
    final storm0 = DateTime(2026, 10, 11, 22, 53, 59, 334);
    const stormSpan = Duration(milliseconds: 44);
    const stormLines = 260;
    DateTime stormAt(int i) => storm0.add(stormSpan * (i / (stormLines - 1)));

    bool hitWith(
      List<DateTime> hits,
      DateTime now, {
      required Duration window,
      required int burst,
      required Duration lineDedupe,
    }) => recordDecodeErrorHit(
      hits,
      now,
      window: window,
      burst: burst,
      lineDedupe: lineDedupe,
    );

    bool sparseHit(List<DateTime> hits, DateTime now) => hitWith(
      hits,
      now,
      window: sparseWindow,
      burst: sparseBurst,
      lineDedupe: dedupe,
    );

    bool denseHit(List<DateTime> hits, DateTime now) => hitWith(
      hits,
      now,
      window: denseWindow,
      burst: denseBurst,
      lineDedupe: Duration.zero,
    );

    test('44 毫秒 260 条：稀疏档整场数不满，密集档第 20 行就报', () {
      // 先钉住病：同包去重把命中率封在 1/5ms，44 毫秒最多落 9 条，够不到 12，
      // 而 44 毫秒之后风暴就结束了 —— 窗口空着等 6 秒过期，整场无人上报。
      final sparse = <DateTime>[];
      var sparseEverReached = false;
      var firstDenseAt = -1;
      final dense = <DateTime>[];
      for (var i = 0; i < stormLines; i++) {
        final at = stormAt(i);
        sparseEverReached |= sparseHit(sparse, at);
        if (firstDenseAt < 0 && denseHit(dense, at)) {
          firstDenseAt = i;
        }
      }

      expect(sparseEverReached, isFalse, reason: '稀疏档本该整场看不见（这就是那条盲区）');
      expect(sparse.length, 9, reason: '44ms / 5ms ≈ 9 条');
      expect(
        firstDenseAt,
        denseBurst - 1,
        reason: '第 20 行落地就该报，44 毫秒里 20 行离门槛只有一步',
      );
    });

    test('越密越看得见：门槛上下各差一条就翻转', () {
      bool fire(int n) {
        final dense = <DateTime>[];
        var reached = false;
        for (var i = 0; i < n; i++) {
          reached |= denseHit(dense, storm0.add(stormSpan * (i / (n - 1))));
        }
        return reached;
      }

      expect(fire(denseBurst), isTrue);
      expect(fire(denseBurst - 1), isFalse);
    });

    test('反例：同一个坏包在三层各报一行，三条不算密集', () {
      // 这正是同包去重存在的原因 —— 密集档不去重，就得靠门槛把这种挡在外面。
      final dense = <DateTime>[];
      for (var i = 0; i < 3; i++) {
        expect(
          denseHit(dense, storm0.add(Duration(milliseconds: i))),
          isFalse,
          reason: '第 ${i + 1} 层不该触发',
        );
      }
    });

    test('反例：换集/seek 边界上零星的一两条（单个损坏的 GOP）', () {
      final dense = <DateTime>[];
      expect(denseHit(dense, storm0), isFalse);
      expect(
        denseHit(dense, storm0.add(const Duration(milliseconds: 60))),
        isFalse,
      );
    });

    test('反例：正好铺满稀疏档窗口的 12 条（平均 545ms 一条）进不了密集档', () {
      // 这是稀疏档刻意要放过的形状 —— 12 条均匀铺满 6 秒。密集档窗口只有
      // 100ms，一条都留不住。
      final gap = Duration(
        milliseconds: sparseWindow.inMilliseconds ~/ (sparseBurst - 1),
      );
      final dense = <DateTime>[];
      for (var i = 0; i < sparseBurst; i++) {
        expect(denseHit(dense, storm0.add(gap * i)), isFalse);
      }
      expect(dense.length, 1, reason: '100ms 一过，前面的全出窗');
    });

    test('正好落在 100ms 边界上的那条还算数（淘汰用严格 >）', () {
      final dense = <DateTime>[];
      denseHit(dense, storm0);
      denseHit(dense, storm0.add(denseWindow));
      expect(dense.length, 2);
    });

    test('时钟回拨压不住它：落在未来的旧记录当场被清掉', () {
      // 100ms 的窗口比任何回拨幅度都短，回拨之后旧记录全在"未来"，
      // removeWhere 第一件事就是把它们清光 —— 不像稀疏档还得专门兜。
      final dense = <DateTime>[];
      for (var i = 0; i < denseBurst - 1; i++) {
        denseHit(dense, storm0.add(Duration(milliseconds: i)));
      }
      final back = storm0.subtract(const Duration(minutes: 5));
      expect(denseHit(dense, back), isFalse);
      expect(dense, [back], reason: '19 条旧记录全被当成未来清掉');

      // 之后照常攒，照样能报。
      var reached = false;
      for (var i = 1; i < denseBurst; i++) {
        reached |= denseHit(dense, back.add(Duration(milliseconds: i)));
      }
      expect(reached, isTrue);
    });
  });
}

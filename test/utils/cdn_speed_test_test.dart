import 'package:PiliPlus/utils/cdn_speed_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseContentRangeSize', () {
    test('reads the total out of a satisfiable range', () {
      expect(
        CdnSpeedTest.parseContentRangeSize(
          'bytes 400000000-499999999/500000000',
        ),
        500000000,
      );
    });

    test('a one-byte probe still discloses the total', () {
      expect(CdnSpeedTest.parseContentRangeSize('bytes 0-0/543447102'), 543447102);
    });

    test('withheld size is null', () {
      expect(CdnSpeedTest.parseContentRangeSize('bytes 0-0/*'), isNull);
    });

    test('an unsatisfied range still carries the total', () {
      expect(CdnSpeedTest.parseContentRangeSize('bytes */1234'), 1234);
    });

    test('malformed and missing values are null, never throw', () {
      expect(CdnSpeedTest.parseContentRangeSize(null), isNull);
      expect(CdnSpeedTest.parseContentRangeSize(''), isNull);
      expect(CdnSpeedTest.parseContentRangeSize('bytes'), isNull);
      expect(CdnSpeedTest.parseContentRangeSize('bytes 0-0'), isNull);
      expect(CdnSpeedTest.parseContentRangeSize('bytes 0-0/abc'), isNull);
    });

    test('tolerates padding around the total', () {
      expect(CdnSpeedTest.parseContentRangeSize('bytes 0-0/ 1234 '), 1234);
    });
  });

  test('autoCandidatesMax leaves room for the baseline in one batch', () {
    // The starvation round measures the current mirror as a baseline plus the
    // candidates, all in one concurrent batch. If this were any larger the
    // round would need a second batch, and the buffer it is trying to rescue
    // would drain while the first one ran.
    //
    // The literal is the point: asserting `autoCandidatesMax == autoConcurrency
    // - 1` alone pins only the *relation*, so bumping `autoConcurrency` from 3
    // to 4 would keep the test green while silently changing the batch width.
    expect(CdnSpeedTest.autoCandidatesMax, 2);
    expect(CdnSpeedTest.autoCandidatesMax, CdnSpeedTest.autoConcurrency - 1);
  });

  group('quick probe budget', () {
    test('is cheaper than a full round on both axes', () {
      // The quick probe fires while the player is already starving, so every
      // byte it spends is contention against the refill it is trying to rescue.
      expect(CdnSpeedTest.quickBytes, 512 * 1024);
      expect(CdnSpeedTest.quickMicros, 3 * 1000 * 1000);
      expect(CdnSpeedTest.quickBytes, lessThan(CdnSpeedTest.autoBytes));
      expect(CdnSpeedTest.quickMicros, lessThan(CdnSpeedTest.autoMicros));
    });

    test('its usability floor fits inside its own window', () {
      // If the floor exceeded what the window can deliver, every sample would be
      // discarded on exactly the slow links this trigger exists for.
      expect(CdnSpeedTest.quickMinBytes, 128 * 1024);
      expect(CdnSpeedTest.autoMinBytes, 256 * 1024);
      expect(CdnSpeedTest.quickMinBytes, lessThanOrEqualTo(CdnSpeedTest.quickBytes));
      expect(CdnSpeedTest.quickMinBytes, lessThan(CdnSpeedTest.autoMinBytes));
    });

    test('the floor is still enough to be a measurement', () {
      // 128 KiB in 3 s implies a floor of ~43 KB/s, well under the ~244 KB/s a
      // 1080p stream needs — so a mirror that clears the floor can be meaningfully
      // ranked, which is the only thing the ratio rule asks of it.
      expect(CdnSpeedTest.quickMinBytes, 128 * 1024);
      expect(CdnSpeedTest.quickMinBytes, greaterThan(0));
    });
  });

  group('usableSample', () {
    const minBytes = 256 * 1024;
    const readOffset = 4096;

    bool usable(({int bytes, int micros, bool ranged})? s) =>
        CdnSpeedTest.usableSample(s, minBytes: minBytes, readOffset: readOffset);

    test('a zero-cost sample is unusable: bytes / 0 takes the ranking outright', () {
      // `_pickFastestCdn` ranks by `-bytes / micros`, so a sample reporting no
      // elapsed time is +Infinity, sorts first, and wins `best` — the switch
      // lands on a mirror that was never actually measured.
      expect(usable((bytes: 2 * 1024 * 1024, micros: 0, ranged: true)), isFalse);
    });

    test('a backwards clock step (negative micros) is unusable too', () {
      expect(usable((bytes: 2 * 1024 * 1024, micros: -1500, ranged: true)), isFalse);
    });

    test('a normal sample is usable — the control against "nothing is usable"', () {
      expect(usable((bytes: 2 * 1024 * 1024, micros: 100 * 1000, ranged: true)), isTrue);
    });

    test('below the byte floor is unusable', () {
      expect(usable((bytes: minBytes - 1, micros: 100 * 1000, ranged: true)), isFalse);
      expect(usable((bytes: minBytes, micros: 100 * 1000, ranged: true)), isTrue);
    });

    test('an unhonoured Range at a non-zero offset is unusable', () {
      // A mirror that answers from the head still looks fast there — the sample
      // only proves the head streams.
      expect(usable((bytes: 2 * 1024 * 1024, micros: 100 * 1000, ranged: false)), isFalse);
    });

    test('the same unhonoured Range is fine at offset 0', () {
      // Offset 0 has no Range to honour, so `ranged` carries no information.
      expect(
        CdnSpeedTest.usableSample(
          (bytes: 2 * 1024 * 1024, micros: 100 * 1000, ranged: false),
          minBytes: minBytes,
          readOffset: 0,
        ),
        isTrue,
      );
    });

    test('no sample at all is unusable', () {
      expect(usable(null), isFalse);
    });
  });

  group('requiredMBps', () {
    test('matches a measured rate unit-for-unit', () {
      // The requirement and a measured sample must be directly comparable: the
      // mixin decides "is the baseline starving?" as `baseBps < needBps`, where
      // baseBps is `bytes / micros`. 100 MiB over 1000 s is 0.1048576 MB/s; a
      // sample that moved 1 MiB in 10 s reads 1 MiB / 10e6 µs — the same number.
      const size = 100 * 1024 * 1024;
      const durationMs = 1000 * 1000;
      final need = CdnSpeedTest.requiredMBps(size, durationMs);
      expect(need, closeTo(0.1048576, 1e-9));

      const measured = (1024 * 1024) / (10 * 1000000);
      expect(measured, closeTo(need, 1e-9));
    });

    test('is not bytes per second or per millisecond', () {
      // Guards the exact 1e3/1e6 slip that silently made every baseline look
      // starved and relaxed the switch ratio everywhere.
      const size = 4 * 1024 * 1024;
      const durationMs = 1000 * 1000; // 4 MiB over 1000 s
      final need = CdnSpeedTest.requiredMBps(size, durationMs);
      expect(need, closeTo(0.004194304, 1e-9)); // MB/s
      expect(size * 1000 / durationMs, closeTo(4194.304, 1e-3)); // B/s — the trap
    });

    test('unknown inputs yield 0 so the caller can skip the relaxation', () {
      expect(CdnSpeedTest.requiredMBps(0, 1000), 0);
      expect(CdnSpeedTest.requiredMBps(1024, 0), 0);
      expect(CdnSpeedTest.requiredMBps(-1, -1), 0);
    });

    test('a real 1080p60 stream needs a rate worth relaxing the ratio for', () {
      // Live case: 399635318 B over 2241600 ms = 0.178 MB/s, and the "healthy"
      // line is a fixed 1.0 MB/s — so the fixed line cannot express "this stream
      // is starving", which is why this exists.
      final need = CdnSpeedTest.requiredMBps(399635318, 2241600);
      expect(need, closeTo(0.178, 0.001));
      expect(need, lessThan(1.0));
    });
  });

  group('recordTooOld', () {
    final now = DateTime(2026, 10, 11, 12);
    const window = Duration(minutes: 3);

    test('a fresh record is usable', () {
      expect(
        CdnSpeedTest.recordTooOld(now, now.subtract(const Duration(seconds: 1)), window),
        isFalse,
      );
      expect(
        CdnSpeedTest.recordTooOld(now, now, window),
        isFalse,
      );
    });

    test('the window boundary counts as expired', () {
      // `>=`, not `>`: the two call sites pass a window that means "this record
      // is no longer describing the object", so the boundary must retire it.
      expect(
        CdnSpeedTest.recordTooOld(now, now.subtract(window), window),
        isTrue,
      );
      expect(
        CdnSpeedTest.recordTooOld(
          now,
          now.subtract(window - const Duration(milliseconds: 1)),
          window,
        ),
        isFalse,
      );
    });

    test('a backwards clock step expires the record instead of preserving it', () {
      // The one-sided `>= window` never fires on a negative delta, so a peak
      // record would outlive its expiry forever — and the "start a fresh window"
      // guard in _recordCdnSample would never fire either. Both exist to retire
      // a record, so a backwards step must expire it immediately.
      expect(
        CdnSpeedTest.recordTooOld(now, now.add(const Duration(hours: 1)), window),
        isTrue,
      );
      expect(
        CdnSpeedTest.recordTooOld(
          now,
          now.add(const Duration(days: 365)),
          const Duration(hours: 6),
        ),
        isTrue,
      );
    });

    test('a never-written slot (timestamp 0, i.e. 1970) is expired', () {
      expect(
        CdnSpeedTest.recordTooOld(
          now,
          DateTime.fromMillisecondsSinceEpoch(0),
          const Duration(hours: 6),
        ),
        isTrue,
      );
    });
  });

  group('targetOffset', () {
    // The same real 1080p60 stream: 399,635,318 B over 2,241,600 ms.
    const size = 399635318;
    const durationMs = 2241600;
    const mid = durationMs ~/ 2;
    const noAudio = false;

    int offsetAt({
      required int playheadMs,
      required int cacheEndMs,
      int duration = durationMs,
      bool onlyPlayAudio = noAudio,
      int total = size,
    }) => CdnSpeedTest.targetOffset(
      size: total,
      playheadMs: playheadMs,
      cacheEndMs: cacheEndMs,
      durationMs: duration,
      onlyPlayAudio: onlyPlayAudio,
    );

    test('maps the playhead through the object, plus the lead', () {
      final at = offsetAt(playheadMs: mid, cacheEndMs: 0);
      // Halfway through, plus [CdnSpeedTest.sampleLeadMs] — so just past half.
      expect(at, greaterThan(size ~/ 2));
      expect(at, lessThan((size * 0.51).round()));
      expect(at, lessThanOrEqualTo(size - CdnSpeedTest.readWindowBytes));
    });

    test('the buffered end wins over the playhead', () {
      expect(
        offsetAt(playheadMs: mid, cacheEndMs: mid + 100000),
        greaterThan(offsetAt(playheadMs: mid, cacheEndMs: 0)),
      );
      // A buffer that has not run ahead is not a second signal.
      expect(
        offsetAt(playheadMs: mid, cacheEndMs: mid),
        offsetAt(playheadMs: mid, cacheEndMs: 0),
      );
    });

    test('samples strictly past the buffered end, never inside it', () {
      // The point of the lead: the bytes the player already pulled are hot in the
      // edge node, and the baseline is the URL being played, so a sample inside
      // the buffer inflates the denominator the candidates are judged against.
      const cacheEnd = mid + 60 * 1000;
      final at = offsetAt(playheadMs: mid, cacheEndMs: cacheEnd);
      final bufferedBytes = (size * cacheEnd / durationMs).round();
      expect(at, greaterThan(bufferedBytes));
    });

    test('pushes past the head, where every mirror is fast', () {
      // 5 s in is 0.22% of the object — under the floor. A mirror that dies deeper
      // in still streams the head at full speed, so a sample there ties everyone.
      expect(
        offsetAt(playheadMs: 5000, cacheEndMs: 0),
        (size * CdnSpeedTest.offsetFloor).round(),
      );
    });

    test('stops short of the end so a read cannot run into EOF', () {
      // Read into the object's end and EOF is misread as "this mirror is slow".
      expect(
        offsetAt(playheadMs: durationMs, cacheEndMs: 0),
        size - CdnSpeedTest.readWindowBytes,
      );
    });

    test('an unknown duration falls back to the floor, not the head', () {
      // No ratio is available, but returning 0 samples the head — where all
      // mirrors tie, and a round that always ties never switches.
      final at = offsetAt(playheadMs: mid, cacheEndMs: mid, duration: 0);
      expect(at, (size * CdnSpeedTest.offsetFloor).round());
      expect(at, greaterThan(0));
    });

    test('unknown size, and audio-only mode, stay at 0', () {
      // Audio-only: mpv was handed an audio URL, so a video offset is a
      // guaranteed 416 (which voids the whole round).
      expect(
        offsetAt(playheadMs: mid, cacheEndMs: mid, onlyPlayAudio: true),
        0,
      );
      expect(offsetAt(playheadMs: mid, cacheEndMs: mid, total: 0), 0);
      expect(offsetAt(playheadMs: mid, cacheEndMs: mid, total: -1), 0);
    });

    test('an object too small to hold both bounds stays at 0', () {
      // The floor and the read window overlap once size <= readWindowBytes/0.85.
      expect(
        offsetAt(playheadMs: mid, cacheEndMs: mid, total: 4 * 1024 * 1024),
        0,
      );
    });
  });
}

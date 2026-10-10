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
    expect(CdnSpeedTest.autoCandidatesMax, CdnSpeedTest.autoConcurrency - 1);
  });

  group('quick probe budget', () {
    test('is cheaper than a full round on both axes', () {
      // The quick probe fires while the player is already starving, so every
      // byte it spends is contention against the refill it is trying to rescue.
      expect(CdnSpeedTest.quickBytes, lessThan(CdnSpeedTest.autoBytes));
      expect(CdnSpeedTest.quickMicros, lessThan(CdnSpeedTest.autoMicros));
    });

    test('its usability floor fits inside its own window', () {
      // If the floor exceeded what the window can deliver, every sample would be
      // discarded on exactly the slow links this trigger exists for.
      expect(CdnSpeedTest.quickMinBytes, lessThanOrEqualTo(CdnSpeedTest.quickBytes));
      expect(CdnSpeedTest.quickMinBytes, lessThan(CdnSpeedTest.autoMinBytes));
    });

    test('the floor is still enough to be a measurement', () {
      // 128 KiB in 3 s implies a floor of ~43 KB/s, well under the ~244 KB/s a
      // 1080p stream needs — so a mirror that clears the floor can be meaningfully
      // ranked, which is the only thing the ratio rule asks of it.
      expect(CdnSpeedTest.quickMinBytes, greaterThan(0));
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
}

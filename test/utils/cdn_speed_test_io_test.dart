import 'dart:typed_data';

import 'package:PiliPlus/utils/cdn_speed_test.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// The I/O half of [CdnSpeedTest]: what it does with a real response stream.
///
/// These need a fake adapter rather than the record literals the pure-function
/// tests use, because the question is about the *stream*, not the arithmetic.
/// The source has to be **paced** (one chunk per event-loop turn): dio subscribes
/// to the adapter's stream the moment the response headers arrive, so a source
/// that hands over everything synchronously is fully buffered before the code
/// under test ever looks at it — and every "how much did it read" assertion
/// becomes vacuous.
void main() {
  group('probeSize', () {
    test('does not pull a 200 that ignored the Range end to end', () async {
      // `Range: bytes=0-0` is a 1-byte request. A server that ignores it answers
      // 200 with the **whole object**. What bounds that read is the cancel fired
      // right after the headers — measured here at one chunk out of fifty. If
      // the cancel moves after the drain (or is dropped), this goes red with the
      // entire object pulled down the very link the probe is trying to measure.
      final adapter = _PacedAdapter(
        statusCode: 200,
        chunks: 50,
        contentLength: 50 * 1024,
      );
      final dio = Dio()..httpClientAdapter = adapter;

      final size = await CdnSpeedTest.probeSize(
        dio,
        'https://mirror.example/v.mp4',
        CancelToken(),
      );
      // Give the source room to keep delivering if nothing stopped it.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(size, 50 * 1024, reason: 'the content-length fallback still works');
      expect(adapter.chunksRead, 1, reason: 'the read must stay bounded');
    });

    test('a real 206 still yields the size', () async {
      // The control: the normal path keeps working, so the bound above is not
      // "the response is broken".
      final adapter = _PacedAdapter(
        statusCode: 206,
        chunks: 1,
        contentRange: 'bytes 0-0/543447102',
      );
      final dio = Dio()..httpClientAdapter = adapter;

      final size = await CdnSpeedTest.probeSize(
        dio,
        'https://mirror.example/v.mp4',
        CancelToken(),
      );

      expect(size, 543447102);
    });
  });

  group('measureAt', () {
    test('stops as soon as isCancelled says so', () async {
      // The mixin hands in the mounted-state test, so this is what makes a
      // detached page stop sampling instead of spending its whole budget.
      final adapter = _PacedAdapter(statusCode: 206, chunks: 6, chunkBytes: 1024);
      final dio = Dio()..httpClientAdapter = adapter;
      var calls = 0;

      final sample = await CdnSpeedTest.measureAt(
        dio,
        'https://mirror.example/v.mp4',
        CancelToken(),
        offset: 0,
        maxBytes: 1024 * 1024 * 1024,
        maxMicros: 60 * 1000 * 1000,
        isCancelled: () => calls++ >= 2,
      );

      expect(sample, isNotNull);
      // The check runs *after* the chunk is counted, so the third chunk is the
      // one that trips it and nothing past it is counted.
      expect(sample!.bytes, 3 * 1024);
    });

    test('reads the whole sample when nothing cancels it', () async {
      // The control: without the callback the full sample still comes through,
      // so the test above is measuring the cancellation, not a broken stream.
      final adapter = _PacedAdapter(statusCode: 206, chunks: 6, chunkBytes: 1024);
      final dio = Dio()..httpClientAdapter = adapter;

      final sample = await CdnSpeedTest.measureAt(
        dio,
        'https://mirror.example/v.mp4',
        CancelToken(),
        offset: 0,
        maxBytes: 1024 * 1024 * 1024,
        maxMicros: 60 * 1000 * 1000,
      );

      expect(sample!.bytes, 6 * 1024);
    });
  });
}

/// Serves [chunks] chunks, **one per event-loop turn**, and counts how many were
/// pulled off the stream — the count is only reachable by subscribing to it.
class _PacedAdapter implements HttpClientAdapter {
  _PacedAdapter({
    required this.statusCode,
    required this.chunks,
    this.chunkBytes = 1024,
    this.contentLength,
    this.contentRange,
  });

  final int statusCode;
  final int chunks;
  final int chunkBytes;
  final int? contentLength;
  final String? contentRange;

  int chunksRead = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    Stream<Uint8List> paced() async* {
      for (var i = 0; i < chunks; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        chunksRead++;
        yield Uint8List(chunkBytes);
      }
    }

    return ResponseBody(
      paced(),
      statusCode,
      headers: {
        if (contentLength != null)
          Headers.contentLengthHeader: ['$contentLength'],
        if (contentRange != null) 'content-range': [contentRange!],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

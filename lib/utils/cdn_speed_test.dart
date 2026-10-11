import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:dio/dio.dart';

/// One transfer sample: bytes received, wall-clock microseconds, the object's
/// total size when the server disclosed it, and whether the server actually
/// answered from the requested offset. [ranged] matters because an edge that
/// ignores `Range` would otherwise be sampled in the object's head, where a
/// mirror that is broken deeper in still looks fast.
typedef CdnSample = ({int bytes, int micros, int? size, bool ranged});

/// Shared transfer measurement, used by both the manual CDN speed-test dialog
/// and the stall-triggered auto-switch.
abstract final class CdnSpeedTest {
  /// Phase 1 screening: small sample, short deadline.
  static const int probeConcurrency = 6;
  static const int probeBytes = 256 * 1024;
  static const int probeMicros = 3 * 1000 * 1000;
  static const Duration probeConnect = Duration(seconds: 3);
  static const Duration probeReceive = Duration(seconds: 3);

  /// Phase 2 measurement: large enough that MB/s is comparable to a
  /// single-stream playback.
  static const int measureBytes = 2 * 1024 * 1024;
  static const int measureMicros = 8 * 1000 * 1000;

  /// Auto-mode budget, tighter than the manual dialog because this runs while
  /// the user is waiting on a frozen video.
  static const int autoBytes = 2 * 1024 * 1024;
  static const int autoMicros = 6 * 1000 * 1000;
  static const int autoConcurrency = 3;

  /// Micro-stutter probe budget: fired the moment the runway hits zero, while the
  /// player is still trying to refill, so the probe is *additional contention on a
  /// link already failing*. The wall-clock deadline is the real cost bound —
  /// [measureAt] aborts on time regardless of bytes — so this caps the damage at
  /// 3 s per stream instead of the 6 s a full round would take. Byte count only
  /// decides how much is sampled in that window.
  static const int quickBytes = 512 * 1024;
  static const int quickMicros = 3 * 1000 * 1000;

  /// Usability floor for a quick probe. It has to scale down with the budget:
  /// [autoMinBytes] is 256 KiB, which a 3 s window cannot reach on the very links
  /// this trigger exists for (at 0.05 MB/s it yields ~150 KiB), so keeping the
  /// full-round floor would discard every sample exactly when the picture is
  /// worst and the probe is most wanted. A ratio comparison only needs both sides
  /// measured the same way.
  static const int quickMinBytes = 128 * 1024;

  /// A starvation round also measures the mirror already in use as a baseline,
  /// so it must fit in one concurrent batch — otherwise the round outlasts the
  /// buffer it is trying to rescue. This is the whole candidate window, not a
  /// Wi-Fi/cellular split: any larger window would need a second batch.
  static const int autoCandidatesMax = autoConcurrency - 1;

  /// A candidate must move at least this much to count as reachable, so a
  /// barely-alive mirror is not preferred over one that actually streams.
  static const int autoMinBytes = 256 * 1024;

  static Dio createDio() =>
      Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 15),
          ),
        )
        ..options.headers = {
          'user-agent': BrowserUa.pc,
          'referer': HttpString.baseUrl,
        };

  /// Real mirrors only — `baseUrl` and `backupUrl` carry no host, and
  /// [CDNService.knownDead] carries a host no resolver can resolve.
  ///
  /// 这是唯一一处"哪些镜像值得探"的源头（轮换表和冠军评选都取自它）。死主机
  /// 留下的唯一后果是每轮白占一个候选位 + 两次 3 秒超时，见 `knownDead`。
  /// 设置页列的是 `CDNService.values`，所以那两行仍然看得见、选得动。
  ///
  /// 用 `static final` 而不是 getter：`CDNService.values` 和
  /// [CDNService.knownDead] 都是编译期常量，结果恒定不变，而这里每轮都要被
  /// 冠军评选和候选建置各取一次（cdn_switch_mixin.dart），没有必要反复过滤。
  static final List<CDNService> mirrors = CDNService.values
      .where((e) => e.host != null && !CDNService.knownDead.contains(e))
      .toList(growable: false);

  /// What it takes to play [size] bytes spread over [durationMs], expressed in
  /// **MB/s** — the same unit a measured sample reads as, since every caller
  /// computes a rate as `bytes / micros` and 1 byte/µs is exactly 1 MB/s.
  ///
  /// Below this, buffering is guaranteed to lose ground no matter which mirror
  /// serves it; it is a hard requirement, unlike the fixed "healthy" line.
  ///
  /// The `/ 1000` is the whole point and is easy to get wrong: `size / durationMs`
  /// alone is bytes per *millisecond*, and `size * 1000 / durationMs` is bytes per
  /// *second*. Both are 1e3–1e6 off from `bytes / micros`, which does not throw —
  /// it just makes every baseline look starved and silently relaxes the switch
  /// ratio everywhere. (This happened; the log printed "baseline only reaches 0%".)
  ///
  /// Returns 0 for unknown inputs so the caller can treat 0 as "don't apply".
  static double requiredMBps(int size, int durationMs) =>
      (size <= 0 || durationMs <= 0) ? 0 : size / durationMs / 1000;

  /// Is a timestamped speed record too old to be used?
  ///
  /// **Negative** age counts as too old. A backwards clock step (NTP correction,
  /// the user changing it) makes `now - recorded` negative, and a one-sided
  /// `>= window` then never fires — so a peak record outlives its expiry
  /// forever, and the "start a fresh window" guard never fires either. Both of
  /// those exist precisely to retire a record, so a backwards step is treated as
  /// immediate expiry.
  ///
  /// A never-written slot has timestamp 0 (1970), which clears any window on its
  /// own — no special case needed.
  static bool recordTooOld(DateTime now, DateTime recorded, Duration window) {
    final delta = now.difference(recorded);
    return delta.isNegative || delta >= window;
  }

  /// Lower bound of the sample offset, as a fraction of the object. The head is
  /// the "face-saving zone" — a mirror that is dead deeper in still streams the
  /// head at full speed — so sampling must land past it.
  static const double offsetFloor = 0.15;

  /// How many bytes to keep clear of the object's end. A sample reads at most
  /// [autoBytes]; the 2x margin is there so a read never runs into EOF, which
  /// would be misread as "this mirror is slow".
  static const int readWindowBytes = 4 * 1024 * 1024;

  /// How far past the buffer's end to sample, on top of the playhead.
  ///
  /// What the player has already pulled is hot in the edge node, and the
  /// baseline *is* the URL being played, so reading hot bytes inflates it
  /// (measured: 19.2MB/s hot vs 0.683MB/s cold at the same offset) and divides
  /// the candidate bar down to a phantom. The buffered end is what the playhead
  /// is about to read next: cold, yet still "the bytes about to be needed".
  /// When the buffer is starved `cacheEnd == playhead`, so this lead is the only
  /// margin left — it cannot be 0.
  static const int sampleLeadMs = 5000;

  /// Where to sample the object for a speed test, in bytes.
  ///
  /// The sample must land inside `[size × offsetFloor, size − readWindowBytes]`:
  /// past the fast head, and short of the end. The point is the **buffered end +
  /// [sampleLeadMs]**, not the playhead byte, so baseline and candidates both
  /// read cold bytes (see [sampleLeadMs]).
  ///
  /// Unknown duration (the player has not reported one yet) has no usable ratio,
  /// but it must not fall back to the head either: every mirror is fast at the
  /// head, so a round there ties them all and never switches. It returns the
  /// interior floor instead. `onlyPlayAudio` returns 0 — mpv was handed an audio
  /// URL, so any video offset is a guaranteed 416 — as does an unknown size.
  static int targetOffset({
    required int size,
    required int playheadMs,
    required int cacheEndMs,
    required int durationMs,
    required bool onlyPlayAudio,
  }) {
    if (size <= 0) return 0;
    if (onlyPlayAudio) return 0;
    final upper = size - readWindowBytes;
    final lower = (size * offsetFloor).round();
    if (lower >= upper) return 0;
    if (durationMs <= 0) return lower;
    final targetMs =
        (cacheEndMs > playheadMs ? cacheEndMs : playheadMs) + sampleLeadMs;
    final offset = (size * (targetMs / durationMs)).round();
    return offset.clamp(lower, upper);
  }

  /// Returns `(bytes downloaded, elapsed microseconds)`, or null when nothing
  /// arrived. Aborting at a cap is a normal result; a genuine network failure
  /// rethrows.
  static Future<(int, int)?> measure(
    Dio dio,
    String url,
    CancelToken token, {
    required int maxBytes,
    required int maxMicros,
    Duration? connectTimeout,
    Duration? receiveTimeout,
    bool Function()? isCancelled,
  }) async {
    var downloaded = 0;
    var stopped = false;
    final start = DateTime.now().microsecondsSinceEpoch;

    void stop() {
      stopped = true;
      token.cancel();
    }

    try {
      await dio.get(
        url,
        cancelToken: token,
        options: Options(
          connectTimeout: connectTimeout,
          receiveTimeout: receiveTimeout,
        ),
        onReceiveProgress: (count, _) {
          if (isCancelled?.call() ?? false) {
            stop();
            return;
          }
          downloaded = count;
          final duration = DateTime.now().microsecondsSinceEpoch - start;
          if (duration > maxMicros || downloaded >= maxBytes) {
            stop();
          }
        },
      );
    } on DioException {
      // Cancelling ourselves is not a failure.
      if (!stopped) rethrow;
    }

    if (downloaded <= 0) return null;
    return (downloaded, DateTime.now().microsecondsSinceEpoch - start);
  }

  /// Total object size out of a `Content-Range` header, e.g.
  /// `bytes 400000000-499999999/500000000` -> 500000000.
  /// `bytes 0-0/*` (size withheld) and malformed values give null.
  static int? parseContentRangeSize(String? value) {
    if (value == null) return null;
    final slash = value.lastIndexOf('/');
    if (slash < 0) return null;
    return int.tryParse(value.substring(slash + 1).trim());
  }

  /// Like [measure], but reads from [offset] so a mirror can be judged on the
  /// bytes the playhead is about to need rather than on the object's head.
  ///
  /// Returns null when nothing arrived. As in [measure], aborting at a cap is a
  /// normal result and a genuine network failure rethrows — with one exception:
  /// a server that sends some bytes and then stalls raises `receiveTimeout`,
  /// which is a slow sample, not a failure.
  static Future<CdnSample?> measureAt(
    Dio dio,
    String url,
    CancelToken token, {
    required int offset,
    required int maxBytes,
    required int maxMicros,
    Duration? connectTimeout,
    Duration? receiveTimeout,
    bool Function()? isCancelled,
  }) async {
    var received = 0;
    var stopped = false;
    final start = DateTime.now().microsecondsSinceEpoch;

    void stop() {
      stopped = true;
      if (!token.isCancelled) token.cancel();
    }

    final Response<ResponseBody> response;
    try {
      response = await dio.get<ResponseBody>(
        url,
        cancelToken: token,
        options: Options(
          responseType: ResponseType.stream,
          headers: offset > 0 ? {'range': 'bytes=$offset-'} : null,
          connectTimeout: connectTimeout,
          receiveTimeout: receiveTimeout,
        ),
      );
    } on DioException {
      if (!stopped) rethrow;
      return null;
    }

    // Status and headers are only readable here: cancelling discards the
    // Response. Do not use ResponseBody.contentLength — it parses the raw
    // header with int.parse and throws on anything malformed.
    final contentRange = response.headers.value('content-range');
    var size = parseContentRangeSize(contentRange);
    if (size == null && response.statusCode == 200) {
      size = int.tryParse(response.headers.value('content-length') ?? '');
    }
    final ranged = offset == 0 || response.statusCode == 206 ||
        contentRange != null;

    final body = response.data;
    if (body == null) return null;
    try {
      await for (final chunk in body.stream) {
        received += chunk.length;
        if (isCancelled?.call() ?? false) {
          stop();
          break;
        }
        final elapsed = DateTime.now().microsecondsSinceEpoch - start;
        if (elapsed > maxMicros || received >= maxBytes) {
          stop();
          break;
        }
      }
    } on DioException catch (e) {
      if (!stopped && e.type != DioExceptionType.receiveTimeout) rethrow;
    } finally {
      stop();
    }

    if (received <= 0) return null;
    return (
      bytes: received,
      micros: DateTime.now().microsecondsSinceEpoch - start,
      size: size,
      ranged: ranged,
    );
  }

  /// Object size via a 1-byte ranged request, so the playhead can be mapped
  /// onto a byte offset. Null when the server will not disclose it.
  static Future<int?> probeSize(
    Dio dio,
    String url,
    CancelToken token, {
    Duration? connectTimeout,
    Duration? receiveTimeout,
  }) async {
    try {
      final response = await dio.get<ResponseBody>(
        url,
        cancelToken: token,
        options: Options(
          responseType: ResponseType.stream,
          headers: const {'range': 'bytes=0-0'},
          connectTimeout: connectTimeout,
          receiveTimeout: receiveTimeout,
        ),
      );
      final contentRange = response.headers.value('content-range');
      final size = parseContentRangeSize(contentRange) ??
          (response.statusCode == 200
              ? int.tryParse(response.headers.value('content-length') ?? '')
              : null);
      // Cancel before subscribing: that closes the response and kills the
      // source subscription, so no data can be delivered to a closed sink.
      if (!token.isCancelled) token.cancel();
      final body = response.data;
      if (body != null) {
        await body.stream.drain<void>().catchError((Object _) {});
      }
      return size;
    } on DioException {
      return null;
    }
  }
}

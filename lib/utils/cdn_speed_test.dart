import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:dio/dio.dart';

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
  static const int autoCandidatesWifi = 6;
  static const int autoCandidatesCell = 4;
  static const Duration autoDeadline = Duration(seconds: 15);

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

  /// Real mirrors only — `baseUrl` and `backupUrl` carry no host.
  static List<CDNService> get mirrors =>
      CDNService.values.where((e) => e.host != null).toList(growable: false);

  /// The URL [service] would serve for [urls], or `''` when there is nothing to
  /// serve.
  static String urlFor(Iterable<String> urls, CDNService service) {
    if (urls.isEmpty) return '';
    return VideoUtils.getCdnUrl(urls, defaultCDNService: service);
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
}

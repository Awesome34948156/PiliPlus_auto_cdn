import 'dart:async';

import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/utils/cdn_speed_test.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:material_ui/material_ui.dart';

class SelectDialog<T> extends StatelessWidget {
  final T? value;
  final String title;
  final List<(T, String)> values;
  final Widget Function(BuildContext, int)? subtitleBuilder;
  final bool toggleable;

  const SelectDialog({
    super.key,
    this.value,
    required this.values,
    required this.title,
    this.subtitleBuilder,
    this.toggleable = false,
  });

  @override
  Widget build(BuildContext context) {
    final titleMedium = TextTheme.of(context).titleMedium!;
    return AlertDialog(
      clipBehavior: Clip.hardEdge,
      title: Text(title),
      constraints: subtitleBuilder != null
          ? const BoxConstraints.tightFor(width: 320)
          : null,
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      content: Material(
        type: .transparency,
        child: SingleChildScrollView(
          child: RadioGroup<T>(
            onChanged: (v) => Navigator.of(context).pop(v ?? value),
            groupValue: value,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(
                values.length,
                (index) {
                  final item = values[index];
                  return RadioListTile<T>(
                    toggleable: toggleable,
                    dense: true,
                    value: item.$1,
                    title: Text(
                      item.$2,
                      style: titleMedium,
                    ),
                    subtitle: subtitleBuilder?.call(context, index),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// The probe/measure budgets live in [CdnSpeedTest] so the manual dialog and the
// auto-switch cannot drift apart; this dialog keeps only the one deliberate
// difference — Phase 2 runs serially (see [_testAllCdnServices]).

class CdnSelectDialog extends StatefulWidget {
  final BaseItem? sample;

  const CdnSelectDialog({
    super.key,
    this.sample,
  });

  @override
  State<CdnSelectDialog> createState() => _CdnSelectDialogState();
}

class _CdnSelectDialogState extends State<CdnSelectDialog> {
  late final List<ValueNotifier<String?>> _cdnResList;
  late final List<CancelToken?> _tokens;
  late final bool _cdnSpeedTest;
  late final ValueNotifier<(int, int)> _progress;

  /// Probe outcome per `CDNService` index; `false` means unreachable.
  late final List<bool> _alive;

  /// [State.mounted] stays true while [dispose] runs, so a cancel-triggered
  /// callback could otherwise write to a just-disposed [ValueNotifier].
  bool _disposed = false;

  @override
  void initState() {
    _cdnSpeedTest = Pref.cdnSpeedTest;
    if (_cdnSpeedTest) {
      _dio = CdnSpeedTest.createDio();
      final length = CDNService.values.length;
      _cdnResList = List.generate(
        length,
        (_) => ValueNotifier<String?>(null),
      );
      _tokens = List.generate(length, (_) => CancelToken());
      _progress = ValueNotifier<(int, int)>((0, 0));
      _alive = List<bool>.filled(length, false);
      _startSpeedTest();
    }
    super.initState();
  }

  @override
  void dispose() {
    if (_cdnSpeedTest) {
      _disposed = true;
      for (final e in _tokens) {
        e?.cancel();
      }
      for (final notifier in _cdnResList) {
        notifier.dispose();
      }
      _progress.dispose();
      _dio.close(force: true);
    }
    super.dispose();
  }

  void _setProgress(int done, int total) {
    if (_disposed) return;
    _progress.value = (done, total);
  }

  Future<BaseItem> _getSampleUrl() async {
    final result = await VideoHttp.videoUrl(
      cid: 196018899,
      bvid: 'BV1fK4y1t7hj',
      qn: VideoQuality.high1080.code,
      tryLook: false,
      videoType: VideoType.ugc,
    );
    final item = result.dataOrNull?.dash?.video?.first;
    if (item == null) throw Exception('无法获取视频流');
    return item;
  }

  Future<void> _startSpeedTest() async {
    try {
      final videoItem = widget.sample ?? await _getSampleUrl();
      await _testAllCdnServices(videoItem);
    } catch (e) {
      if (kDebugMode) debugPrint('CDN speed test failed: $e');
    }
  }

  /// Object size in bytes for the sample, or 0 when the server will not
  /// disclose it. Only used to turn a fraction of the object into a byte offset
  /// for the ranged samples; one mirror answers for all of them since every
  /// host serves the same object.
  Future<int> _probeObjectSize(List<String> urls) async {
    final token = CancelToken();
    try {
      return await CdnSpeedTest.probeSize(
            _dio,
            urls.first,
            token,
            connectTimeout: CdnSpeedTest.probeConnect,
            receiveTimeout: CdnSpeedTest.probeReceive,
          ) ??
          0;
    } catch (e) {
      if (kDebugMode) debugPrint('CDN size probe failed: $e');
      return 0;
    } finally {
      if (!token.isCancelled) token.cancel();
    }
  }

  Future<void> _testAllCdnServices(BaseItem videoItem) async {
    // _startSpeedTest awaits the sample fetch first, so the dialog may already
    // be gone by the time we get here.
    if (_disposed || !mounted) return;
    // playUrls is a lazy sync* generator; materialize it once.
    final urls = videoItem.playUrls.toList();
    // [CdnSpeedTest.mirrors] already drops baseUrl/backupUrl (no host) and the
    // known-dead hosts, so the manual dialog screens exactly the real mirrors
    // the auto-switch does. The two dead rows still show in the list (which
    // renders `CDNService.values`) — they just stay '---' instead of paying two
    // 3 s NXDOMAIN timeouts each round.
    final candidates = CdnSpeedTest.mirrors;

    if (urls.isEmpty) {
      for (final e in candidates) {
        _cdnResList[e.index].value = '无法获取视频流';
      }
      return;
    }

    // One offset for every mirror keeps the reported MB/s comparable — all
    // hosts serve the same object. The manual dialog has no live playhead: it
    // can run before playback (the settings entry point) and, opened from the
    // player, still measures every mirror at a single fixed offset. So the
    // playhead inputs are passed as 0, which lands [CdnSpeedTest.targetOffset]
    // on its interior floor (size × offsetFloor) — well past the fast head that
    // flatters every mirror equally and hides one that is dead deeper in. The
    // branch to avoid is the one that returns 0 (the object's head); only a
    // failed size probe falls back there.
    final offset = CdnSpeedTest.targetOffset(
      size: await _probeObjectSize(urls),
      playheadMs: 0,
      cacheEndMs: 0,
      durationMs: 0,
      onlyPlayAudio: false,
    );

    // Phase 1: screen every mirror for reachability, concurrently.
    _setProgress(0, candidates.length);
    var done = 0;
    for (final chunk in candidates.mapChunked(
      CdnSpeedTest.probeConcurrency,
      (e) => _probeSingle(e, urls, offset),
    )) {
      if (_disposed || !mounted) return;
      for (final (item, alive) in await Future.wait(chunk)) {
        _alive[item.index] = alive;
        _cdnResList[item.index].value = alive ? '待测速' : '连接失败';
      }
      done += chunk.length;
      _setProgress(done, candidates.length);
    }
    if (_disposed || !mounted) return;

    // Phase 2: measure the survivors **one at a time** so the reported MB/s
    // stays comparable to a single-stream playback. This serial intent is
    // deliberate — batching it with Phase 1's concurrency would report a
    // contended rate no single stream ever sees.
    final survivors = candidates
        .where((e) => _alive[e.index])
        .toList(growable: false);
    _setProgress(0, survivors.length);
    var measured = 0;
    for (final item in survivors) {
      if (_disposed || !mounted) return;
      await _testSingleCdn(item, urls, offset);
      _setProgress(++measured, survivors.length);
    }
    _setProgress(0, 0);
  }

  Future<(CDNService, bool)> _probeSingle(
    CDNService item,
    List<String> urls,
    int offset,
  ) async {
    try {
      final url = VideoUtils.getCdnUrl(urls, defaultCDNService: item);
      if (url.isEmpty) return (item, false);
      final res = await _measureDownloadSpeed(
        url,
        item.index,
        offset: offset,
        maxBytes: CdnSpeedTest.probeBytes,
        maxMicros: CdnSpeedTest.probeMicros,
        connectTimeout: CdnSpeedTest.probeConnect,
        receiveTimeout: CdnSpeedTest.probeReceive,
      );
      return (item, res != null);
    } catch (e) {
      if (kDebugMode) debugPrint('CDN probe error [${item.name}]: $e');
      return (item, false);
    }
  }

  Future<void> _testSingleCdn(
    CDNService item,
    List<String> urls,
    int offset,
  ) async {
    final index = item.index;
    try {
      final cdnUrl = VideoUtils.getCdnUrl(urls, defaultCDNService: item);
      if (cdnUrl.isEmpty) throw Exception('无法获取视频流');
      _cdnResList[index].value = '测速中…';
      final res = await _measureDownloadSpeed(
        cdnUrl,
        index,
        offset: offset,
        maxBytes: CdnSpeedTest.measureBytes,
        maxMicros: CdnSpeedTest.measureMicros,
      );
      if (res == null) throw TimeoutException('测速超时');
      _updateSpeedResult(index, res.$1, res.$2);
    } catch (e) {
      _handleSpeedTestError(e, index);
    }
  }

  late final Dio _dio;

  /// Returns `(bytes downloaded, elapsed microseconds)`, or null when nothing
  /// arrived. Aborting at a cap is a normal result; a genuine network failure
  /// rethrows. Reads from [offset] (see [CdnSpeedTest.measureAt]) so a mirror is
  /// judged on bytes past the head, not on the head that flatters every host.
  Future<(int, int)?> _measureDownloadSpeed(
    String url,
    int index, {
    required int offset,
    required int maxBytes,
    required int maxMicros,
    Duration? connectTimeout,
    Duration? receiveTimeout,
  }) async {
    final sample = await CdnSpeedTest.measureAt(
      _dio,
      url,
      _tokens[index] = CancelToken(),
      offset: offset,
      maxBytes: maxBytes,
      maxMicros: maxMicros,
      connectTimeout: connectTimeout,
      receiveTimeout: receiveTimeout,
      isCancelled: () => _disposed || !mounted,
    );
    return sample == null ? null : (sample.bytes, sample.micros);
  }

  void _updateSpeedResult(int index, int downloaded, int duration) {
    // A dismissal mid-transfer still yields a non-null result, so guard here
    // rather than at the call site.
    if (_disposed || !mounted) return;
    final speed = (downloaded / duration).toStringAsPrecision(3);
    _cdnResList[index].value = '${speed}MB/s';
  }

  void _handleSpeedTestError(dynamic error, int index) {
    if (_disposed || !mounted) return;
    _tokens
      ..[index]?.cancel()
      ..[index] = null;

    if (kDebugMode) debugPrint('CDN speed test error: $error');
    String message;
    if (error is DioException) {
      final statusCode = error.response?.statusCode;
      if (statusCode != null && 400 <= statusCode && statusCode < 500) {
        message = '此视频可能无法替换为该CDN';
      } else {
        message = error.toString();
      }
    } else {
      message = error.toString();
    }
    if (message.isEmpty) {
      message = '测速失败';
    }
    _cdnResList[index].value = message;
  }

  @override
  Widget build(BuildContext context) {
    if (!_cdnSpeedTest) {
      return _buildDialog('CDN 设置');
    }
    return ValueListenableBuilder<(int, int)>(
      valueListenable: _progress,
      builder: (context, progress, _) {
        final (done, total) = progress;
        return _buildDialog(
          total == 0 ? 'CDN 设置' : 'CDN 设置 (测速中 $done/$total)',
        );
      },
    );
  }

  Widget _buildDialog(String title) {
    return SelectDialog<CDNService>(
      title: title,
      values: CDNService.values.map((i) => (i, i.desc)).toList(),
      value: VideoUtils.cdnService,
      subtitleBuilder: _cdnSpeedTest
          ? (context, index) {
              final item = _cdnResList[index];
              return ValueListenableBuilder(
                valueListenable: item,
                builder: (context, value, _) {
                  return Text(
                    value ?? '---',
                    style: const TextStyle(fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  );
                },
              );
            }
          : null,
    );
  }
}

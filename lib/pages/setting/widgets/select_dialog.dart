import 'dart:async';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
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

/// Phase 1 screens every mirror for reachability with a small sample and a
/// short deadline, running [_kProbeConcurrency] at a time.
const _kProbeConcurrency = 6;
const _kProbeBytes = 256 * 1024;
const _kProbeMicros = 3 * 1000 * 1000;
const _kProbeConnect = Duration(seconds: 3);
const _kProbeReceive = Duration(seconds: 3);

/// Phase 2 measures the survivors one at a time so the reported MB/s stays
/// comparable to a single-stream playback.
const _kMeasureBytes = 2 * 1024 * 1024;
const _kMeasureMicros = 8 * 1000 * 1000;

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
      _dio =
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

  Future<void> _testAllCdnServices(BaseItem videoItem) async {
    // _startSpeedTest awaits the sample fetch first, so the dialog may already
    // be gone by the time we get here.
    if (_disposed || !mounted) return;
    // playUrls is a lazy sync* generator; materialize it once.
    final urls = videoItem.playUrls.toList();
    // baseUrl/backupUrl carry no host and are not real mirrors, so there is
    // nothing to probe.
    final candidates = CDNService.values
        .where((e) => e.host != null)
        .toList(growable: false);

    if (urls.isEmpty) {
      for (final e in candidates) {
        _cdnResList[e.index].value = '无法获取视频流';
      }
      return;
    }

    // Phase 1: screen every mirror for reachability, concurrently.
    _setProgress(0, candidates.length);
    var done = 0;
    for (final chunk in candidates.mapChunked(
      _kProbeConcurrency,
      (e) => _probeSingle(e, urls),
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

    // Phase 2: measure the survivors one at a time at full bandwidth.
    final survivors = candidates
        .where((e) => _alive[e.index])
        .toList(growable: false);
    _setProgress(0, survivors.length);
    var measured = 0;
    for (final item in survivors) {
      if (_disposed || !mounted) return;
      await _testSingleCdn(item, urls);
      _setProgress(++measured, survivors.length);
    }
    _setProgress(0, 0);
  }

  Future<(CDNService, bool)> _probeSingle(
    CDNService item,
    List<String> urls,
  ) async {
    try {
      final url = VideoUtils.getCdnUrl(urls, defaultCDNService: item);
      if (url.isEmpty) return (item, false);
      final res = await _measureDownloadSpeed(
        url,
        item.index,
        maxBytes: _kProbeBytes,
        maxMicros: _kProbeMicros,
        connectTimeout: _kProbeConnect,
        receiveTimeout: _kProbeReceive,
      );
      return (item, res != null);
    } catch (e) {
      if (kDebugMode) debugPrint('CDN probe error [${item.name}]: $e');
      return (item, false);
    }
  }

  Future<void> _testSingleCdn(CDNService item, List<String> urls) async {
    final index = item.index;
    try {
      final cdnUrl = VideoUtils.getCdnUrl(urls, defaultCDNService: item);
      if (cdnUrl.isEmpty) throw Exception('无法获取视频流');
      _cdnResList[index].value = '测速中…';
      final res = await _measureDownloadSpeed(
        cdnUrl,
        index,
        maxBytes: _kMeasureBytes,
        maxMicros: _kMeasureMicros,
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
  /// rethrows.
  Future<(int, int)?> _measureDownloadSpeed(
    String url,
    int index, {
    required int maxBytes,
    required int maxMicros,
    Duration? connectTimeout,
    Duration? receiveTimeout,
  }) async {
    var downloaded = 0;
    var stopped = false;
    final cancelToken = _tokens[index] = CancelToken();
    final start = DateTime.now().microsecondsSinceEpoch;

    void stop() {
      stopped = true;
      cancelToken.cancel();
    }

    try {
      await _dio.get(
        url,
        cancelToken: cancelToken,
        options: Options(
          connectTimeout: connectTimeout,
          receiveTimeout: receiveTimeout,
        ),
        onReceiveProgress: (count, _) {
          if (_disposed || !mounted) {
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

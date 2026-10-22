import 'package:PiliPlus/utils/cdn_speed_test.dart';
import 'package:dio/dio.dart' show CancelToken, Dio, DioException;
import 'package:flutter/foundation.dart' show debugPrint;

/// 一轮测速里"发请求 + 收样本"的那一层。
///
/// 从 `CdnSwitchMixin._pickFastestCdn` 的局部闭包整块搬出来（2026-10-22 评审
/// Phase 5 / 4.1），**判据、门槛、并发结构一行未改**：先全部发出去、再逐个
/// await、最后统一取消。
///
/// 它只管测速本身：哪些镜像该测、测出来的数怎么比、比完要不要换，仍然是
/// `_pickFastestCdn` 的事。
final class CdnProbeRunner {
  /// 位置参数依次是：测速用的 [Dio]、目标字节偏移、是否小卡顿档、
  /// 「这一轮还算不算数」的惰性判据（`() => !_roundLive(generation)`）。
  CdnProbeRunner(this._dio, this._readOffset, this._quick, this._isCancelled);

  final Dio _dio;

  /// 本轮测速的目标字节偏移。0 = 从头发。
  final int _readOffset;

  /// 小卡顿档：预算 3 秒，字节上限与门槛都跟着它走。
  final bool _quick;

  /// 挂载态而不是 isClosed：被顶掉的那一页（detach 但没换代）也该立刻停采样。
  /// 真机是流式 socket，第一块到达就 stop()，省下这一轮 ~6MiB 的移动流量。
  final bool Function() _isCancelled;

  final List<CancelToken> _tokens = [];
  bool _offsetRejected = false;

  /// 基线回了 416：目标偏移越界，整轮作废。
  ///
  /// 只对**基线**算数 —— 基线那份对象的长度是所有镜像的共同定义。候选回 416
  /// 只说明它自己那份短/不接受这个 range，丢掉它就行，不该连累另外两个已经测
  /// 出可用样本的候选。
  bool get offsetRejected => _offsetRejected;

  /// 测一条 URL。异常原样抛出，由 [guarded] 兜住。
  Future<CdnSample?> sample(String url, {required bool isBaseline}) async {
    final token = CancelToken();
    _tokens.add(token);
    try {
      return await CdnSpeedTest.measureAt(
        _dio,
        url,
        token,
        offset: _readOffset,
        maxBytes: _quick ? CdnSpeedTest.quickBytes : CdnSpeedTest.autoBytes,
        maxMicros: _quick ? CdnSpeedTest.quickMicros : CdnSpeedTest.autoMicros,
        connectTimeout: CdnSpeedTest.probeConnect,
        receiveTimeout: CdnSpeedTest.probeReceive,
        isCancelled: _isCancelled,
      );
    } on DioException catch (e) {
      if (isBaseline && e.response?.statusCode == 416) {
        _offsetRejected = true;
      }
      rethrow;
    }
  }

  /// 兜住任何一路的失败，别让它变成未捕获的异步异常。
  Future<CdnSample?> guarded(
    String url,
    String label, {
    required bool isBaseline,
  }) async {
    try {
      return await sample(url, isBaseline: isBaseline);
    } catch (e) {
      debugPrint('CDN 测速失败 $label: $e');
      return null;
    }
  }

  /// 样本能不能拿来比较。判据在 [CdnSpeedTest.usableSample]：micros 必须为正
  /// （否则 `bytes / micros` 是 Infinity，排序里直接赢下 best），字节门槛跟档位
  /// 走（快速档只有 3 秒预算，用整轮的门槛会把最该采到的样本丢掉），offset > 0
  /// 时服务器必须真的按 Range 回 206。
  bool usable(CdnSample? s) => CdnSpeedTest.usableSample(
    s,
    minBytes: _quick ? CdnSpeedTest.quickMinBytes : CdnSpeedTest.autoMinBytes,
    readOffset: _readOffset,
  );

  /// 收尾：把这一轮发出去的请求全部取消。
  void cancelAll() {
    for (final token in _tokens) {
      if (!token.isCancelled) token.cancel();
    }
  }
}

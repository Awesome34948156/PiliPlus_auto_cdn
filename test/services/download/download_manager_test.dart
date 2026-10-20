import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/services/download/download_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// [DownloadManager] 的 I/O 半边：Range 头、断点续传的拼接、失败清理。
///
/// 服务器用假适配器按请求里的 `Range` 切片返回，网络是这套逻辑里唯一不可
/// 离线复现的部分。
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('download_manager_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('新下载：Range 从 0 开始，落盘字节与服务端一致', () async {
    final payload = List<int>.generate(4096, (i) => i % 251);
    final adapter = _RangeAdapter(payload);
    final dio = Dio()..httpClientAdapter = adapter;
    final file = File(p.join(tempDir.path, 'video.m4s'));
    final progress = <(int, int)>[];
    var doneCalls = 0;
    Object? doneError;

    final manager = DownloadManager(
      url: 'https://mirror.example/video.m4s',
      path: file.path,
      dio: dio,
      onReceiveProgress: (received, total) => progress.add((received, total)),
      onDone: ([error]) {
        doneCalls++;
        doneError = error;
      },
    );
    await manager.task;

    expect(adapter.rangeHeader, 'bytes=0-');
    expect(file.readAsBytesSync(), payload);
    expect(progress, isNotEmpty, reason: '至少要有初始事件');
    expect(progress.first.$1, 0);
    expect(progress.first.$2, payload.length);
    expect(progress.last.$2, payload.length);
    expect(manager.status, DownloadStatus.completed);
    expect(doneCalls, 1);
    expect(doneError, isNull);
  });

  test('断点续传：从已有长度开始，最终文件是前缀 + 剩余字节', () async {
    final payload = List<int>.generate(5000, (i) => i % 241);
    final file = File(p.join(tempDir.path, 'resume.m4s'))
      ..writeAsBytesSync(payload.sublist(0, 2000));
    final adapter = _RangeAdapter(payload);
    final dio = Dio()..httpClientAdapter = adapter;
    final progress = <(int, int)>[];
    Object? doneError;

    final manager = DownloadManager(
      url: 'https://mirror.example/video.m4s',
      path: file.path,
      dio: dio,
      onReceiveProgress: (received, total) => progress.add((received, total)),
      onDone: ([error]) => doneError = error,
    );
    await manager.task;

    expect(adapter.rangeHeader, 'bytes=2000-');
    expect(file.readAsBytesSync(), payload);
    expect(manager.status, DownloadStatus.completed);
    expect(doneError, isNull);
    // 续传不先报 (0, total)；只要有一次读数到达总长即可。
    expect(progress, isNotEmpty);
    expect(progress.every((event) => event.$2 == payload.length), isTrue);
    expect(progress.any((event) => event.$1 == payload.length), isTrue);
  });

  test('失败：状态码不在白名单时回错误、删半成品', () async {
    final adapter = _RangeAdapter(const [], statusCode: 500);
    final dio = Dio()..httpClientAdapter = adapter;
    final file = File(p.join(tempDir.path, 'broken.m4s'));
    Object? doneError;

    final manager = DownloadManager(
      url: 'https://mirror.example/video.m4s',
      path: file.path,
      dio: dio,
      onReceiveProgress: null,
      onDone: ([error]) => doneError = error,
    );
    await manager.task;

    expect(manager.status, DownloadStatus.failDownload);
    expect(doneError, isA<DioException>());
    expect(file.existsSync(), isFalse, reason: '失败时删掉写了一半的文件');
  });
}

/// 按请求里的 `Range: bytes=N-` 返回 `body[N..]`，并记下实际请求头。
class _RangeAdapter implements HttpClientAdapter {
  _RangeAdapter(this.body, {this.statusCode = 206});

  final List<int> body;
  final int statusCode;

  String? rangeHeader;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    rangeHeader = _header(options, 'range');
    var start = 0;
    final match = RegExp(r'bytes=(\d+)-').firstMatch(rangeHeader ?? '');
    if (match != null) start = int.parse(match.group(1)!);
    final slice = Uint8List.fromList(body.sublist(start.clamp(0, body.length)));
    return ResponseBody(
      Stream.value(slice),
      statusCode,
      headers: {
        Headers.contentLengthHeader: ['${slice.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}

  static String? _header(RequestOptions options, String name) {
    for (final entry in options.headers.entries) {
      if (entry.key.toLowerCase() == name) return '${entry.value}';
    }
    return null;
  }
}

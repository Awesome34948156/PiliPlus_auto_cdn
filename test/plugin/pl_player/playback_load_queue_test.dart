import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/playback_load_queue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('完整装载串行执行，B 等 A 离开后才开始', () async {
    final queue = PlaybackLoadQueue();
    final releaseA = Completer<void>();
    final startA = Completer<void>();
    final events = <String>[];

    final a = queue.run((isCurrent) async {
      events.add('a:start');
      startA.complete();
      await releaseA.future;
      if (isCurrent()) events.add('a:commit');
      events.add('a:end');
    });
    await startA.future;

    final b = queue.run((isCurrent) async {
      expect(isCurrent(), isTrue);
      events
        ..add('b:start')
        ..add('b:commit');
    });
    expect(queue.busy, isTrue);

    releaseA.complete();
    await Future.wait([a, b]);

    expect(events, ['a:start', 'a:end', 'b:start', 'b:commit']);
    expect(queue.busy, isFalse);
  });

  test('连续请求只有最后一代执行', () async {
    final queue = PlaybackLoadQueue();
    final releaseA = Completer<void>();
    final startA = Completer<void>();
    final events = <String>[];

    final a = queue.run((isCurrent) async {
      events.add('a:start');
      startA.complete();
      await releaseA.future;
      if (isCurrent()) events.add('a:commit');
    });
    await startA.future;

    final b = queue.run((_) async {
      events.add('b:start');
    });
    final c = queue.run((_) async {
      events.add('c:start');
    });

    releaseA.complete();
    await Future.wait([a, b, c]);
    expect(events, ['a:start', 'c:start']);
  });

  test('前一个请求失败不会毒化队列或卡住 processing', () async {
    final queue = PlaybackLoadQueue();
    final started = Completer<void>();
    final failed = queue.run((_) {
      started.complete();
      throw StateError('load failed');
    });
    final failedExpectation = expectLater(failed, throwsStateError);
    await started.future;

    final next = queue.run((isCurrent) async {
      expect(isCurrent(), isTrue);
    });

    await failedExpectation;
    await next;
    expect(queue.busy, isFalse);
  });
}

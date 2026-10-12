import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

class PlayOrPauseButton extends StatefulWidget {
  final PlPlayerController plPlayerController;

  const PlayOrPauseButton({
    super.key,
    required this.plPlayerController,
  });

  @override
  PlayOrPauseButtonState createState() => PlayOrPauseButtonState();
}

class PlayOrPauseButtonState extends State<PlayOrPauseButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;
  StreamSubscription<bool>? subscription;

  /// 当前订阅的那个 player。**不能**在 initState 里抓一次就当常量：
  /// 渲染上下文被就地重建（[PlPlayerController.renderContextGen]）时 player 会换成
  /// 另一个对象，而本 State 不会重建 —— 钉在已 dispose 的那个上，图标与语义标签
  /// 此后就不再跟随播放状态了。见 [didUpdateWidget]。
  Player? player;

  @override
  void initState() {
    super.initState();
    // 重建窗口里 videoPlayerController 是 null（旧 player 已拆、新的还没建），
    // 这里不能再 `!` 强解 —— 控制条正好在这段时间重挂就会崩。
    final player = widget.plPlayerController.videoPlayerController;
    this.player = player;
    controller = AnimationController(
      vsync: this,
      value: player != null && player.state.playing ? 1 : 0,
      duration: const Duration(milliseconds: 200),
    );
    if (player != null) {
      _bind(player);
    }
  }

  @override
  void didUpdateWidget(covariant PlayOrPauseButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    final current = widget.plPlayerController.videoPlayerController;
    if (identical(current, player)) return;
    subscription?.cancel();
    subscription = null;
    player = current;
    controller.value = current != null && current.state.playing ? 1 : 0;
    if (current != null) {
      _bind(current);
    }
  }

  void _bind(Player player) {
    subscription = player.stream.playing.listen((playing) {
      if (playing) {
        controller.forward();
      } else {
        controller.reverse();
      }
    });
  }

  @override
  void dispose() {
    subscription?.cancel();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playing = player?.state.playing ?? false;
    return SizedBox(
      width: 42,
      height: 34,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.plPlayerController.onDoubleTapCenter,
        child: Center(
          child: AnimatedIcon(
            semanticLabel: playing ? '暂停' : '播放',
            progress: controller,
            icon: AnimatedIcons.play_pause,
            color: Colors.white,
            size: 20,
          ),
        ),
      ),
    );
  }
}

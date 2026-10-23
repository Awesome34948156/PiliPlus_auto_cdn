/// 系统「正在播放」期间持有独占音频会话的最小接口。
///
/// 播放器服务只需要“开始/停止守卫”这两个动作，不需要认识 AudioSessionHandler。
/// 把接口放在无依赖的叶子模块里，由 service locator 注入实现，可以避免
/// `audio_handler -> service_locator/audio_session -> controller` 的循环依赖。
abstract interface class NowPlayingGuard {
  void start(Object holder);

  void stop(Object holder);
}

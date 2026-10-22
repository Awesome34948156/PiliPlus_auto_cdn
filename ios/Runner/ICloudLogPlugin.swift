import Flutter
import UIKit
import UniformTypeIdentifiers

/// 把 `pili-console.log` 同步到用户选的 iCloud Drive 文件夹。
///
/// 为什么是"用户选文件夹"而不是 app 自己的 iCloud 容器：那需要
/// `com.apple.developer.icloud-container-identifiers` 一类的 entitlement 进
/// provisioning profile，而这个包是 AltSign 侧载的。document picker + 安全作用域
/// 书签是**不需要任何 entitlement** 的唯一办法。
///
/// 分工：Dart 那边只负责在写入串行链上把日志**快照**到一个 staging 文件，
/// 然后调 [uploadLog]。真正落进 iCloud 的写在这里做 —— 这样安全作用域的
/// `startAccessing`/`stopAccessing` 全程在一处配对，不用跨 method channel 维护
/// 引用计数。**泄漏 `startAccessing` 会耗尽 app 后续添加文件位置的能力**
/// （之后再选文件夹会失败），所以只在换绑/解绑时 `stop`，不每次拷贝配一对。
final class ICloudLogPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
  private static let channelName = "com.example.piliplus/icloud_log"

  /// 在线的那一份。注意它**不匹配** [archivePrefix]，所以清理时不会把自己删掉。
  private static let liveName = "pili-console.log"
  private static let archivePrefix = "pili-console-"
  private static let archiveSuffix = ".log"

  /// 存档保留份数。超出的按修改时间从旧到新删。
  private static let maxArchives = 10

  private let channel: FlutterMethodChannel

  /// 所有碰文件夹的操作都排在这一条队列上：解析 bookmark、存档、上传。
  ///
  /// 单开一条而不是用主队列，是因为 `URL(resolvingBookmarkData:)` 撞上
  /// FileProvider 做维护时**实测能卡近一分钟**，放主线程就是卡 UI。
  private let opQueue = DispatchQueue(label: "com.example.piliplus.icloud_log")

  /// 解析好的目录 + 已生效的安全作用域，持有到进程结束（或用户换绑）。
  /// 只在 [opQueue] 上读写。
  private var heldURL: URL?

  /// 存档每个进程只做一次 —— 就是"新会话把上一份顶掉之前"那一次。
  private var didArchive = false

  private var pendingPick: FlutterResult?
  private var presentedPicker: UIDocumentPickerViewController?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    let instance = ICloudLogPlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  private init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "isAvailable":
      result(true)

    case "pickFolder":
      pickFolder(result: result)

    case "resolve":
      guard let data = (args["bookmark"] as? FlutterStandardTypedData)?.data else {
        result(FlutterError(code: "ARGS", message: "bookmark is required", details: nil))
        return
      }
      resolve(bookmark: data, result: result)

    case "clearAccess":
      opQueue.async { [weak self] in
        self?.releaseHeld()
        DispatchQueue.main.async { result(nil) }
      }

    case "uploadLog":
      guard let staging = args["stagingPath"] as? String else {
        result(FlutterError(code: "ARGS", message: "stagingPath is required", details: nil))
        return
      }
      // 租约必须在这里（平台线程 = 主线程）拿：`beginBackgroundTask` 是
      // `UIApplication` 的主线程 API，旧写法把它留在了 opQueue 里。
      upload(stagingPath: staging, lease: BackgroundTaskLease(), result: result)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - 选文件夹

  private func pickFolder(result: @escaping FlutterResult) {
    // 一次只弹一个：第二次调用直接报错，不然 pendingPick 会被覆盖掉、
    // 第一次那个 FlutterResult 永远不回，Dart 那边就永久挂起。
    guard pendingPick == nil, presentedPicker == nil else {
      result(FlutterError(code: "BUSY", message: "already picking", details: nil))
      return
    }
    guard let host = ICloudLogPlugin.hostViewController() else {
      result(FlutterError(code: "NO_VC", message: "no view controller", details: nil))
      return
    }
    pendingPick = result
    let picker = UIDocumentPickerViewController(
      forOpeningContentTypes: [UTType.folder],
      asCopy: false
    )
    picker.delegate = self
    picker.allowsMultipleSelection = false
    // iPad 上它是 popover，不设 sourceView/sourceRect **必崩** —— 这个 app 支持 iPad。
    if let popover = picker.popoverPresentationController {
      popover.sourceView = host.view
      popover.sourceRect = host.view.bounds
      popover.permittedArrowDirections = []
    }
    presentedPicker = picker
    host.present(picker, animated: true)
    // `present` 失败（宿主已在呈现别的 VC、或正处于呈现动画里）时 UIKit 只打一条
    // 警告：两个 delegate 回调都不会来，于是 pendingPick / presentedPicker 永久
    // 非空，此后每次调用都只回 `BUSY`。挂上一秒后复查：没被任何 VC 领走就自己
    // 收尾，把状态和 FlutterResult 一起还回去。
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      guard let self, self.presentedPicker === picker,
        picker.presentingViewController == nil,
        !picker.isBeingPresented, !picker.isBeingDismissed
      else { return }
      self.presentedPicker = nil
      let reply = self.pendingPick
      self.pendingPick = nil
      reply?(
        FlutterError(code: "NO_SHOW", message: "picker failed to present", details: nil))
    }
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    presentedPicker = nil
    let reply = pendingPick
    pendingPick = nil
    guard let reply else { return }
    guard let url = urls.first else {
      reply(nil) // 理论上不会：didPick 一定带 URL
      return
    }
    // ⚠️ **先拿访问权、再建书签。** 反过来是真机实测踩过的坑（2026-10-12）：
    // `bookmarkData` 抛 `The file couldn't be opened because it doesn't exist.`
    // （NSFileNoSuchFileError）。在授权之前，iCloud Drive 那条 FileProvider 连
    // "这个条目存在吗" 都不会回答，于是从 app 的沙箱看它就是不存在。
    guard url.startAccessingSecurityScopedResource() else {
      reply(FlutterError(
        code: "NO_ACCESS",
        message: "startAccessingSecurityScopedResource returned false",
        details: nil
      ))
      return
    }
    do {
      // 书签必须**当场**建 —— 此刻这个 URL 的安全作用域还有效。
      // `.minimalBookmark`：`.withSecurityScope` 是 macOS 的，在 iOS 上不适用。
      let data = try url.bookmarkData(
        options: .minimalBookmark,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      opQueue.async { [weak self] in
        guard let self else { return }
        self.releaseHeld()
        self.heldURL = url // 已 startAccessing，持有到换绑
        // `FlutterResult` 是平台线程（主线程）契约：在 opQueue 上回调会让引擎
        // 侧断言/丢弃结果，Dart 的 await 就永久挂起。
        DispatchQueue.main.async {
          reply([
            "bookmark": FlutterStandardTypedData(bytes: data),
            "path": url.path,
          ])
        }
      }
    } catch {
      // 建书签没成，刚开的那个访问权就得还回去 —— 泄漏 `startAccessing`
      // 会耗尽 app 后续添加文件位置的能力。
      url.stopAccessingSecurityScopedResource()
      reply(FlutterError(code: "BOOKMARK", message: error.localizedDescription, details: nil))
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    presentedPicker = nil
    let reply = pendingPick
    pendingPick = nil
    // 取消也要回 —— 不回的话 Dart 那边的 await 永久挂起。
    reply?(nil)
  }

  // MARK: - 解析 / 释放

  private func resolve(bookmark data: Data, result: @escaping FlutterResult) {
    opQueue.async { [weak self] in
      guard let self else { return }
      self.releaseHeld()
      do {
        var stale = false
        let url = try URL(
          resolvingBookmarkData: data,
          // `.withSecurityScope` 是 macOS 的；iOS 上要 startAccessing 显式开。
          options: [.withoutUI, .withoutMounting],
          relativeTo: nil,
          bookmarkDataIsStale: &stale
        )
        guard url.startAccessingSecurityScopedResource() else {
          DispatchQueue.main.async {
            result(FlutterError(
              code: "NO_ACCESS",
              message: "startAccessingSecurityScopedResource returned false",
              details: nil
            ))
          }
          return
        }
        self.heldURL = url
        // 新会话第一次拿到访问权时，把上一份日志存档 —— 必须赶在 Dart 那边
        // 第一次上传之前，否则会被直接覆盖掉。每个进程只做一次。
        if !self.didArchive {
          self.didArchive = true
          self.archivePrevious(in: url)
        }
        DispatchQueue.main.async {
          result(["path": url.path, "stale": stale])
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "RESOLVE", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func releaseHeld() {
    heldURL?.stopAccessingSecurityScopedResource()
    heldURL = nil
  }

  // MARK: - 存档 / 清理

  /// 把 `<文件夹>/pili-console.log` 按它自己的修改时间改名成
  /// `pili-console-<MMdd-HHmmss>.log`，再把多出来的旧存档删掉。
  ///
  /// **只碰严格匹配我们自己命名的文件**，用户文件夹里别的东西一个都不动。
  /// 失败一律静默：存档是锦上添花，不能因为它让同步整个失败。
  private func archivePrevious(in folder: URL) {
    let fm = FileManager.default
    let live = folder.appendingPathComponent(ICloudLogPlugin.liveName)
    if let attrs = try? fm.attributesOfItem(atPath: live.path),
      let mtime = attrs[.modificationDate] as? Date
    {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = "MMdd-HHmmss"
      let archived = folder.appendingPathComponent(
        "\(ICloudLogPlugin.archivePrefix)\(formatter.string(from: mtime))\(ICloudLogPlugin.archiveSuffix)"
      )
      try? fm.removeItem(at: archived) // 同一秒重启两次时先让位
      try? fm.moveItem(at: live, to: archived)
    }
    pruneArchives(in: folder)
  }

  private func pruneArchives(in folder: URL) {
    let fm = FileManager.default
    guard
      let names = try? fm.contentsOfDirectory(atPath: folder.path)
    else { return }
    let archives = names
      .filter {
        $0.hasPrefix(ICloudLogPlugin.archivePrefix)
          && $0.hasSuffix(ICloudLogPlugin.archiveSuffix)
      }
      .compactMap { name -> (String, Date)? in
        let path = folder.appendingPathComponent(name).path
        guard let attrs = try? fm.attributesOfItem(atPath: path),
          let date = attrs[.modificationDate] as? Date
        else { return nil }
        return (name, date)
      }
      .sorted { $0.1 > $1.1 } // 新的在前
    guard archives.count > ICloudLogPlugin.maxArchives else { return }
    for (name, _) in archives.dropFirst(ICloudLogPlugin.maxArchives) {
      try? fm.removeItem(at: folder.appendingPathComponent(name))
    }
  }

  // MARK: - 上传

  /// 把 staging 文件原子地写成 `<文件夹>/pili-console.log`。
  ///
  /// **永远不重读 app 本地那份 `pili-console.log`** —— 它随时可能被
  /// `console_log.dart` 的轮换截断，读到的会是空文件。Dart 那边已经先在
  /// 写入串行链上拷好了 staging。
  private func upload(
    stagingPath: String,
    lease: BackgroundTaskLease?,
    result: @escaping FlutterResult
  ) {
    opQueue.async { [weak self] in
      defer { lease?.end() }
      guard let self else { return }
      guard let folder = self.heldURL else {
        DispatchQueue.main.async {
          result(FlutterError(code: "NO_FOLDER", message: "no folder bound", details: nil))
        }
        return
      }
      let staging = URL(fileURLWithPath: stagingPath)
      guard let data = try? Data(contentsOf: staging) else {
        DispatchQueue.main.async {
          result(FlutterError(code: "STAGING", message: "cannot read staging", details: nil))
        }
        return
      }

      // 后台任务租约由调用方在主线程拿好（见 [BackgroundTaskLease]），
      // `defer { lease?.end() }` 在这一层结束时归还。
      let dest = folder.appendingPathComponent(ICloudLogPlugin.liveName)
      var coordError: NSError?
      var writeError: Error?
      NSFileCoordinator().coordinate(
        writingItemAt: dest,
        options: .forReplacing,
        error: &coordError
      ) { url in
        do {
          try data.write(to: url, options: .atomic)
        } catch {
          writeError = error
        }
      }
      let failure = writeError ?? coordError
      DispatchQueue.main.async {
        if let failure {
          result(FlutterError(
            code: "WRITE",
            message: failure.localizedDescription,
            details: nil
          ))
        } else {
          result(nil)
        }
      }
    }
  }

  // MARK: - 后台任务租约

  /// 一次上传期间的"别把我挂起"租约。
  ///
  /// 旧写法有三个问题：`beginBackgroundTask` 在 opQueue（后台线程）上调用，
  /// 是 `UIApplication` 的主线程 API；过期回调与 `defer` 并发读写同一个
  /// `token` 变量；过期回调里 `end` 之后 `defer` 又 `end` 一次（令牌可能已被
  /// 系统回收复用）。这里把开始/结束都收敛到主线程，令牌用锁保护、只允许
  /// 结束一次。
  private final class BackgroundTaskLease {
    private let lock = NSLock()
    private var token: UIBackgroundTaskIdentifier = .invalid

    /// **只在主线程调用**（`handle` 的平台线程就是主线程）。
    init() {
      let started = UIApplication.shared.beginBackgroundTask(withName: "icloud-log-upload") {
        [weak self] in
        // 过期回调在主线程：系统要收回后台时间，立刻归还，别让 app 被杀。
        self?.end()
      }
      if started != .invalid {
        token = started
      }
    }

    func end() {
      lock.lock()
      let t = token
      token = .invalid
      lock.unlock()
      guard t != .invalid else { return }
      if Thread.isMainThread {
        UIApplication.shared.endBackgroundTask(t)
      } else {
        DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(t) }
      }
    }
  }

  // MARK: - 找宿主

  /// 与 `PipPlugin.hostWindow()` 同一招：拿承载 Flutter 的那个 window。
  private static func hostViewController() -> UIViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
    let root = windows.first { $0.rootViewController is FlutterViewController }?
      .rootViewController
      ?? windows.first { $0.isKeyWindow }?.rootViewController
    // 已经在弹别的东西时不能再 present，否则 UIKit 会警告并静默丢弃。
    // `isBeingDismissed` 那一半是给「Dart 那边刚 Get.back() 关掉对话框、
    // 紧接着就调 pickFolder」准备的：此刻上层正处在关闭动画里，从它身上
    // present 会撞上 "while a presentation is in progress"。退回下面那层，
    // UIKit 会把这次 present 排在动画之后。
    var top = root
    while let presented = top?.presentedViewController,
      !presented.isBeingDismissed
    {
      top = presented
    }
    return top
  }
}

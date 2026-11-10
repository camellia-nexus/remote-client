import Cocoa
import AVFoundation
import FlutterMacOS
import desktop_multi_window
// import bitsdojo_window_macos

import desktop_drop
import device_info_plus
import file_picker
import file_selector_macos
import flutter_custom_cursor
import package_info_plus
import screen_retriever
import sqflite_darwin
// import tray_manager
import uni_links_desktop
import url_launcher_macos
import wakelock_plus
import window_manager
import window_size
import texture_rgba_renderer

// Global state and coordinator for relative mouse mode.
// All properties and methods must be accessed on the main thread since they
// interact with NSEvent monitors, CoreGraphics APIs, and Flutter channels.
struct RelativeMouseOwner: Equatable {
    let windowId: Int64
    let sessionId: String
    let generation: UInt64
}

class RelativeMouseState {
    static let shared = RelativeMouseState()

    var enabled: Bool {
        return isLocked
    }

    private(set) var isLocked = false
    private(set) var currentOwner: RelativeMouseOwner?
    private(set) var activeGeneration: UInt64 = 0

    var eventMonitor: Any?
    var deltaChannel: FlutterMethodChannel?
    weak var ownerWindow: NSWindow?
    var accumulatedDeltaX: CGFloat = 0
    var accumulatedDeltaY: CGFloat = 0

    // Monotonic generation counter for re-association retries so outdated callbacks never unlock active mode
    private(set) var retryGeneration: UInt64 = 0
    private var windowCloseObserver: Any?
    private var appTerminateObserver: Any?

    private init() {
        setupLifecycleObservers()
    }

    deinit {
        if let observer = windowCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = appTerminateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupLifecycleObservers() {
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleWindowWillClose(notification)
        }

        appTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppWillTerminate()
        }
    }

    private func handleWindowWillClose(_ notification: Notification) {
        assert(Thread.isMainThread)
        guard isLocked, let owner = currentOwner else { return }
        guard let closingWindow = notification.object as? NSWindow else { return }

        // If the closing window is the active owner's window, auto-release relative mouse mode
        if (ownerWindow != nil && closingWindow == ownerWindow) || (owner.windowId == 0 && closingWindow is MainFlutterWindow) {
            NSLog("[Camellia] Owner window closing for sessionId=%@ windowId=%lld gen=%llu, auto-releasing relative mouse mode",
                  owner.sessionId, owner.windowId, owner.generation)
            forceRelease()
        }
    }

    private func handleAppWillTerminate() {
        if isLocked {
            NSLog("[Camellia] App terminating while relative mouse active, force re-associating cursor")
            forceRelease()
        }
    }

    func forceRelease() {
        assert(Thread.isMainThread)
        guard isLocked else { return }

        retryGeneration &+= 1

        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }

        deltaChannel = nil
        ownerWindow = nil
        accumulatedDeltaX = 0
        accumulatedDeltaY = 0
        currentOwner = nil
        isLocked = false

        let result = CGAssociateMouseAndMouseCursorPosition(1)
        if result != CGError.success {
            NSLog("[Camellia] forceRelease failed to re-associate mouse: %d, scheduling bounded retry", result.rawValue)
            scheduleBoundedRetry(retryGen: self.retryGeneration, remainingAttempts: 3)
        }
    }

    func scheduleBoundedRetry(retryGen: UInt64, remainingAttempts: Int) {
        guard remainingAttempts > 0 else {
            NSLog("[Camellia] Re-association retry budget exhausted. Cursor may remain locked.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self else { return }
            assert(Thread.isMainThread)
            guard self.retryGeneration == retryGen && !self.isLocked else {
                NSLog("[Camellia] Stale cursor re-association retry ignored (retryGen=%llu, currentGen=%llu, isLocked=%d)",
                      retryGen, self.retryGeneration, self.isLocked ? 1 : 0)
                return
            }
            let retryResult = CGAssociateMouseAndMouseCursorPosition(1)
            if retryResult != CGError.success {
                NSLog("[Camellia] Retry failed to re-associate mouse: %d, remaining attempts: %d", retryResult.rawValue, remainingAttempts - 1)
                self.scheduleBoundedRetry(retryGen: retryGen, remainingAttempts: remainingAttempts - 1)
            } else {
                NSLog("[Camellia] Mouse cursor successfully re-associated on retry.")
            }
        }
    }

    enum EnableError: Error {
        case conflict(owner: RelativeMouseOwner)
        case cgError(code: Int32)
        case monitorError
    }

    func enable(channel: FlutterMethodChannel,
                window: NSWindow?,
                windowId: Int64,
                sessionId: String,
                generation: UInt64) -> Result<Bool, EnableError> {
        assert(Thread.isMainThread, "enable must be called on the main thread")

        // Cancel any pending re-association retry from previous release
        retryGeneration &+= 1

        if isLocked {
            guard let owner = currentOwner else {
                isLocked = false
                return .failure(.conflict(owner: RelativeMouseOwner(windowId: -1, sessionId: "unknown", generation: 0)))
            }

            // Same session and window re-enabling or updating channel
            if owner.windowId == windowId && owner.sessionId == sessionId {
                currentOwner = RelativeMouseOwner(windowId: windowId, sessionId: sessionId, generation: generation)
                activeGeneration = generation
                deltaChannel = channel
                if window != nil {
                    ownerWindow = window
                }
                return .success(true)
            } else {
                // Different owner attempted to take over: reject with typed conflict
                NSLog("[Camellia] Relative mouse enable rejected: locked by windowId=%lld sessionId=%@ gen=%llu; requested by windowId=%lld sessionId=%@ gen=%llu",
                      owner.windowId, owner.sessionId, owner.generation, windowId, sessionId, generation)
                return .failure(.conflict(owner: owner))
            }
        }

        // Dissociate mouse from cursor position FIRST before mutating state
        let cgResult = CGAssociateMouseAndMouseCursorPosition(0)
        if cgResult != CGError.success {
            NSLog("[Camellia] Failed to dissociate mouse from cursor position: %d", cgResult.rawValue)
            return .failure(.cgError(code: cgResult.rawValue))
        }

        deltaChannel = channel
        ownerWindow = window
        accumulatedDeltaX = 0
        accumulatedDeltaY = 0
        currentOwner = RelativeMouseOwner(windowId: windowId, sessionId: sessionId, generation: generation)
        activeGeneration = generation

        // Event monitor capturing relative deltas
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] event in
            guard let self = self else { return event }
            guard self.isLocked, let owner = self.currentOwner else { return event }
            // Verify generation hasn't changed
            guard owner.generation == self.activeGeneration else { return event }

            let deltaX = event.deltaX
            let deltaY = event.deltaY

            if deltaX != 0 || deltaY != 0 {
                self.accumulatedDeltaX += deltaX
                self.accumulatedDeltaY += deltaY

                let intX = Int(self.accumulatedDeltaX)
                let intY = Int(self.accumulatedDeltaY)

                if intX != 0 || intY != 0 {
                    self.accumulatedDeltaX -= CGFloat(intX)
                    self.accumulatedDeltaY -= CGFloat(intY)

                    // Deliver delta to active owner channel with generation fencing
                    self.deltaChannel?.invokeMethod("onMouseDelta", arguments: [
                        "dx": intX,
                        "dy": intY,
                        "sessionId": owner.sessionId,
                        "generation": owner.generation
                    ])
                }
            }

            return event
        }

        if eventMonitor == nil {
            NSLog("[Camellia] Failed to create event monitor for relative mouse mode")
            CGAssociateMouseAndMouseCursorPosition(1)
            deltaChannel = nil
            ownerWindow = nil
            currentOwner = nil
            return .failure(.monitorError)
        }

        isLocked = true
        return .success(true)
    }

    enum DisableError: Error {
        case notOwner(owner: RelativeMouseOwner)
        case staleGeneration(activeGen: UInt64)
        case cgError(code: Int32)
    }

    func disable(windowId: Int64,
                 sessionId: String,
                 generation: UInt64) -> Result<Bool, DisableError> {
        assert(Thread.isMainThread, "disable must be called on the main thread")

        if !isLocked {
            return .success(true)
        }

        guard let owner = currentOwner else {
            forceRelease()
            return .success(true)
        }

        // Only the active owner can release
        if owner.windowId != windowId || owner.sessionId != sessionId {
            NSLog("[Camellia] Non-owner attempted to disable relative mouse: owner=(windowId=%lld sessionId=%@ gen=%llu), caller=(windowId=%lld sessionId=%@ gen=%llu)",
                  owner.windowId, owner.sessionId, owner.generation, windowId, sessionId, generation)
            return .failure(.notOwner(owner: owner))
        }

        if generation < owner.generation {
            NSLog("[Camellia] Stale disable generation: caller gen=%llu < active owner gen=%llu", generation, owner.generation)
            return .failure(.staleGeneration(activeGen: owner.generation))
        }

        // Invalidate any previous or current retry timers
        retryGeneration &+= 1

        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }

        deltaChannel = nil
        ownerWindow = nil
        accumulatedDeltaX = 0
        accumulatedDeltaY = 0
        currentOwner = nil
        isLocked = false

        let cgResult = CGAssociateMouseAndMouseCursorPosition(1)
        if cgResult != CGError.success {
            NSLog("[Camellia] Failed to re-associate mouse cursor: %d, scheduling bounded retry...", cgResult.rawValue)
            scheduleBoundedRetry(retryGen: self.retryGeneration, remainingAttempts: 3)
            return .failure(.cgError(code: cgResult.rawValue))
        }

        return .success(true)
    }
}

class MainFlutterWindow: NSWindow {
    override func awakeFromNib() {
        camellia_remote_core_main();
        let flutterViewController = FlutterViewController.init()
        let windowFrame = self.frame
        self.contentViewController = flutterViewController
        self.setFrame(windowFrame, display: true)
        // register self method handler
        let registrar = flutterViewController.registrar(forPlugin: "RustDeskPlugin")
        setMethodHandler(registrar: registrar)

        RegisterGeneratedPlugins(registry: flutterViewController)

        FlutterMultiWindowPlugin.setOnWindowCreatedCallback { controller in
            // Keep this in sync with GeneratedPluginRegistrant. The multi-window
            // plugin has already registered its child-window channel at this point.
            self.setMethodHandler(registrar: controller.registrar(forPlugin: "RustDeskPlugin"))
            DesktopDropPlugin.register(with: controller.registrar(forPlugin: "DesktopDropPlugin"))
            DeviceInfoPlusMacosPlugin.register(with: controller.registrar(forPlugin: "DeviceInfoPlusMacosPlugin"))
            FilePickerPlugin.register(with: controller.registrar(forPlugin: "FilePickerPlugin"))
            FileSelectorPlugin.register(with: controller.registrar(forPlugin: "FileSelectorPlugin"))
            FlutterCustomCursorPlugin.register(with: controller.registrar(forPlugin: "FlutterCustomCursorPlugin"))
            FPPPackageInfoPlusPlugin.register(with: controller.registrar(forPlugin: "FPPPackageInfoPlusPlugin"))
            ScreenRetrieverPlugin.register(with: controller.registrar(forPlugin: "ScreenRetrieverPlugin"))
            SqflitePlugin.register(with: controller.registrar(forPlugin: "SqflitePlugin"))
            TextureRgbaRendererPlugin.register(with: controller.registrar(forPlugin: "TextureRgbaRendererPlugin"))
            UniLinksDesktopPlugin.register(with: controller.registrar(forPlugin: "UniLinksDesktopPlugin"))
            UrlLauncherPlugin.register(with: controller.registrar(forPlugin: "UrlLauncherPlugin"))
            WakelockPlusMacosPlugin.register(with: controller.registrar(forPlugin: "WakelockPlusMacosPlugin"))
            WindowManagerPlugin.register(with: controller.registrar(forPlugin: "WindowManagerPlugin"))
            WindowSizePlugin.register(with: controller.registrar(forPlugin: "WindowSizePlugin"))
        }

        super.awakeFromNib()
    }

    override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        super.order(place, relativeTo: otherWin)
        hiddenWindowAtLaunch()
    }

    /// Override window theme.
    public func setWindowInterfaceMode(window: NSWindow, themeName: String) {
        window.appearance = NSAppearance(named: themeName == "light" ? .aqua : .darkAqua)
    }

    private func enableNativeRelativeMouseMode(channel: FlutterMethodChannel,
                                               window: NSWindow?,
                                               windowId: Int64,
                                               sessionId: String,
                                               generation: UInt64) -> Result<Bool, RelativeMouseState.EnableError> {
        return RelativeMouseState.shared.enable(channel: channel,
                                                window: window,
                                                windowId: windowId,
                                                sessionId: sessionId,
                                                generation: generation)
    }

    private func disableNativeRelativeMouseMode(windowId: Int64,
                                                sessionId: String,
                                                generation: UInt64) -> Result<Bool, RelativeMouseState.DisableError> {
        return RelativeMouseState.shared.disable(windowId: windowId,
                                                 sessionId: sessionId,
                                                 generation: generation)
    }

    public func setMethodHandler(registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.camellia.remote/host", binaryMessenger: registrar.messenger)
        channel.setMethodCallHandler({
            (call, result) -> Void in
                switch call.method {
                case "setWindowTheme":
                    let arg = call.arguments as! [String: Any]
                    let themeName = arg["themeName"] as? String
                    guard let window = registrar.view?.window else {
                        result(nil)
                        return
                    }
                    self.setWindowInterfaceMode(window: window,themeName: themeName ?? "light")
                    result(nil)
                    break;
                case "terminate":
                    NSApplication.shared.terminate(self)
                    result(nil)
                case "canRecordAudio":
                    switch AVCaptureDevice.authorizationStatus(for: .audio) {
                    case .authorized:
                        result(1)
                        break
                    case .notDetermined:
                        result(0)
                        break
                    default:
                        result(-1)
                        break
                    }
                case "requestRecordAudio":
                    AVCaptureDevice.requestAccess(for: .audio, completionHandler: { granted in
                        DispatchQueue.main.async {
                            result(granted)
                        }
                    })
                    break
                case "bumpMouse":
                    var dx = 0
                    var dy = 0

                    if let argMap = call.arguments as? [String: Any] {
                        dx = (argMap["dx"] as? Int) ?? 0
                        dy = (argMap["dy"] as? Int) ?? 0
                    }
                    else if let argList = call.arguments as? [Any] {
                        dx = argList.count >= 1 ? (argList[0] as? Int) ?? 0 : 0
                        dy = argList.count >= 2 ? (argList[1] as? Int) ?? 0 : 0
                    }

                    var mouseLoc: CGPoint

                    if let dummyEvent = CGEvent(source: nil) { // can this ever fail?
                        mouseLoc = dummyEvent.location
                    }
                    else if let screenFrame = NSScreen.screens.first?.frame {
                        // NeXTStep: Origin is lower-left of primary screen, positive is up
                        // Cocoa Core Graphics: Origin is upper-left of primary screen, positive is down
                        let nsMouseLoc = NSEvent.mouseLocation

                        mouseLoc = CGPoint(
                            x: nsMouseLoc.x,
                            y: NSHeight(screenFrame) - nsMouseLoc.y)
                    }
                    else {
                        result(false)
                        break
                    }

                    let newLoc = CGPoint(x: mouseLoc.x + CGFloat(dx), y: mouseLoc.y + CGFloat(dy))

                    CGDisplayMoveCursorToPoint(0, newLoc)

                    // By default, Cocoa suppresses mouse events briefly after a call to warp the
                    // cursor to a new location. This is good if you want to draw the user's
                    // attention to the fact that the mouse is now in a particular location, but
                    // it's bad in this case; we get called as part of the handling of edge
                    // scrolling, which means the mouse is typically still in motion, and we want
                    // the cursor to keep moving smoothly uninterrupted.
                    //
                    // This function's main action is to toggle whether the mouse cursor is
                    // associated with the mouse position, but setting it to true when it's
                    // already true has the side-effect of cancelling this motion suppression.
                    //
                    // However, we must NOT call this when relative mouse mode is active,
                    // as it would break the pointer lock established by enableNativeRelativeMouseMode.
                    if !RelativeMouseState.shared.enabled {
                        CGAssociateMouseAndMouseCursorPosition(1 /* true */)
                    }

                    result(true)

                case "enableNativeRelativeMouseMode":
                    guard let argMap = call.arguments as? [String: Any],
                          let windowId = (argMap["windowId"] as? NSNumber)?.int64Value,
                          let sessionId = argMap["sessionId"] as? String,
                          let generation = (argMap["generation"] as? NSNumber)?.uint64Value else {
                        result(FlutterError(code: "INVALID_ARGUMENT",
                                            message: "enableNativeRelativeMouseMode requires windowId, sessionId, and generation",
                                            details: nil))
                        break
                    }
                    let targetWindow = registrar.view?.window ?? (self as NSWindow)
                    let enableResult = self.enableNativeRelativeMouseMode(channel: channel,
                                                                         window: targetWindow,
                                                                         windowId: windowId,
                                                                         sessionId: sessionId,
                                                                         generation: generation)
                    switch enableResult {
                    case .success(let val):
                        result(val)
                    case .failure(let err):
                        switch err {
                        case .conflict(let owner):
                            result(FlutterError(code: "OWNER_CONFLICT",
                                                message: "Relative mouse is locked by windowId=\(owner.windowId) sessionId=\(owner.sessionId) gen=\(owner.generation)",
                                                details: [
                                                    "ownerWindowId": owner.windowId,
                                                    "ownerSessionId": owner.sessionId,
                                                    "ownerGeneration": owner.generation
                                                ]))
                        case .cgError(let code):
                            result(FlutterError(code: "CG_ERROR",
                                                message: "Failed to dissociate mouse from cursor position: \(code)",
                                                details: ["errorCode": code]))
                        case .monitorError:
                            result(FlutterError(code: "MONITOR_ERROR",
                                                message: "Failed to create event monitor for relative mouse mode",
                                                details: nil))
                        }
                    }

                case "disableNativeRelativeMouseMode":
                    guard let argMap = call.arguments as? [String: Any],
                          let windowId = (argMap["windowId"] as? NSNumber)?.int64Value,
                          let sessionId = argMap["sessionId"] as? String,
                          let generation = (argMap["generation"] as? NSNumber)?.uint64Value else {
                        result(FlutterError(code: "INVALID_ARGUMENT",
                                            message: "disableNativeRelativeMouseMode requires windowId, sessionId, and generation",
                                            details: nil))
                        break
                    }
                    let disableResult = self.disableNativeRelativeMouseMode(windowId: windowId,
                                                                           sessionId: sessionId,
                                                                           generation: generation)
                    switch disableResult {
                    case .success(let val):
                        result(val)
                    case .failure(let err):
                        switch err {
                        case .notOwner(let owner):
                            result(FlutterError(code: "NOT_OWNER",
                                                message: "Caller windowId=\(windowId) sessionId=\(sessionId) is not the active owner",
                                                details: [
                                                    "ownerWindowId": owner.windowId,
                                                    "ownerSessionId": owner.sessionId
                                                ]))
                        case .staleGeneration(let activeGen):
                            result(FlutterError(code: "STALE_GENERATION",
                                                message: "Caller generation \(generation) is older than active generation \(activeGen)",
                                                details: ["activeGeneration": activeGen]))
                        case .cgError(let code):
                            result(FlutterError(code: "CG_ASSOCIATE_FAILED",
                                                message: "Failed to re-associate mouse cursor: \(code)",
                                                details: ["errorCode": code]))
                        }
                    }

                default:
                    result(FlutterMethodNotImplemented)
                }
        })
    }
}

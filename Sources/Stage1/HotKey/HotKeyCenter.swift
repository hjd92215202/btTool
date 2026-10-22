import Carbon.HIToolbox
import Foundation

/// 基于 Carbon `RegisterEventHotKey` 的全局热键中心。
///
/// 为什么用 Carbon 而不是 `NSEvent.addGlobalMonitorForEvents`：
/// 1. **不需要**辅助功能 / 输入监控权限，用户体验好，审核友好；
/// 2. 它是「注册式」而不是「监听式」：系统直接把组合键路由给我们的进程，
///    不会拦截事件流（monitor 方式必须 return 原事件，且拿不到某些系统占用键）；
/// 3. 应用处于后台（LSUIElement、无窗口）时依然可靠触发。
///
/// ⚠️ 限制：
/// - 若组合键被系统或其它 App 已注册，则注册会失败（errHotKeyExists），需换键；
/// - 事件只在主线程 RunLoop 派发。
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// 事件签名：用于区分「是我们注册的哪个热键」，避免与其它 Carbon 事件混淆。
    private static let signature: OSType = fourCharCode("BTTO")

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextIdentifier: UInt32 = 1

    private init() {}

    // MARK: - 注册 / 注销

    /// 注册一个全局热键。
    /// - Returns: 热键 ID，可用于 `unregister(_:)`；失败返回 nil。
    @discardableResult
    func register(_ hotKey: HotKey, action: @escaping () -> Void) -> UInt32? {
        installEventHandlerIfNeeded()

        let identifier = nextIdentifier
        nextIdentifier += 1

        let hotKeyID = EventHotKeyID(signature: HotKeyCenter.signature, id: identifier)
        var reference: EventHotKeyRef?

        let status = RegisterEventHotKey(hotKey.keyCode,
                                         hotKey.carbonModifiers,
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &reference)
        guard status == noErr, let reference else {
            Log.error("注册全局热键 \(hotKey.readableDescription) 失败，status=\(status)" +
                      "（若 status = -9878 表示该组合键已被系统/其它 App 占用）", log: Log.hotKey)
            return nil
        }

        hotKeyRefs[identifier] = reference
        handlers[identifier] = action
        Log.info("已注册全局热键 \(hotKey.readableDescription)（id=\(identifier)）", log: Log.hotKey)
        return identifier
    }

    func unregister(_ identifier: UInt32) {
        guard let reference = hotKeyRefs.removeValue(forKey: identifier) else { return }
        UnregisterEventHotKey(reference)
        handlers.removeValue(forKey: identifier)
        Log.info("已注销全局热键 id=\(identifier)", log: Log.hotKey)
    }

    func unregisterAll() {
        for identifier in hotKeyRefs.keys { unregister(identifier) }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    // MARK: - 内部：安装 Carbon 事件处理器

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: UInt32(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(),
                                        hotKeyEventHandler,
                                        1,
                                        &eventType,
                                        userData,
                                        &eventHandlerRef)
        if status != noErr {
            Log.error("InstallEventHandler 失败：\(status)", log: Log.hotKey)
        }
    }

    /// 由 C 回调调用（fileprivate 便于同文件的全局函数访问）
    fileprivate func handle(hotKeyID: EventHotKeyID) {
        guard hotKeyID.signature == HotKeyCenter.signature else { return }
        guard let action = handlers[hotKeyID.id] else { return }
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }
}

// MARK: - Carbon C 回调（必须是全局函数，不能捕获上下文，靠 userData 回传 self）

private func hotKeyEventHandler(_ nextHandler: EventHandlerCallRef?,
                                _ event: EventRef?,
                                _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hotKeyID)
    guard status == noErr else { return OSStatus(eventNotHandledErr) }

    let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
    center.handle(hotKeyID: hotKeyID)
    return noErr
}

private func fourCharCode(_ text: String) -> OSType {
    var result: OSType = 0
    for byte in text.utf8 {
        result = (result << 8) | OSType(byte)
    }
    return result
}

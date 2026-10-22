import Foundation
import ObjectiveC

/// 极薄的 Objective-C runtime 封装，专门用于调用私有 API。
///
/// 为什么不能直接 `performSelector:`：
/// 1. 我们要调用的是**类方法**，且最多带 3 个参数，`perform(_:with:with:)` 只支持 2 个；
/// 2. Swift 的 `performSelector` 系列在 ARC 下对返回值的处理很危险；
/// 3. arm64 上 `objc_msgSend` 必须通过**精确的函数类型**转换后再调用，否则寄存器错乱崩溃。
enum ObjCRuntime {
    /// `RTLD_DEFAULT` 是 `((void *)-2)` 宏，Swift 无法直接导入，这里手工构造
    private static let handleDefault = UnsafeMutableRawPointer(bitPattern: -2)

    static let msgSend: UnsafeMutableRawPointer? = dlsym(handleDefault, "objc_msgSend")

    /// 判断某个类上是否存在指定的**类方法**（比 `responds(to:)` 更精确，避免误判实例方法）
    static func classMethodExists(on cls: AnyClass, _ selector: Selector) -> Bool {
        class_getClassMethod(cls, selector) != nil
    }

    /// 类方法，无返回值，1 个对象参数
    static func sendVoid(_ cls: AnyClass, _ selector: Selector, _ arg1: AnyObject) {
        typealias Fn = @convention(c) (AnyClass, Selector, AnyObject) -> Void
        guard let raw = msgSend else { return }
        unsafeBitCast(raw, to: Fn.self)(cls, selector, arg1)
    }

    /// 类方法，无返回值，2 个对象参数
    static func sendVoid(_ cls: AnyClass, _ selector: Selector, _ arg1: AnyObject, _ arg2: AnyObject) {
        typealias Fn = @convention(c) (AnyClass, Selector, AnyObject, AnyObject) -> Void
        guard let raw = msgSend else { return }
        unsafeBitCast(raw, to: Fn.self)(cls, selector, arg1, arg2)
    }
}

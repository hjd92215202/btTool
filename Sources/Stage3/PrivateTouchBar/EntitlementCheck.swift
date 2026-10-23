import Foundation
import Security

/// 进程自身的「代码签名 / 特权」自省。
///
/// ⚠️ 用途已收窄：**只报事实，不做因果判断**。
///
/// 旧注释把「托盘图标不显示」直接归因于缺少 `com.apple.private.controlstrip`，
/// 这条因果链已被推翻 —— 反证：MTMR 用完全相同的 API 序列且不持有该特权。
/// 现在它只负责在 P0 诊断日志里如实打印「持有 / 不持有」，不再当作判据。
enum EntitlementCheck {
    /// 惰性创建：第一次访问时才拿 SecTask（避免过早触碰 Security 框架）
    private static var task: SecTask? { SecTaskCreateFromSelf(nil) }

    /// 读取某个 entitlement 的布尔值；不存在或类型不符一律视为 false
    static func boolValue(_ entitlement: String) -> Bool {
        guard let task, let value = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) else {
            return false
        }
        return (value as? NSNumber)?.boolValue ?? false
    }

    /// `com.apple.private.controlstrip` —— **曾**被怀疑是 Control Strip 托盘项的门槛。
    ///
    /// 已知事实：把它签进 ad-hoc 包 → launchd 拒绝启动（spawn failed，
    /// `NSPOSIXErrorDomain Code=153`）⇒ 它是**受限 entitlement，需要 provisioning profile**。
    ///
    /// 🟢 已知反证：MTMR（`Toxblh/MTMR`）不持有它，照样用
    /// `addSystemTrayItem:` + `DFRElementSetControlStripPresenceForIdentifier` 注册托盘
    /// ⇒ **它既不是充分条件，也不是必要条件**。保留此查询只为如实记录。
    static var hasControlStripEntitlement: Bool { boolValue("com.apple.private.controlstrip") }
}

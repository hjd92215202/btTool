import Carbon
import Foundation

/// 存档 DTO 的编解码往返 —— 存档格式一改就断，必须钉住。
enum PersistentModelTests {
    static func run(_ t: TestRunner) {
        // ActionDTO：每种 Kind 都要能原样往返（含全部可选字段）
        for kind in ActionDTO.Kind.allCases {
            let action = ActionDTO(kind: kind,
                                   text: "标题",
                                   detail: "正文",
                                   keyCode: CGKeyCode(kVK_Space),
                                   modifierRawValue: CGEventFlags.maskCommand.rawValue,
                                   children: [ActionDTO(kind: .log, text: "子动作")])
            guard let data = try? JSONEncoder().encode(action),
                  let decoded = try? JSONDecoder().decode(ActionDTO.self, from: data) else {
                t.check(false, "ActionDTO(\(kind.rawValue)) 编解码失败")
                continue
            }
            t.checkEqual(decoded, action, "ActionDTO(\(kind.rawValue)) 往返后应与原值完全一致")
        }

        // 前向兼容：缺少可选字段的老存档也要能解出来
        let minimal = try? JSONDecoder().decode(
            ActionDTO.self,
            from: Data(#"{"kind":"notification","text":"仅标题"}"#.utf8))
        t.checkEqual(minimal?.kind, .notification, "缺少可选字段的 ActionDTO 也应能解码")
        t.checkEqual(minimal?.text, "仅标题", "解码后 text 应保留")
        t.check(minimal?.detail == nil, "缺失的 detail 应为 nil")
        t.check(minimal?.children == nil, "缺失的 children 应为 nil")
    }
}

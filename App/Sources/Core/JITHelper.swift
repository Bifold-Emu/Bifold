import AzaharCore
import UIKit

/// Helpers for enabling JIT on sideloaded builds.
enum JITHelper {
    static var status: AZJitStatus { az_jit_status() }

    static var statusText: String {
        switch status {
        case AZ_JIT_LEGACY: return "JIT 已启用（传统模式）"
        case AZ_JIT_TXM_SCRIPT: return "JIT 已启用（iOS 26 调试器脚本模式）"
        case AZ_JIT_DISABLED_BUILD: return "App Store 版本：使用解释器"
        default: return "JIT 未启用：使用解释器（较慢）"
        }
    }

    static var isEnabled: Bool { status == AZ_JIT_LEGACY || status == AZ_JIT_TXM_SCRIPT }

    /// Opens StikDebug and asks it to attach to this app with its bundled universal JIT script
    /// (required on iOS 26 TXM devices; harmless on older ones). StikDebug relaunches the app.
    static func requestViaStikDebug() {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        var c = URLComponents()
        c.scheme = "stikjit"
        c.host = "enable-jit"
        c.queryItems = [
            URLQueryItem(name: "bundle-id", value: bundleID),
            URLQueryItem(name: "script-name", value: "universal.js"),
        ]
        if let url = c.url {
            UIApplication.shared.open(url)
        }
    }

    static var canOpenStikDebug: Bool {
        guard let url = URL(string: "stikjit://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }
}

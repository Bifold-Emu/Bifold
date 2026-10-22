import Foundation
import UIKit

/// Shows the 3DS software keyboard as a UIAlertController. Called on the emulation thread,
/// which blocks until the user answers (the emulated game is waiting for the applet anyway).
/// `cancel()` releases a pending request, e.g. when the game is closed while the alert is up.
enum KeyboardBridge {
    private final class Request {
        let semaphore = DispatchSemaphore(value: 0)
        var text = ""
        var button: Int32 = 0
        weak var alert: UIAlertController?
    }

    private static let lock = NSLock()
    private static var pending: Request?

    static func present(hint: String, maxLength: Int, multiline: Bool, buttonCount: Int,
                        outButton: UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<CChar>? {
        let request = Request()
        request.button = Int32(max(buttonCount - 1, 0))
        lock.lock(); pending = request; lock.unlock()

        DispatchQueue.main.async {
            let alert = UIAlertController(title: "输入文字", message: hint.isEmpty ? nil : hint,
                                          preferredStyle: .alert)
            alert.addTextField { field in
                field.placeholder = hint
                field.clearButtonMode = .whileEditing
            }
            if buttonCount >= 2 {
                alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
                    request.button = 0
                    request.semaphore.signal()
                })
            }
            if buttonCount >= 3 {
                alert.addAction(UIAlertAction(title: "忘记了", style: .default) { _ in
                    request.button = 1
                    request.semaphore.signal()
                })
            }
            alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak alert] _ in
                var text = alert?.textFields?.first?.text ?? ""
                if maxLength > 0, text.count > maxLength { text = String(text.prefix(maxLength)) }
                request.text = text
                request.button = Int32(max(buttonCount - 1, 0))
                request.semaphore.signal()
            })
            guard let top = UIApplication.shared.topViewController else {
                request.semaphore.signal()
                return
            }
            request.alert = alert
            top.present(alert, animated: true)
        }

        request.semaphore.wait()
        lock.lock(); if pending === request { pending = nil }; lock.unlock()
        outButton?.pointee = request.button
        return strdup(request.text) // freed by the core with free()
    }

    /// Unblocks the emulation thread if a keyboard is open (answers "cancel"/default).
    static func cancel() {
        lock.lock()
        let request = pending
        pending = nil
        lock.unlock()
        guard let request else { return }
        request.button = 0
        request.semaphore.signal()
        DispatchQueue.main.async { request.alert?.dismiss(animated: false) }
    }
}

extension UIApplication {
    var topViewController: UIViewController? {
        let scene = connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

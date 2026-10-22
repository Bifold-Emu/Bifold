import AzaharCore
import CoreMotion
import GameController
import UIKit

/// Physical controllers (MFi, Xbox, PlayStation, Switch Pro, Backbone/Kishi …), keyboards and
/// the gyroscope. Started while a game is on screen.
@MainActor
final class InputManager: ObservableObject {
    static let shared = InputManager()

    /// True once a physical controller has actually been used. Merely being connected is not
    /// enough: the iOS Simulator (and many paired-but-idle pads) always report a gamepad.
    @Published private(set) var hasGamepad = false
    private let motion = CMMotionManager()
    private var observers: [NSObjectProtocol] = []

    private init() {}

    func start() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            Task { @MainActor in self?.attach(n.object as? GCController) }
        })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshGamepadState() }
        })
        observers.append(nc.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] n in
            Task { @MainActor in self?.attachKeyboard((n.object as? GCKeyboard) ?? GCKeyboard.coalesced) }
        })
        GCController.controllers().forEach(attach)
        if let kb = GCKeyboard.coalesced { attachKeyboard(kb) }
        GCController.startWirelessControllerDiscovery {}
        refreshGamepadState()
        startMotion()
        updateOrientation()
        observers.append(nc.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateOrientation() }
        })
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        GCController.stopWirelessControllerDiscovery()
        motion.stopDeviceMotionUpdates()
        az_release_all_input()
    }

    private func refreshGamepadState() {
        if !GCController.controllers().contains(where: { $0.extendedGamepad != nil }) {
            hasGamepad = false
        }
    }

    fileprivate func gamepadUsed() {
        if !hasGamepad { hasGamepad = true }
    }

    // MARK: Gamepads

    private func attach(_ controller: GCController?) {
        guard let pad = controller?.extendedGamepad else { return }
        controller?.playerIndex = .index1
        func bind(_ input: GCControllerButtonInput?, _ button: AZButton) {
            input?.pressedChangedHandler = { _, _, pressed in
                az_button(button, pressed)
                if pressed { Task { @MainActor in InputManager.shared.gamepadUsed() } }
            }
        }
        // Nintendo layout by position: the east face button is A, like on a real 3DS.
        bind(pad.buttonB, AZ_BUTTON_A)
        bind(pad.buttonA, AZ_BUTTON_B)
        bind(pad.buttonY, AZ_BUTTON_X)
        bind(pad.buttonX, AZ_BUTTON_Y)
        bind(pad.leftShoulder, AZ_BUTTON_L)
        bind(pad.rightShoulder, AZ_BUTTON_R)
        bind(pad.leftTrigger, AZ_BUTTON_ZL)
        bind(pad.rightTrigger, AZ_BUTTON_ZR)
        bind(pad.buttonMenu, AZ_BUTTON_START)
        bind(pad.buttonOptions, AZ_BUTTON_SELECT)
        bind(pad.buttonHome, AZ_BUTTON_HOME)
        bind(pad.dpad.up, AZ_BUTTON_UP)
        bind(pad.dpad.down, AZ_BUTTON_DOWN)
        bind(pad.dpad.left, AZ_BUTTON_LEFT)
        bind(pad.dpad.right, AZ_BUTTON_RIGHT)
        pad.leftThumbstick.valueChangedHandler = { _, x, y in az_stick(AZ_STICK_CIRCLE_PAD, x, y) }
        pad.rightThumbstick.valueChangedHandler = { _, x, y in az_stick(AZ_STICK_C_STICK, x, y) }
        refreshGamepadState()
    }

    private func attachKeyboard(_ keyboard: GCKeyboard?) {
        guard let kb = keyboard?.keyboardInput else { return }
        let map: [GCKeyCode: AZButton] = [
            .keyX: AZ_BUTTON_A, .keyZ: AZ_BUTTON_B, .keyS: AZ_BUTTON_X, .keyA: AZ_BUTTON_Y,
            .keyQ: AZ_BUTTON_L, .keyW: AZ_BUTTON_R, .one: AZ_BUTTON_ZL, .two: AZ_BUTTON_ZR,
            .returnOrEnter: AZ_BUTTON_START, .rightShift: AZ_BUTTON_SELECT, .keyH: AZ_BUTTON_HOME,
            .upArrow: AZ_BUTTON_UP, .downArrow: AZ_BUTTON_DOWN, .leftArrow: AZ_BUTTON_LEFT, .rightArrow: AZ_BUTTON_RIGHT,
        ]
        var stickKeys = Set<GCKeyCode>()
        kb.keyChangedHandler = { _, _, code, pressed in
            if let b = map[code] {
                az_button(b, pressed)
                return
            }
            let stickCodes: [GCKeyCode] = [.keyI, .keyJ, .keyK, .keyL]
            guard stickCodes.contains(code) else { return }
            if pressed { stickKeys.insert(code) } else { stickKeys.remove(code) }
            let x: Float = (stickKeys.contains(.keyL) ? 1 : 0) - (stickKeys.contains(.keyJ) ? 1 : 0)
            let y: Float = (stickKeys.contains(.keyI) ? 1 : 0) - (stickKeys.contains(.keyK) ? 1 : 0)
            az_stick(AZ_STICK_CIRCLE_PAD, x, y)
        }
    }

    // MARK: Motion

    private func startMotion() {
        guard AppSettings.shared.motionControls, motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates(to: OperationQueue()) { data, _ in
            guard let d = data else { return }
            let g = d.gravity, a = d.userAcceleration, r = d.rotationRate
            az_motion(Float(g.x + a.x), Float(g.y + a.y), Float(g.z + a.z),
                      Float(r.x), Float(r.y), Float(r.z))
        }
    }

    private func updateOrientation() {
        let orientation = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.interfaceOrientation }.first ?? .portrait
        switch orientation {
        case .landscapeRight: az_set_motion_orientation(1) // home indicator on the right
        case .portraitUpsideDown: az_set_motion_orientation(2)
        case .landscapeLeft: az_set_motion_orientation(3)
        default: az_set_motion_orientation(0)
        }
    }
}

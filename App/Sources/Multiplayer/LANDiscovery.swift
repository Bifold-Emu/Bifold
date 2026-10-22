import dnssd
import Foundation
import Network

/// Same-Wi-Fi room discovery over Bonjour.
///
/// The host registers `_azahar3ds._udp` with the room's ENet port (DNSServiceRegister does not
/// need us to own that socket) and a TXT record with the room details and its IPv4 addresses.
/// Other devices browse with NWBrowser and join the advertised address directly.
@MainActor
final class LANDiscovery: ObservableObject {
    static let serviceType = "_azahar3ds._udp"

    struct Room: Identifiable, Hashable {
        let serviceName: String
        let name: String
        let addresses: [String]
        let port: UInt16
        let hasPassword: Bool
        let players: Int
        let maxPlayers: Int
        let game: String
        let host: String
        var id: String { serviceName }
    }

    @Published private(set) var rooms: [Room] = []
    @Published private(set) var isBrowsing = false

    private var browser: NWBrowser?
    private var registration: DNSServiceRef?
    private var advertised: (name: String, port: UInt16, hasPassword: Bool, max: Int, game: String)?
    private var players = 1

    // MARK: Browsing

    func startBrowsing() {
        guard browser == nil else { return }
        let params = NWParameters.udp
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let rooms = results.compactMap(Self.parse)
            Task { @MainActor in self?.rooms = rooms.sorted { $0.name < $1.name } }
        }
        b.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.isBrowsing = true
                case .failed, .cancelled: self?.isBrowsing = false
                default: break
                }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
        rooms = []
    }

    nonisolated private static func parse(_ result: NWBrowser.Result) -> Room? {
        guard case let .service(serviceName, _, _, _) = result.endpoint,
              case let .bonjour(txt) = result.metadata else { return nil }
        let dict = txt.dictionary
        guard let portString = dict["port"], let port = UInt16(portString) else { return nil }
        let addresses = (dict["ip"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        guard !addresses.isEmpty else { return nil }
        return Room(serviceName: serviceName, name: dict["name"] ?? serviceName, addresses: addresses,
                    port: port, hasPassword: dict["pw"] == "1", players: Int(dict["n"] ?? "") ?? 0,
                    maxPlayers: Int(dict["max"] ?? "") ?? 0, game: dict["game"] ?? "",
                    host: dict["host"] ?? "")
    }

    // MARK: Advertising

    func advertise(roomName: String, port: UInt16, hasPassword: Bool, maxPlayers: Int, game: String) {
        advertised = (roomName, port, hasPassword, maxPlayers, game)
        players = 1
        register()
    }

    func updatePlayers(_ count: Int) {
        guard advertised != nil, count != players else { return }
        players = count
        register()
    }

    func stopAdvertising() {
        if let ref = registration {
            DNSServiceRefDeallocate(ref)
        }
        registration = nil
        advertised = nil
    }

    private func register() {
        guard let a = advertised else { return }
        if let ref = registration {
            DNSServiceRefDeallocate(ref)
            registration = nil
        }
        let entries: [(String, String)] = [
            ("name", a.name), ("port", String(a.port)), ("pw", a.hasPassword ? "1" : "0"),
            ("n", String(players)), ("max", String(a.max)), ("game", String(a.game.prefix(60))),
            ("host", AppSettings.shared.nickname), ("ip", Self.localIPv4Addresses().joined(separator: ",")),
            ("v", "1"),
        ]
        var txt = Data()
        for (k, v) in entries {
            let item = Array("\(k)=\(v)".utf8.prefix(255))
            txt.append(UInt8(item.count))
            txt.append(contentsOf: item)
        }
        var ref: DNSServiceRef?
        let serviceName = "\(a.name) (\(AppSettings.shared.nickname))"
        let err = txt.withUnsafeBytes { raw in
            DNSServiceRegister(&ref, 0, 0, serviceName, Self.serviceType, nil, nil,
                               a.port.bigEndian, UInt16(txt.count), raw.baseAddress, nil, nil)
        }
        if err == DNSServiceErrorType(kDNSServiceErr_NoError), let ref {
            DNSServiceSetDispatchQueue(ref, .main)
            registration = ref
        }
    }

    /// IPv4 addresses of Wi-Fi / hotspot / wired interfaces.
    nonisolated static func localIPv4Addresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue } // Wi-Fi, USB, hotspot
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return result
    }
}

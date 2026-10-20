// Flatline: a menu bar pulse for servers running the Flatline agent.
// Every 30 s it runs `flatline status --json` on each server over SSH, with the keys you already use.
// Servers and the Telegram bot are set up in the panel; the bot token is kept in the macOS Keychain.
import Security
import ServiceManagement
import SwiftUI

@main
struct FlatlineApp: App {
    @StateObject private var monitor = Monitor()

    var body: some Scene {
        MenuBarExtra {
            Panel().environmentObject(monitor)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: monitor.down == 0 ? "waveform.path.ecg" : "heart.slash.fill")
                if monitor.down > 0 { Text("\(monitor.down)") }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Model

struct Vitals: Decodable {
    let name: String
    let cpu, ram, disk: Double
    let uptime: Int
    let problems: [String]
    // details for the server's page; older agents may not send them
    var load: [Double]?
    var cores: Int?
    var memUsed, memTotal: Int?  // MB
    var diskUsed, diskTotal: Double?  // GB
    var os, kernel: String?
    var pm2: [Pm2App]?
    var docker: [Container]?
    var agent: Bool?  // false: read once over SSH with nothing installed

    struct Pm2App: Decodable {
        let name, status: String
        let cpu: Double
        let mem, restarts: Int
    }

    struct Container: Decodable {
        let name, state, status: String
    }
}

struct Server: Identifiable {
    let id: String  // the SSH host, or flatline@host:port for a server someone shared with you
    var vitals: Vitals?
    var error: String?
    var guest = false
    var history: [Double] = []  // recent CPU readings, drawn as the pulse
    var healthy: Bool { error == nil && vitals?.problems.isEmpty == true }
    var notes: [String] { vitals?.problems ?? (error.map { [$0] } ?? []) }
}

/// A server someone shared with you: read-only, through your own restricted key.
struct Guest: Codable, Hashable {
    let name, host: String
    let port: Int
    var id: String { "flatline@\(host):\(port)" }
}

extension Data {
    init?(base64url text: String) {
        var b64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        self.init(base64Encoded: b64)
    }

    var base64url: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct Telegram: Codable {
    let token: String
    let chat: Int64

    func call(_ method: String, _ params: [String: Any] = [:]) async -> [String: Any] {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else { return [:] }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: params)
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

enum Keychain {
    static let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: "Flatline", kSecAttrAccount as String: "telegram"]

    static func load() -> Telegram? {
        var data: AnyObject?
        let query = item.merging([kSecReturnData as String: true]) { $1 }
        guard SecItemCopyMatching(query as CFDictionary, &data) == errSecSuccess, let data = data as? Data else { return nil }
        return try? JSONDecoder().decode(Telegram.self, from: data)
    }

    static func save(_ telegram: Telegram) {
        SecItemDelete(item as CFDictionary)
        guard let data = try? JSONEncoder().encode(telegram) else { return }
        SecItemAdd(item.merging([kSecValueData as String: data]) { $1 } as CFDictionary, nil)
    }
}

@MainActor
final class Monitor: ObservableObject {
    @Published var hosts: [String] = []
    @Published var servers: [Server] = []
    @Published var updated: Date?
    @Published var telegram = Keychain.load()
    @Published var guests: [Guest] = []
    nonisolated static let dir = URL.homeDirectory.appending(path: ".config/flatline")
    nonisolated static let ownKey = dir.appending(path: "id_ed25519")  // yours, for servers shared with you
    nonisolated static let knownHosts = dir.appending(path: "known_hosts")  // their host keys, pinned by the invite
    let file = Monitor.dir.appending(path: "servers.txt")
    let guestFile = Monitor.dir.appending(path: "shared.json")
    var down: Int { servers.filter { !$0.healthy }.count }

    init() {
        UserDefaults.standard.register(defaults: ["dashboard": true])
        hosts = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter(Monitor.valid)
        guests = (try? JSONDecoder().decode([Guest].self, from: Data(contentsOf: guestFile))) ?? []
        Task { while true { await refresh(); try? await Task.sleep(for: .seconds(30)) } }
    }

    /// An SSH destination such as root@203.0.113.10 or an alias from ~/.ssh/config. Never an ssh option.
    nonisolated static func valid(_ host: String) -> Bool {
        !host.isEmpty && host.count <= 255 && !host.hasPrefix("-")
            && host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "@._-".contains($0)) }
    }

    func add(_ host: String) {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard Monitor.valid(host), !hosts.contains(host) else { return }
        hosts.append(host)
        save()
        Task {
            if telegram != nil { _ = await push(to: [host]) }
            await refresh()
        }
    }

    /// Stops watching and removes Flatline from the server too, leaving nothing behind.
    func uninstall(_ host: String) async -> String? {
        let (code, _) = await Monitor.ssh(Monitor.own(host), Monitor.root("flatline uninstall"))
        guard code == 0 || code == 127 else { return code == 255 ? "can't reach it over ssh" : "needs root or passwordless sudo" }
        remove(host)
        return nil
    }

    func leave(_ guest: Guest) {
        guests.removeAll { $0 == guest }
        servers.removeAll { $0.id == guest.id }
        saveGuests()
    }

    private func saveGuests() {
        try? FileManager.default.createDirectory(at: Monitor.dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(guests).write(to: guestFile, options: .atomic)
    }

    func remove(_ host: String) {
        hosts.removeAll { $0 == host }
        servers.removeAll { $0.id == host }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (hosts.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    func refresh() async {
        let targets = hosts.map { ($0, Monitor.own($0), false) } + guests.map { ($0.id, Monitor.guestArgs($0), true) }
        let results = await withTaskGroup(of: Server.self) { group in
            for (id, destination, guest) in targets { group.addTask { await Monitor.check(id, destination, guest: guest) } }
            return await group.reduce(into: [String: Server]()) { $0[$1.id] = $1 }
        }
        servers = (self.hosts + self.guests.map(\.id)).compactMap { host in  // the lists may have changed while we waited
            guard var server = results[host] else { return nil }
            let past = servers.first { $0.id == host }?.history ?? []
            server.history = Array((past + [server.vitals?.cpu].compactMap { $0 }).suffix(60))  // 30 minutes
            return server
        }
        updated = .now
        await publish()
    }

    nonisolated static func check(_ id: String, _ destination: [String], guest: Bool) async -> Server {
        var (code, out) = await ssh(destination, "flatline status --json")
        if code == 127, !guest, let agent = Bundle.main.url(forResource: "flatline", withExtension: nil),
           let source = try? Data(contentsOf: agent) {  // no agent there: run ours once over SSH, write nothing
            (code, out) = await ssh(destination, "python3 - status --json --live", input: source, timeout: 45)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if code == 0, let vitals = try? decoder.decode(Vitals.self, from: out) { return Server(id: id, vitals: vitals, guest: guest) }
        let error = switch code {
        case 255: guest ? "can't reach it, or your access was taken away" : "can't reach it over ssh"
        case 127: "needs python3 or the flatline agent"
        default: "agent error \(code)"
        }
        return Server(id: id, error: error, guest: guest)
    }

    nonisolated static func own(_ host: String) -> [String] { ["--", host] }

    nonisolated static func guestArgs(_ guest: Guest, key: URL = ownKey) -> [String] {
        ["-i", key.path, "-o", "IdentitiesOnly=yes", "-o", "UserKnownHostsFile=\(knownHosts.path)", "-o", "StrictHostKeyChecking=yes",
         "-p", String(guest.port), "--", "flatline@\(guest.host)"]
    }

    /// Runs a command as root, through passwordless sudo when the SSH user isn't root.
    nonisolated static func root(_ command: String) -> String {
        #"if [ "$(id -u)" = 0 ]; then "# + command + "; else sudo -n " + command + "; fi"
    }

    /// Runs one fixed command on a server. Secrets (bot token, keys) go through stdin, never the command line.
    nonisolated static func ssh(_ destination: [String], _ command: String, input: Data? = nil, timeout: Double = 20) async -> (Int32, Data) {
        await run("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8"] + destination + [command], input: input, timeout: timeout)
    }

    nonisolated static func run(_ tool: String, _ arguments: [String], input: Data? = nil, timeout: Double = 20) async -> (Int32, Data) {
        await withCheckedContinuation { done in
            DispatchQueue.global().async {
                let process = Process(), output = Pipe(), stdin = Pipe()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = arguments
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                process.standardInput = input == nil ? FileHandle.nullDevice : stdin
                do { try process.run() } catch { return done.resume(returning: (-1, Data())) }
                if let input {
                    stdin.fileHandleForWriting.write(input)
                    try? stdin.fileHandleForWriting.close()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                done.resume(returning: (process.terminationStatus, data))
            }
        }
    }

    // MARK: Sharing

    /// Makes a single-use invite that lets someone else's Flatline read this server, and nothing more.
    func invite(_ host: String) async -> (invite: String?, note: String) {
        let temp = FileManager.default.temporaryDirectory.appending(path: "flatline-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temp) }  // the private half lives only inside the invite
        let key = temp.appending(path: "invite")
        _ = await Monitor.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "flatline-invite", "-f", key.path])
        guard let pub = try? Data(contentsOf: key.appendingPathExtension("pub")),
              let secret = try? String(contentsOf: key, encoding: .utf8) else { return (nil, "couldn't make a key") }
        let (code, out) = await Monitor.ssh(Monitor.own(host), Monitor.root("flatline share"), input: pub)
        guard code == 0, let reply = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any],
              let hostkeys = reply["hostkeys"] as? [String] else {
            return (nil, code == 255 ? "can't reach it over ssh" : code == 127 ? "install the agent here first" : "needs root or passwordless sudo")
        }
        let config = String(decoding: await Monitor.run("/usr/bin/ssh", ["-G", "--", host]).1, as: UTF8.self).split(separator: "\n")
        let address = config.first { $0.hasPrefix("hostname ") }.map { String($0.dropFirst(9)) } ?? host
        let port = config.first { $0.hasPrefix("port ") }.flatMap { Int($0.dropFirst(5)) } ?? 22
        let name = servers.first { $0.id == host }?.vitals?.name ?? host
        let payload: [String: Any] = ["v": 1, "name": name, "host": address, "port": port, "user": "flatline", "key": secret, "hostkeys": hostkeys]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return (nil, "couldn't write the invite") }
        return ("flatline-invite:" + data.base64url, "Single use, expires in 24 hours. Your partner must be able to reach \(address):\(port).")
    }

    func guestsOf(_ host: String) async -> [String] {
        let (code, out) = await Monitor.ssh(Monitor.own(host), Monitor.root("flatline access --json"))
        return code == 0 ? ((try? JSONSerialization.jsonObject(with: out)) as? [String] ?? []) : []
    }

    func revoke(_ name: String, on host: String) async {
        guard name.range(of: #"^[A-Za-z0-9._-]{1,40}$"#, options: .regularExpression) != nil else { return }
        _ = await Monitor.ssh(Monitor.own(host), Monitor.root("flatline revoke \(name)"))
    }

    /// Redeems an invite: makes your own key, trades the one-time key for it, pins the server's host key.
    func join(_ text: String) async -> String {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.hasPrefix("flatline-invite:"), let data = Data(base64url: String(raw.dropFirst(16))),
              let p = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let host = p["host"] as? String, host.range(of: #"^[A-Za-z0-9.:-]{1,253}$"#, options: .regularExpression) != nil, !host.hasPrefix("-"),
              let port = p["port"] as? Int, (1...65535).contains(port), p["user"] as? String == "flatline",
              let secret = p["key"] as? String, secret.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"),
              let hostkeys = p["hostkeys"] as? [String], !hostkeys.isEmpty,
              hostkeys.allSatisfy({ $0.range(of: #"^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa) [A-Za-z0-9+/]+=*$"#, options: .regularExpression) != nil })
        else { return "✕ that isn't a Flatline invite" }
        let label = ((p["name"] as? String) ?? host).filter { $0.isLetter || $0.isNumber || "._-".contains($0) }.prefix(40)
        let guest = Guest(name: label.isEmpty ? host : String(label), host: host, port: port)
        let fm = FileManager.default
        try? fm.createDirectory(at: Monitor.dir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: Monitor.ownKey.path) {
            _ = await Monitor.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "flatline-guest", "-f", Monitor.ownKey.path])
        }
        guard let mine = (try? String(contentsOf: Monitor.ownKey.appendingPathExtension("pub"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return "✕ couldn't make your key" }
        let pin = "[\(host)]:\(port) "
        let known = ((try? String(contentsOf: Monitor.knownHosts, encoding: .utf8)) ?? "").split(separator: "\n").filter { !$0.hasPrefix(pin) }
        try? (known.map(String.init) + hostkeys.map { pin + $0 }).joined(separator: "\n").appending("\n").write(to: Monitor.knownHosts, atomically: true, encoding: .utf8)
        let temp = fm.temporaryDirectory.appending(path: "flatline-\(UUID().uuidString)")
        try? fm.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temp) }
        let once = temp.appending(path: "invite")
        guard fm.createFile(atPath: once.path, contents: Data(secret.utf8), attributes: [.posixPermissions: 0o600]) else { return "✕ couldn't use the invite" }
        let me = (Host.current().localizedName ?? "guest").filter { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }.prefix(30)
            + "-" + UUID().uuidString.prefix(4).lowercased()
        let (code, out) = await Monitor.ssh(Monitor.guestArgs(guest, key: once), "redeem", input: Data("\(mine)\n\(me)\n".utf8))
        guard code == 0, String(decoding: out, as: UTF8.self).contains("ok") else {
            return code == 255 ? "✕ the invite was already used, has expired, or the server is out of reach" : "✕ the server refused the invite"
        }
        if !guests.contains(guest) { guests.append(guest) }
        saveGuests()
        Task { await refresh() }
        return "✓ you can now see \(guest.name) (read only)"
    }

    // MARK: Telegram

    func connect(token raw: String) async -> String {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.range(of: #"^\d{5,16}:[A-Za-z0-9_-]{30,64}$"#, options: .regularExpression) != nil else {
            return "✕ that isn't a bot token (looks like 123456:ABC...)"
        }
        let reply = await Telegram(token: token, chat: 0).call("getUpdates")
        guard reply["ok"] as? Bool == true else { return "✕ telegram refused this token" }
        let updates = reply["result"] as? [[String: Any]] ?? []
        let chats = updates.compactMap { ($0["message"] as? [String: Any])?["chat"] as? [String: Any] }
        guard let found = chats.last, let chat = found["id"] as? Int64 else { return "✕ send your bot a message first, then connect again" }
        // say whose chat it is, so a stranger who messaged the bot first can't quietly take the alerts
        let who = [found["title"], found["first_name"], found["last_name"]].compactMap { $0 as? String }.joined(separator: " ")
            + ((found["username"] as? String).map { " (@\($0))" } ?? "")
        let telegram = Telegram(token: token, chat: chat)
        Keychain.save(telegram)
        self.telegram = telegram
        UserDefaults.standard.removeObject(forKey: "pinned")
        return "✓ alerts go to \(who.isEmpty ? String(chat) : who). Not you? Message the bot yourself and connect again.\n" + (await push(to: hosts))
    }

    /// Hands the bot to each server's agent so alerts keep flowing when this Mac is off.
    func push(to hosts: [String]) async -> String {
        guard let telegram else { return "" }
        let input = Data("\(telegram.token)\n\(telegram.chat)\n".utf8)
        let command = Monitor.root("flatline telegram")
        let lines = await withTaskGroup(of: String.self) { group in
            for host in hosts {
                group.addTask {
                    let (code, _) = await Monitor.ssh(Monitor.own(host), command, input: input)
                    switch code {
                    case 0: return "  ✓ \(host)"
                    case 255: return "  ✕ \(host): can't reach it over ssh"
                    case 127: return "  ✕ \(host): flatline agent isn't installed"
                    case 1, 77: return "  ✕ \(host): needs root or passwordless sudo"
                    case 69: return "  ✕ \(host): saved, but the server can't reach telegram"
                    default: return "  ✕ \(host): agent error \(code)"
                    }
                }
            }
            return await group.reduce(into: [String]()) { $0.append($1) }
        }
        return lines.sorted().joined(separator: "\n")
    }

    /// Keeps one pinned message in the chat as a live dashboard of every server.
    func publish() async {
        guard let telegram, UserDefaults.standard.bool(forKey: "dashboard"), !servers.isEmpty else { return }
        let rows = servers.map { server -> String in
            guard let v = server.vitals else { return "✕ \(server.id)  no signal" }
            let name = v.name.padding(toLength: 14, withPad: " ", startingAt: 0)
            let row = "\(server.healthy ? "●" : "✕") \(name) cpu\(pct(v.cpu)) ram\(pct(v.ram)) dsk\(pct(v.disk))"
            return ([row] + v.problems.map { "  └ \($0)" }).joined(separator: "\n")
        }
        let alive = servers.filter(\.healthy).count
        let time = Date.now.formatted(date: .omitted, time: .shortened)
        let text = String("FLATLINE  \(alive)/\(servers.count) alive\n\n\(rows.joined(separator: "\n"))\n\nupdated \(time)".prefix(3500))
        let html = "<pre>" + text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;") + "</pre>"
        let pinned = UserDefaults.standard.integer(forKey: "pinned")
        if pinned != 0 {
            let reply = await telegram.call("editMessageText", ["chat_id": telegram.chat, "message_id": pinned, "text": html, "parse_mode": "HTML"])
            guard (reply["description"] as? String ?? "").contains("not found") else { return }  // deleted: post a new one
        }
        let sent = await telegram.call("sendMessage", ["chat_id": telegram.chat, "text": html, "parse_mode": "HTML", "disable_notification": true])
        guard let id = (sent["result"] as? [String: Any])?["message_id"] as? Int else { return }
        UserDefaults.standard.set(id, forKey: "pinned")
        _ = await telegram.call("pinChatMessage", ["chat_id": telegram.chat, "message_id": id, "disable_notification": true])
    }
}

func pct(_ value: Double) -> String { String(format: "%4d%%", Int(value.rounded())) }

// MARK: - Look: soft paper, white cards, Geist Mono and halftone art

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    static let ink = Color(hex: 0x262626)
    static let muted = Color(hex: 0x8E8E93)
    static let hairline = Color(hex: 0xEFEFF1)
    static let field = Color(hex: 0xF4F4F6)
    static let button = Color(hex: 0x2E2E2E)
    static let ok = Color(hex: 0x2FBF71)
    static let warn = Color(hex: 0xF59E0B)
    static let bad = Color(hex: 0xF0384F)
}

func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .custom("Geist Mono", size: size).weight(weight) }
func shortUptime(_ s: Int) -> String { s >= 86400 ? "\(s / 86400)d" : s >= 3600 ? "\(s / 3600)h" : "\(s / 60)m" }
func longUptime(_ s: Int) -> String { s >= 86400 ? "\(s / 86400)d \(s % 86400 / 3600)h" : "\(s / 3600)h \(s % 3600 / 60)m" }
func level(_ percent: Double) -> Color { percent >= 90 ? .bad : percent >= 70 ? .warn : .ink }

extension View {
    func card() -> some View {
        background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 16, y: 6)
    }
}

/// Buttons sink a little under your finger.
struct Press: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.35)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Views

enum Page: Equatable {
    case list, detail(String), settings
}

struct Panel: View {
    @EnvironmentObject var monitor: Monitor
    @State private var page = Page.list

    var body: some View {
        VStack(spacing: 12) {
            Hero(page: page, server: shown, back: { go(.list) }, settings: { go(page == .settings ? .list : .settings) })
            switch page {
            case .list:
                if !monitor.hosts.isEmpty { ServersCard { go(.detail($0)) }.transition(.opacity) }
            case .detail:
                if let shown { DetailCard(server: shown).transition(.move(edge: .trailing).combined(with: .opacity)) }
            case .settings:
                SettingsCard().transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(14)
        .frame(width: 380)
        .background(Backdrop())
        .environment(\.colorScheme, .light)
        .environment(\.locale, Locale(identifier: "en_US"))  // keep "12 sec ago" in the UI's language
    }

    var shown: Server? {
        if case .detail(let id) = page { return monitor.servers.first { $0.id == id } }
        return nil
    }

    func go(_ next: Page) {
        withAnimation(.snappy(duration: 0.3)) { page = next }
    }
}

/// The pale lime-and-lavender paper behind the cards.
struct Backdrop: View {
    var body: some View {
        ZStack {
            Color(hex: 0xF5F6F2)
            Circle().fill(Color(hex: 0xEEF3C6)).frame(width: 340, height: 340).blur(radius: 70).offset(x: -150, y: -230)
            Circle().fill(Color(hex: 0xE9E7FA)).frame(width: 340, height: 340).blur(radius: 70).offset(x: 160, y: 170)
        }
        .clipped()
    }
}

/// The status card: a headline that says how things are, and halftone art that beats with them.
struct Hero: View {
    @EnvironmentObject var monitor: Monitor
    let page: Page
    let server: Server?
    let back: () -> Void
    let settings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                ForEach(headline.components(separatedBy: "\n"), id: \.self) { Text($0).lineLimit(1).minimumScaleFactor(0.55) }
            }
            .font(mono(27, .medium)).foregroundStyle(Color.ink).multilineTextAlignment(.center)
            .padding(.top, 38).padding(.horizontal, 22)
            .id(headline)
            .transition(.opacity.combined(with: .offset(y: 8)))
            subtitle
                .font(mono(11.5)).foregroundStyle(Color.muted).multilineTextAlignment(.center).lineLimit(2)
                .padding(.top, 10).padding(.horizontal, 26)
            ZStack(alignment: .top) {
                Halftone(alarm: alarm).frame(height: 128)
                action.padding(.top, 14)
            }
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity)
        .background(.white)
        .overlay(alignment: .top) {
            HStack {
                if case .detail = page { Icon("chevron.left", action: back) }
                Spacer()
                Icon(page == .settings ? "xmark" : "gearshape", action: settings)
            }
            .padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 16, y: 6)
        .animation(.snappy(duration: 0.35), value: headline)
    }

    var sick: [Server] { monitor.servers.filter { !$0.healthy } }
    var alarm: Bool { server.map { !$0.healthy } ?? !sick.isEmpty }

    var headline: String {
        if let server {
            let name = server.vitals?.name ?? server.id
            if server.vitals == nil { return "\(name)\nis silent." }
            return server.healthy ? "\(name)\nis breathing." : "\(name)\nneeds you."
        }
        let count = monitor.servers.count
        if monitor.hosts.isEmpty { return "Add your\nfirst server." }
        if count == 0 { return "Listening for\na heartbeat…" }
        if sick.isEmpty {
            return count == 1 ? "Your server\nis breathing." : count == 2 ? "Both servers\nare breathing." : "All \(count) servers\nare breathing."
        }
        if sick.count == 1 { return "\(sick[0].vitals?.name ?? sick[0].id)\nneeds you." }
        return "\(sick.count) servers\nneed you."
    }

    var subtitle: Text {
        if let server {
            guard let v = server.vitals else { return Text(server.error ?? "no signal") }
            guard let updated = monitor.updated else { return Text("up \(longUptime(v.uptime))") }
            return Text("up \(longUptime(v.uptime)) · checked \(updated, style: .relative) ago")
        }
        if monitor.hosts.isEmpty {
            return Text("Flatline checks your servers over SSH and pings your Telegram the moment one breaks.")
        }
        if !sick.isEmpty {
            return Text(sick.map { "\($0.vitals?.name ?? $0.id): \($0.notes.first ?? "")" }.joined(separator: " · "))
        }
        guard let updated = monitor.updated else { return Text("Checking your servers…") }
        let telegram = monitor.telegram == nil ? "Telegram not connected" : "Telegram connected"
        return Text("Checked \(updated, style: .relative) ago · \(telegram)")
    }

    @ViewBuilder var action: some View {
        if let server {
            Pill("Open SSH →") { NSWorkspace.shared.open(URL(string: "ssh://\(server.id)")!) }  // id passed Monitor.valid
        } else if monitor.hosts.isEmpty {
            Pill("Add a server →", action: settings)
        } else {
            Pill("Check now →") { Task { await monitor.refresh() } }
        }
    }
}

/// Halftone art: soft colour blobs printed as a dot grid that fades to paper white at the top.
/// While every server is alive the colours drift and a heartbeat rolls through the dots;
/// when one flatlines the art turns red and holds still.
struct Halftone: View {
    let alarm: Bool

    private typealias Blob = (x: Double, y: Double, r: Double, rgb: (Double, Double, Double))
    private static let calm: [Blob] = [
        (0.10, 0.90, 0.30, (1.00, 0.74, 0.30)),  // amber
        (0.28, 0.70, 0.26, (1.00, 0.52, 0.22)),  // orange
        (0.50, 0.98, 0.30, (1.00, 0.16, 0.45)),  // hot pink
        (0.42, 0.62, 0.18, (1.00, 0.40, 0.62)),  // rose
        (0.74, 0.80, 0.26, (0.62, 0.38, 1.00)),  // violet
        (0.92, 0.45, 0.24, (0.52, 0.66, 1.00)),  // periwinkle
        (0.03, 1.05, 0.20, (1.00, 0.90, 0.36)),  // yellow
        (0.64, 1.05, 0.18, (1.00, 0.30, 0.28)),  // red
    ]
    private static let flatlined: [Blob] = [
        (0.15, 0.85, 0.34, (1.00, 0.30, 0.36)),
        (0.45, 1.00, 0.34, (0.94, 0.14, 0.40)),
        (0.40, 0.62, 0.18, (1.00, 0.46, 0.52)),
        (0.78, 0.75, 0.30, (1.00, 0.40, 0.42)),
        (0.95, 0.45, 0.22, (0.86, 0.20, 0.36)),
        (0.04, 1.05, 0.22, (0.82, 0.08, 0.24)),
    ]
    private static let holes: [(x: Double, y: Double, r: Double)] = [(0.36, 0.50, 0.15), (0.86, 0.98, 0.12)]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: alarm)) { context in
            Canvas { ctx, size in paint(ctx, size, context.date.timeIntervalSinceReferenceDate) }
        }
    }

    /// Cheap repeatable noise in 0..<1, so the print looks inked rather than plotted.
    private func noise(_ i: Int, _ j: Int) -> Double {
        let s = sin(Double(i) * 12.9898 + Double(j) * 78.233) * 43758.5453
        return s - s.rounded(.down)
    }

    private func paint(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double) {
        let blobs = alarm ? Halftone.flatlined : Halftone.calm
        let beat = (t / 1.4).truncatingRemainder(dividingBy: 1)  // where we are in the heartbeat
        let step: CGFloat = 4.5
        for (j, y) in stride(from: step / 2, to: size.height, by: step).enumerated() {
            let v = Double(y / size.height)
            let fade = min(1, max(0, (v - 0.08) / 0.6))  // paper white at the top, full ink below
            for (i, x) in stride(from: step / 2, to: size.width, by: step).enumerated() {
                let u = Double(x / size.width)
                var w = 0.0, r = 0.0, g = 0.0, b = 0.0
                for (n, blob) in blobs.enumerated() {
                    let phase = Double(n) * 1.9
                    let du = u - blob.x - 0.12 * sin(t * 0.55 + phase)
                    let dv = v - blob.y - 0.09 * cos(t * 0.45 + phase)
                    // jitter each colour's weight per dot, so blends speckle like a real halftone
                    let k = exp(-(du * du * 2.2 + dv * dv) / (blob.r * blob.r)) * (0.7 + 0.6 * noise(i + 31 * n, j + 17 * n))
                    w += k
                    r += k * blob.rgb.0
                    g += k * blob.rgb.1
                    b += k * blob.rgb.2
                }
                guard w > 0.001 else { continue }
                var ink = min(1, w) * fade * (0.8 + 0.4 * noise(i, j))
                for (n, hole) in Halftone.holes.enumerated() {  // where the paper shows through
                    let du = u - hole.x - 0.08 * cos(t * 0.35 + Double(n))
                    let dv = v - hole.y
                    ink *= 1 - 0.9 * exp(-(du * du * 2.2 + dv * dv) / (hole.r * hole.r))
                }
                // lub-dub: two rings of fatter dots roll up from the bottom on every beat
                var pulse = 0.0
                if !alarm {
                    let d = ((u - 0.5) * (u - 0.5) * 3 + (v - 1.15) * (v - 1.15)).squareRoot()
                    pulse = exp(-pow((d - beat * 1.5) / 0.07, 2)) * (1 - beat)
                    if beat > 0.16 { pulse += 0.7 * exp(-pow((d - (beat - 0.16) * 1.5) / 0.06, 2)) * (1 - beat) }
                }
                let radius = min(step * 0.62, step * 0.58 * CGFloat(min(1, ink + 0.35 * pulse).squareRoot()))
                guard radius > 0.35 else { continue }
                let wash = min(0.85, (1 - fade) * 0.55 + 0.4 * pulse)  // washes out toward the paper; the beat lights it up
                let color = Color(red: r / w + (1 - r / w) * wash, green: g / w + (1 - g / w) * wash,
                                  blue: b / w + (1 - b / w) * wash)
                ctx.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                         with: .color(color))
            }
        }
    }
}

struct ServersCard: View {
    @EnvironmentObject var monitor: Monitor
    let open: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("SERVERS").frame(maxWidth: .infinity, alignment: .leading)
                Text("PULSE").frame(width: 48, alignment: .leading)
                Text("CPU").frame(width: 32, alignment: .trailing)
                Text("RAM").frame(width: 32, alignment: .trailing)
                Text("DISK").frame(width: 38, alignment: .trailing)
                Text("UP").frame(width: 32, alignment: .trailing)
            }
            .font(mono(9.5, .medium)).tracking(0.6).foregroundStyle(Color.muted)
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
            if monitor.servers.count > 12 {
                ScrollView { rows }.frame(height: 400)
            } else {
                rows
            }
        }
        .padding(.bottom, 6)
        .card()
    }

    var rows: some View {
        VStack(spacing: 0) {
            ForEach(monitor.servers) { server in
                Rectangle().fill(Color.hairline).frame(height: 1).padding(.horizontal, 16)
                ServerRow(server: server) { open(server.id) }
            }
        }
    }
}

struct ServerRow: View {
    let server: Server
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    Pulse(healthy: server.healthy).padding(.trailing, 9)
                    Text(server.vitals?.name ?? server.id).font(mono(12.5, .medium)).foregroundStyle(Color.ink)
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    if let v = server.vitals {
                        Sparkline(values: Array(server.history.suffix(12)), color: server.healthy ? Color(hex: 0xC2C2C8) : .bad)
                            .frame(width: 40, height: 14).padding(.trailing, 8)
                        Num(v.cpu).frame(width: 32, alignment: .trailing)
                        Num(v.ram).frame(width: 32, alignment: .trailing)
                        Num(v.disk).frame(width: 38, alignment: .trailing)
                        Text(shortUptime(v.uptime)).foregroundStyle(Color.muted).frame(width: 32, alignment: .trailing)
                    } else {
                        Text("no signal").foregroundStyle(Color.bad)
                    }
                }
                if !server.notes.isEmpty {
                    Text(server.notes.joined(separator: " · ")).font(mono(11)).foregroundStyle(Color.bad)
                        .padding(.leading, 16).fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(mono(11.5))
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(hovered ? Color.field : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(Press())
        .onHover { over in withAnimation(.easeOut(duration: 0.12)) { hovered = over } }
    }
}

/// The status dot. Healthy ones send out a soft ring now and then, like a pulse.
struct Pulse: View {
    let healthy: Bool
    @State private var ring = false

    var body: some View {
        Circle().fill(healthy ? Color.ok : Color.bad).frame(width: 7, height: 7)
            .background {
                if healthy {
                    Circle().stroke(Color.ok.opacity(0.6), lineWidth: 1)
                        .scaleEffect(ring ? 2.6 : 1).opacity(ring ? 0 : 0.8)
                        .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: ring)  // local, never panel-wide
                        .onAppear { ring = true }
                }
            }
    }
}

struct Num: View {
    let value: Double

    init(_ value: Double) { self.value = value }

    var body: some View {
        Text("\(Int(value.rounded()))")
            .foregroundStyle(level(value).opacity(value >= 70 ? 1 : 0.75))
            .contentTransition(.numericText(value: value))
            .animation(.snappy, value: value)
    }
}

/// Recent CPU readings as a thin line, scaled to their own range so the beat shows.
struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1, let low = values.min(), let high = values.max() else { return }
            let span = max(high - low, 10)
            var path = Path()
            for (i, value) in values.enumerated() {
                let point = CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1),
                                    y: size.height * (1 - CGFloat((value - low) / span)))
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        }
    }
}

/// One server, up close.
struct DetailCard: View {
    @EnvironmentObject var monitor: Monitor
    let server: Server

    var body: some View {
        ScrollView { content }.frame(height: 430).card()  // long pages scroll inside the panel, like a sheet
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let v = server.vitals {
                HStack(spacing: 8) {
                    Tile(label: "CPU", value: v.cpu, caption: v.cores.map { "\($0) cores" } ?? "")
                    Tile(label: "RAM", value: v.ram, caption: size(v.memUsed.map { Double($0) / 1024 }, v.memTotal.map { Double($0) / 1024 }))
                    Tile(label: "DISK", value: v.disk, caption: size(v.diskUsed, v.diskTotal))
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle("CPU · last 30 min · peak \(Int(server.history.max() ?? v.cpu))%")
                    DotChart(values: server.history).frame(height: 52)
                }
                if !v.problems.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionTitle("Problems")
                        ForEach(v.problems, id: \.self) { Text("• \($0)").foregroundStyle(Color.bad) }
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    SectionTitle("System").padding(.bottom, 4)
                    Info("Uptime", longUptime(v.uptime))
                    if let load = v.load { Info("Load", load.map { String(format: "%.2f", $0) }.joined(separator: "  ")) }
                    if let os = v.os { Info("OS", os) }
                    if let kernel = v.kernel { Info("Kernel", kernel) }
                    Info("SSH", server.id)
                    Info("Mode", server.guest ? "shared with you · read only" : v.agent == false
                         ? "nothing installed · alerts only while this Mac is on" : "agent · alerts around the clock")
                }
                if let apps = v.pm2, !apps.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        SectionTitle("pm2 · \(apps.count)").padding(.bottom, 4)
                        ForEach(Array(apps.enumerated()), id: \.offset) { _, app in
                            Item(ok: app.status == "online", name: app.name,
                                 detail: "\(Int(app.cpu))%  \(app.mem) MB  ↺ \(app.restarts)")
                        }
                    }
                }
                if let boxes = v.docker, !boxes.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        SectionTitle("Docker · \(boxes.count)").padding(.bottom, 4)
                        ForEach(Array(boxes.enumerated()), id: \.offset) { _, box in
                            Item(ok: box.state == "running" && !box.status.contains("unhealthy"), name: box.name, detail: box.status)
                        }
                    }
                }
                if !server.guest && v.agent != false { Sharing(host: server.id) }
            } else {
                SectionTitle("No signal")
                Text(server.error ?? "no reply").foregroundStyle(Color.bad)
                Text("Flatline couldn't run `flatline status` here over SSH. Check that the server is up and the agent is installed.")
                    .foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(mono(11.5))
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func size(_ used: Double?, _ total: Double?) -> String {
        guard let used, let total else { return "" }
        return String(format: "%.1f / %.1f GB", used, total)
    }
}

/// Read-only access for someone else: a single-use invite, and the people who already have it.
struct Sharing: View {
    @EnvironmentObject var monitor: Monitor
    let host: String
    @State private var invite: String?
    @State private var note = ""
    @State private var people: [String] = []
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Share")
            Text("Let a partner watch this server from their own Flatline. They get read-only access and never your SSH or root.")
                .foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
            if let invite {
                HStack(spacing: 8) {
                    Text(invite).lineLimit(1).truncationMode(.middle).padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Pill("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(invite, forType: .string) }
                }
            } else {
                Pill(busy ? "Making an invite…" : "Create a one-time invite →") {
                    busy = true
                    Task { (invite, note) = await monitor.invite(host); busy = false; people = await monitor.guestsOf(host) }
                }
                .disabled(busy)
            }
            if !note.isEmpty { Text(note).font(mono(10.5)).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true) }
            ForEach(people, id: \.self) { person in
                HStack {
                    Text(person)
                    Spacer()
                    Button("Revoke") { Task { await monitor.revoke(person, on: host); people = await monitor.guestsOf(host) } }
                        .buttonStyle(Press()).foregroundStyle(Color.bad)
                }
                .padding(.vertical, 6)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.hairline).frame(height: 1) }
            }
        }
        .task { people = await monitor.guestsOf(host) }
    }
}

struct Tile: View {
    let label: String
    let value: Double
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(mono(9.5, .medium)).tracking(0.6).foregroundStyle(Color.muted)
            Text("\(Int(value.rounded()))%").font(mono(20, .medium)).foregroundStyle(level(value))
                .contentTransition(.numericText(value: value)).animation(.snappy, value: value)
            Capsule().fill(Color.hairline).frame(height: 3).overlay(alignment: .leading) {
                GeometryReader { g in
                    Capsule().fill(value >= 90 ? Color.bad : value >= 70 ? Color.warn : Color.ok)
                        .frame(width: g.size.width * min(value, 100) / 100)
                }
            }
            Text(caption).font(mono(9.5)).foregroundStyle(Color.muted).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// CPU history as a column chart printed in the same halftone as the art.
struct DotChart: View {
    let values: [Double]

    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 4
            let rows = Int(size.height / step), columns = Int(size.width / step)
            let samples = Array(values.suffix(columns))
            let first = columns - samples.count  // newest reading sits on the right
            let top = max((samples.max() ?? 0) * 1.25, 10)  // own scale, so a calm server still shows its pulse
            for column in 0..<columns {
                let value = column >= first ? samples[column - first] : -1
                let lit = value < 0 ? 0 : max(1, Int((min(value, top) / top * Double(rows)).rounded(.up)))
                for row in 0..<rows {
                    let x = CGFloat(column) * step + step / 2, y = size.height - CGFloat(row) * step - step / 2
                    let radius: CGFloat = row < lit ? 1.5 : 0.7
                    let color = row < lit ? DotChart.ink(Double(row) / Double(max(rows - 1, 1))) : Color.hairline
                    ctx.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)), with: .color(color))
                }
            }
        }
    }

    /// Periwinkle at the bottom, pink in the middle, orange at the top: the art's palette.
    static func ink(_ height: Double) -> Color {
        let stops: [(Double, Double, Double)] = [(0.55, 0.66, 1.00), (1.00, 0.20, 0.50), (1.00, 0.62, 0.26)]
        let x = min(max(height, 0), 1) * 2, i = min(Int(x), 1), f = x - Double(i)
        let a = stops[i], b = stops[i + 1]
        return Color(red: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f)
    }
}

struct Info: View {
    let key: String
    let value: String

    init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }

    var body: some View {
        HStack {
            Text(key).foregroundStyle(Color.muted)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(Color.ink).lineLimit(1).truncationMode(.middle)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.hairline).frame(height: 1) }
    }
}

struct Item: View {
    let ok: Bool
    let name: String
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(ok ? Color.ok : Color.bad).frame(width: 6, height: 6)
            Text(name).foregroundStyle(Color.ink).lineLimit(1)
            Spacer(minLength: 12)
            Text(detail).foregroundStyle(ok ? Color.muted : Color.bad).lineLimit(1)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.hairline).frame(height: 1) }
    }
}

struct SettingsCard: View {
    @EnvironmentObject var monitor: Monitor
    @AppStorage("dashboard") private var dashboard = true
    @State private var host = ""
    @State private var code = ""
    @State private var removing: String?
    @State private var token = ""
    @State private var report = ""
    @State private var busy = false
    @State private var atLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Servers")
            ForEach(monitor.hosts, id: \.self) { h in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(h).foregroundStyle(Color.ink)
                        Spacer()
                        Button { withAnimation(.snappy(duration: 0.2)) { removing = removing == h ? nil : h } } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.muted)
                        }
                        .buttonStyle(Press())
                    }
                    if removing == h {  // stop watching, or also wipe Flatline off the server
                        HStack(spacing: 8) {
                            Pill("Stop watching", dark: false) { monitor.remove(h); removing = nil }
                            Pill("Remove from server too") {
                                Task { report = await monitor.uninstall(h).map { "✕ \(h): \($0)" } ?? "✓ \(h): Flatline removed, nothing left behind" }
                                removing = nil
                            }
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            ForEach(monitor.guests, id: \.self) { g in
                HStack {
                    Text(g.name).foregroundStyle(Color.ink)
                    Text("shared with you").font(mono(10)).foregroundStyle(Color.muted)
                    Spacer()
                    Button { monitor.leave(g) } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.muted)
                    }
                    .buttonStyle(Press())
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            HStack(spacing: 8) {
                Input("user@host or ssh alias", text: $host).onSubmit(add)
                Pill("Add", dark: false, action: add)
            }
            HStack(spacing: 8) {
                Input("Paste an invite from a partner", text: $code)
                Pill("Join", dark: false) { Task { report = await monitor.join(code); code = "" } }.disabled(code.isEmpty)
            }
            SectionTitle("Telegram").padding(.top, 8)
            Text("1. Open @BotFather in Telegram, send /newbot and paste the token below.\n2. Send your new bot any message, then connect.")
                .font(mono(11)).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Input(monitor.telegram == nil ? "Bot token" : "Connected · paste a new token to switch", text: $token, secure: true)
                Pill(busy ? "…" : "Connect →", action: connect).disabled(busy || token.isEmpty)
            }
            if !report.isEmpty {
                Text(report).font(mono(11)).foregroundStyle(Color.ink).fixedSize(horizontal: false, vertical: true)
            }
            Switch("Live dashboard in Telegram", on: $dashboard)
            SectionTitle("General").padding(.top, 8)
            Switch("Open at login", on: $atLogin)
                .onChange(of: atLogin) { _, on in
                    do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
                    catch { atLogin = SMAppService.mainApp.status == .enabled }
                }
            HStack {
                Text("Flatline \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(mono(11)).foregroundStyle(Color.muted)
                Spacer()
                Pill("Quit", dark: false) { NSApp.terminate(nil) }
            }
            .padding(.top, 6)
        }
        .font(mono(12))
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    func add() {
        monitor.add(host)
        host = ""
    }

    func connect() {
        busy = true
        Task {
            report = await monitor.connect(token: token)
            token = ""
            busy = false
        }
    }
}

struct SectionTitle: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased()).font(mono(9.5, .medium)).tracking(0.6).foregroundStyle(Color.muted)
    }
}

struct Input: View {
    let placeholder: String
    @Binding var text: String
    let secure: Bool

    init(_ placeholder: String, text: Binding<String>, secure: Bool = false) {
        self.placeholder = placeholder
        _text = text
        self.secure = secure
    }

    var body: some View {
        Group {
            if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
        }
        .textFieldStyle(.plain).font(mono(12))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct Pill: View {
    let title: String
    let dark: Bool
    let action: () -> Void

    init(_ title: String, dark: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.dark = dark
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).font(mono(12, .medium)).foregroundStyle(dark ? Color.white : Color.ink)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(dark ? Color.button : Color.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(Press())
    }
}

/// A round icon button for the corners of the status card.
struct Icon: View {
    let symbol: String
    let action: () -> Void

    init(_ symbol: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.ink.opacity(0.7))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 28)
                .background(Color.field, in: Circle())
        }
        .buttonStyle(Press())
    }
}

struct Switch: View {
    let title: String
    @Binding var on: Bool

    init(_ title: String, on: Binding<Bool>) {
        self.title = title
        _on = on
    }

    var body: some View {
        Button { withAnimation(.snappy(duration: 0.2)) { on.toggle() } } label: {
            HStack {
                Text(title).foregroundStyle(Color.ink)
                Spacer()
                Capsule().fill(on ? Color.ok : Color(hex: 0xE2E2E7)).frame(width: 30, height: 18)
                    .overlay(alignment: on ? .trailing : .leading) {
                        Circle().fill(.white).padding(2).shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

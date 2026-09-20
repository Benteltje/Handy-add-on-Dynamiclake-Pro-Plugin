import Foundation

private let pluginName = "Handy"
private let activityID = "handy-voice.listening"
private let socketEnvironmentKey = "DYNAMICLAKE_JSON_SOCKET"

private func debugLogPath() -> URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = appSupport.appendingPathComponent("DynamicLake", isDirectory: true)
        .appendingPathComponent("PluginLogs", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("handy-voice.log")
}

private func debugLog(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = ts + " " + message + "\n"
    let url = debugLogPath()
    if FileManager.default.fileExists(atPath: url.path),
       let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

private enum PluginError: Error, CustomStringConvertible {
    case socket(String)
    case socketPathMissing
    var description: String {
        switch self {
        case .socket(let m): return "socket: " + m
        case .socketPathMissing: return "DYNAMICLAKE_JSON_SOCKET not set"
        }
    }
}

private final class JSONSocketClient {
    let socketPath: String
    private var fd: Int32 = -1

    init(socketPath: String) { self.socketPath = socketPath }
    deinit { close() }

    func connect() throws {
        close()
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PluginError.socket("socket failed") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)

        socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
                    memset(dst, 0, maxLen)
                    strncpy(dst, src, maxLen - 1)
                }
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Darwin.connect(fd, sp, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw PluginError.socket("connect: " + String(cString: strerror(errno))) }
        debugLog("connected")
    }

    func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }

    func send(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        var frame = Data()
        var len = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
        frame.append(data)
        try frame.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < frame.count {
                let r = Darwin.send(fd, base.advanced(by: sent), frame.count - sent, 0)
                if r > 0 { sent += r; continue }
                if r < 0 && errno == EINTR { continue }
                if r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { usleep(10_000); continue }
                throw PluginError.socket("send: " + String(cString: strerror(errno)))
            }
        }
        debugLog("sent frame " + String(data.count) + " bytes")
    }

    func sendWithReconnect(_ payload: [String: Any]) throws {
        if fd < 0 { try connect() }
        do {
            try send(payload)
        } catch {
            close()
            try connect()
            try send(payload)
        }
    }
}

// MARK: - Handy Detection

private func getHandyPID() -> pid_t? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    task.arguments = ["-x", "handy"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return nil }
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if let pid = Int32(str) { return pid }
    return nil
}

private enum HandyState {
    case idle, recording, transcribing, processing
}

private final class HandyRecordingLog {
    private let url: URL
    private var offset: UInt64 = 0
    private(set) var state: HandyState = .idle

    init() {
        url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/com.pais.handy/handy.log")
    }

    func refresh() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return }
        let fileSize = size.uint64Value
        if offset == 0 { offset = fileSize > 64 * 1024 ? fileSize - 64 * 1024 : 0 }
        if fileSize < offset { offset = 0 }
        guard fileSize > offset,
              let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return }
        offset += UInt64(data.count)
        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(whereSeparator: \.isNewline) { consume(String(line)) }
    }

    private func consume(_ line: String) {
        if line.contains("icon=resources/tray_recording") ||
           line.contains("Microphone is receiving samples; recording is ready") {
            state = .recording
        } else if line.contains("icon=resources/tray_transcribing") ||
                  line.contains("Starting async transcription") {
            state = .transcribing
        } else if line.contains("Starting LLM post-processing") ||
                  line.contains("icon=resources/tray_processing") ||
                  line.contains("overlay 'processing'") {
            state = .processing
        } else if line.contains("icon=resources/tray_idle") ||
                  line.contains("returned to idle state") {
            state = .idle
        }
    }
}

private func handyState(_ log: HandyRecordingLog) -> HandyState {
    log.refresh()
    guard getHandyPID() != nil else { return .idle }
    return log.state
}

// MARK: - Plugin Main

private var published = false

private final class HandyMonitor {
    private let client: JSONSocketClient
    private var timer: DispatchSourceTimer?
    private var lastState: HandyState = .idle
    private let handyLog = HandyRecordingLog()

    init(client: JSONSocketClient) { self.client = client }

    func run() {
        try? client.connect()
        let q = DispatchQueue(label: "com.dynamiclake.handy")
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500), leeway: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        dispatchMain()
    }

    private func makePayload(text: String) -> [String: Any] {
        return [
            "schemaVersion": 1,
            "requestID": "\(published ? "update" : "create")-\(Int(Date().timeIntervalSince1970))",
            "type": published ? "update" : "create",
            "activityID": activityID,
            "title": pluginName,
            "priority": "high",
            "size": "large",
            "surfaces": [
                "compactLiveActivity": [
                    "leftSlot": [
                        "type": "text", "id": "name",
                        "text": "Handy", "style": "compact", "tint": "pink"
                    ] as [String: Any],
                    "rightSlot": [
                        "type": "text", "id": "status",
                        "text": text, "style": "compact", "tint": "pink"
                    ] as [String: Any]
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    private func tick() {
        let state = handyState(handyLog)
        if state != lastState {
            debugLog("state=" + String(describing: state))
            lastState = state
        }

        if state == .recording && !published {
            do {
                try client.send(makePayload(text: "Listening"))
                published = true
                debugLog("published listening")
            } catch {
                debugLog("publish error: \(error)")
            }
        } else if state == .transcribing && published {
            do {
                try client.send(makePayload(text: "Transcribing"))
                debugLog("updated transcribing")
            } catch {
                debugLog("update error: \(error)")
            }
        } else if state == .processing && published {
            do {
                try client.send(makePayload(text: "Processing"))
                debugLog("updated processing")
            } catch {
                debugLog("update error: \(error)")
            }
        } else if state == .idle && published {
            let payload: [String: Any] = [
                "schemaVersion": 1,
                "requestID": "dismiss-\(Int(Date().timeIntervalSince1970))",
                "type": "dismiss",
                "activityID": activityID
            ]
            do {
                try client.send(payload)
                published = false
                debugLog("dismissed")
            } catch {
                debugLog("dismiss error: \(error)")
            }
        }
    }
}

@main
private enum Main {
    static func main() {
        let args = Set(CommandLine.arguments.dropFirst())

        if args.contains("--check") {
            print("Plugin: " + pluginName)
            print("Socket: " + (ProcessInfo.processInfo.environment[socketEnvironmentKey] ?? "missing"))
            exit(0)
        }

        guard let socketPath = ProcessInfo.processInfo.environment[socketEnvironmentKey],
              !socketPath.isEmpty else {
            fputs(pluginName + ": no socket\n", stderr)
            exit(64)
        }

        debugLog("starting, socket=" + socketPath)
        let client = JSONSocketClient(socketPath: socketPath)
        let monitor = HandyMonitor(client: client)
        monitor.run()
    }
}

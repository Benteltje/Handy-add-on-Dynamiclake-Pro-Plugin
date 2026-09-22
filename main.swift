import Foundation

private let pluginName = "Handy"
private let activityID = "handy-voice.listening"
private let socketEnvironmentKey = "DYNAMICLAKE_JSON_SOCKET"
private let maxLogBytes: UInt64 = 256 * 1024

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
       let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
       let size = attrs[.size] as? NSNumber,
       size.uint64Value > maxLogBytes {
        try? FileManager.default.removeItem(at: url)
    }
    if let handle = try? FileHandle(forWritingTo: url) {
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
        // Try to read a response (non-blocking, best effort)
        var flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        var lenBuf = [UInt8](repeating: 0, count: 4)
        let lr = Darwin.recv(fd, &lenBuf, 4, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags)
        }
        if lr == 4 {
            let respLen = (UInt32(lenBuf[0]) << 24) | (UInt32(lenBuf[1]) << 16) |
                          (UInt32(lenBuf[2]) << 8) | UInt32(lenBuf[3])
            if respLen > 0 && respLen < 1024 * 1024 {
                var respBuf = [UInt8](repeating: 0, count: Int(respLen))
                var got = 0
                while got < Int(respLen) {
                    let r = respBuf.withUnsafeMutableBytes { ptr in
                        Darwin.recv(fd, ptr.baseAddress!.advanced(by: got), Int(respLen) - got, 0)
                    }
                    if r > 0 { got += r }
                    else if r == 0 { break }
                    else if errno == EINTR { continue }
                    else { break }
                }
                if got > 0 {
                    let respStr = String(bytes: respBuf.prefix(got), encoding: .utf8) ?? "<binary>"
                    debugLog("response: " + respStr)
                }
            }
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

private final class HandyMonitor {
    private let client: JSONSocketClient
    private var timer: DispatchSourceTimer?
    private var lastState: HandyState = .idle
    private var published = false
    private let handyLog = HandyRecordingLog()
    private var progressTimer: DispatchSourceTimer?
    private var progressValue = 1
    private var progressTickCount = 0

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

    private func startProgress() {
        // Alleen resetten als de timer nog niet liep (dus niet bij transcribing→processing)
        if progressTimer == nil {
            progressValue = 1
            progressTickCount = 0
        }
        stopProgress()
        let q = DispatchQueue(label: "com.dynamiclake.handy.progress")
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.progressTick() }
        t.resume()
        progressTimer = t
    }

    private func stopProgress() {
        progressTimer?.cancel()
        progressTimer = nil
    }

    private func progressTick() {
        progressValue += 1
        if progressValue > 100 {
            progressValue = 1
        }
        // Elke 100ms (10 ticks) versturen: vloeiender dan 250ms, onder rate limit
        progressTickCount += 1
        guard progressTickCount >= 10 else { return }
        progressTickCount = 0
        guard published else { return }
        let statusText: String
        switch lastState {
        case .transcribing: statusText = "Transcribing"
        case .processing: statusText = "Processing"
        default: return
        }
        do {
            try client.send(makePayload(status: statusText, progress: Double(progressValue) / 100.0))
        } catch {
            debugLog("progress error: \(error)")
        }
    }

    private func makePayload(status: String, progress: Double? = nil) -> [String: Any] {
        let sfSymbol = status == "Listening" ? "mic.fill" :
                       status == "Transcribing" ? "waveform" :
                       status == "Processing" ? "sparkles" : "mic.fill"
        let rightSlot: [String: Any]
        if let p = progress {
            rightSlot = [
                "type": "progress", "id": "hv-progress",
                "value": p, "tint": "pink"
            ]
        } else {
            rightSlot = [
                "type": "status", "id": "hv-status",
                "systemImage": sfSymbol, "tint": "pink"
            ]
        }
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
                        "type": "image", "id": "hv-icon",
                        "source": "packageFile", "fileName": "icon-pink.png"
                    ] as [String: Any],
                    "rightSlot": rightSlot
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    private func tick() {
        let state = handyState(handyLog)
        guard state != lastState else { return }
        lastState = state
        debugLog("state=" + String(describing: state))

        if state == .recording && !published {
            do {
                try client.send(makePayload(status: "Listening"))
                published = true
                debugLog("published listening")
            } catch {
                debugLog("publish error: \(error)")
            }
        } else if state == .transcribing && published {
            startProgress()
            debugLog("started progress (transcribing)")
        } else if state == .processing && published {
            startProgress()
            debugLog("started progress (processing)")
        } else if state == .idle && published {
            stopProgress()
            let payload: [String: Any] = [
                "schemaVersion": 1,
                "requestID": "dismiss-\(Int(Date().timeIntervalSince1970))",
                "type": "dismiss",
                "activityID": activityID
            ]
            // 3x sturen met pauzes: send() gooit niet bij rate limit,
            // dus bucket moet tijd krijgen om bij te vullen
            for attempt in 1...3 {
                do {
                    try client.send(payload)
                } catch {
                    debugLog("dismiss error attempt \(attempt): \(error)")
                }
                if attempt < 3 {
                    usleep(300_000)
                }
            }
            published = false
            debugLog("dismissed")
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

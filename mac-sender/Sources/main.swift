import AppKit
import Foundation
import Network

// MARK: - Configuration

struct Config {
    static let host = ProcessInfo.processInfo.environment["CLIPBOARD_SYNC_HOST"] ?? "localhost"
    static let port = ProcessInfo.processInfo.environment["CLIPBOARD_SYNC_PORT"] ?? "8765"
    static let endpointURL = URL(string: "http://\(host):\(port)/clipboard")!
    static let pollInterval: TimeInterval = 0.3

    // Linux 側からの受信を待ち受けるポート（Linux -> Mac）
    static let listenPort = ProcessInfo.processInfo.environment["CLIPBOARD_SYNC_LISTEN_PORT"] ?? "8766"

    // touch このファイルで一時停止、rm で再開
    static let pauseFlagPath =
        (ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
        + "/.clipboard-sync-pause"

    // フォアグラウンドにいるときに送信をスキップするアプリ名
    static let excludedApps: Set<String> = [
        "1Password",
        "1Password 7",
        "Keychain Access",
        "Bitwarden",
    ]
}

// MARK: - ClipboardSender

final class ClipboardSender {
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private let session: URLSession

    init() {
        lastChangeCount = pasteboard.changeCount

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        session = URLSession(configuration: config)
    }

    func start() {
        print("[clipboard-sender] started. target=\(Config.endpointURL)")
        Timer.scheduledTimer(withTimeInterval: Config.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    // Linux から受信してペーストボードに書き込んだ直後に呼ぶ。
    // これを呼ばないと、直後の poll() が「ローカルでの変更」と誤認して Linux に送り返し、
    // 無限ループ（Linux -> Mac -> Linux -> ...）になる。
    func absorbExternalChange() {
        lastChangeCount = pasteboard.changeCount
    }

    // MARK: - Private

    private func poll() {
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        if isPaused() {
            fputs("[clipboard-sender] paused by flag file, skipping.\n", stderr)
            return
        }

        if isForegroundAppExcluded() {
            fputs("[clipboard-sender] excluded app is in foreground, skipping.\n", stderr)
            return
        }

        sendClipboard()
    }

    private func isPaused() -> Bool {
        FileManager.default.fileExists(atPath: Config.pauseFlagPath)
    }

    private func isForegroundAppExcluded() -> Bool {
        guard let appName = NSWorkspace.shared.frontmostApplication?.localizedName else {
            return false
        }
        return Config.excludedApps.contains(appName)
    }

    private func sendClipboard() {
        let types = pasteboard.types?.map { $0.rawValue } ?? []
        fputs("[clipboard-sender] pasteboard types: \(types)\n", stderr)

        // PNG を優先
        if let data = pasteboard.data(forType: .png) {
            send(data: data, contentType: "image/png")
            return
        }

        // TIFF → PNG に変換して送信
        if let tiffData = pasteboard.data(forType: .tiff),
            let image = NSImage(data: tiffData),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        {
            let rep = NSBitmapImageRep(cgImage: cgImage)
            if let pngData = rep.representation(using: .png, properties: [:]) {
                send(data: pngData, contentType: "image/png")
                return
            }
        }

        // ファイルURL が画像ファイルを指している場合は画像データを送信
        // UTI フィルタを使わず、実際に NSImage で開けるかどうかで判定する
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls where url.isFileURL {
                if let image = NSImage(contentsOf: url),
                   let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                {
                    let rep = NSBitmapImageRep(cgImage: cgImage)
                    if let pngData = rep.representation(using: .png, properties: [:]) {
                        send(data: pngData, contentType: "image/png")
                        return
                    }
                }
            }
        }

        // テキスト
        if let text = pasteboard.string(forType: .string) {
            // クリップボードマネージャーが画像を一時ファイルに保存してパスを文字列で入れるケースに対応
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            fputs("[clipboard-sender] text detected: \(trimmed.prefix(120))\n", stderr)
            if trimmed.hasPrefix("/") {
                let url = URL(fileURLWithPath: trimmed)
                let exists = FileManager.default.fileExists(atPath: trimmed)
                fputs("[clipboard-sender] file path detected, exists=\(exists)\n", stderr)
                if let image = NSImage(contentsOf: url) {
                    fputs("[clipboard-sender] NSImage loaded\n", stderr)
                    if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        let rep = NSBitmapImageRep(cgImage: cgImage)
                        if let pngData = rep.representation(using: .png, properties: [:]) {
                            fputs("[clipboard-sender] sending as image/png (\(pngData.count) bytes)\n", stderr)
                            send(data: pngData, contentType: "image/png")
                            return
                        }
                    } else {
                        fputs("[clipboard-sender] cgImage failed\n", stderr)
                    }
                } else {
                    fputs("[clipboard-sender] NSImage load failed\n", stderr)
                }
            }
            // /var/folders/ など macOS temp パスはテキストとして送信しない（クリップボードマネージャーの後処理）
            if trimmed.hasPrefix("/var/folders/") || trimmed.hasPrefix("/private/var/folders/") {
                fputs("[clipboard-sender] skipping macOS temp path as text\n", stderr)
                return
            }
            if let data = text.data(using: .utf8) {
                send(data: data, contentType: "text/plain; charset=utf-8")
            }
        }
    }

    private func send(data: Data, contentType: String) {
        var request = URLRequest(url: Config.endpointURL)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let task = session.dataTask(with: request) { _, response, error in
            if let error = error {
                fputs("[clipboard-sender] send error: \(error.localizedDescription)\n", stderr)
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                fputs("[clipboard-sender] unexpected status: \(http.statusCode)\n", stderr)
            }
        }
        task.resume()
    }
}

// MARK: - ClipboardReceiver (Linux -> Mac)

final class ClipboardReceiver {
    private let pasteboard = NSPasteboard.general
    private let sender: ClipboardSender
    private var listener: NWListener?

    init(sender: ClipboardSender) {
        self.sender = sender
    }

    func start() {
        guard let port = NWEndpoint.Port(Config.listenPort) else {
            fputs("[clipboard-receiver] invalid port: \(Config.listenPort)\n", stderr)
            return
        }
        do {
            let listener = try NWListener(using: .tcp, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: .main)
            self.listener = listener
            print("[clipboard-receiver] listening on port \(Config.listenPort)")
        } catch {
            fputs("[clipboard-receiver] failed to start listener: \(error)\n", stderr)
        }
    }

    // MARK: - Private

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var buf = buffer
            if let data = data {
                buf.append(data)
            }

            if let (bodyStart, headers) = Self.parseHeaders(buf) {
                let contentLength = Self.contentLength(from: headers)
                if buf.count - bodyStart >= contentLength {
                    let body = buf.subdata(in: bodyStart..<(bodyStart + contentLength))
                    let contentType = headers["content-type"] ?? "text/plain"
                    self.applyClipboard(contentType: contentType, body: body)
                    Self.respondOK(on: connection)
                    return
                }
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: buf)
        }
    }

    private func applyClipboard(contentType: String, body: Data) {
        pasteboard.clearContents()
        if contentType.hasPrefix("image/png") {
            if let image = NSImage(data: body) {
                pasteboard.writeObjects([image])
            } else {
                pasteboard.setData(body, forType: .png)
            }
        } else if let text = String(data: body, encoding: .utf8) {
            pasteboard.setString(text, forType: .string)
        }
        // pasteboard への書き込みは同期的に changeCount を更新するため、
        // ここで即座に absorb すれば次の poll() で誤検知しない。
        sender.absorbExternalChange()
        fputs("[clipboard-receiver] applied clipboard from linux (\(body.count) bytes, \(contentType))\n", stderr)
    }

    private static func parseHeaders(_ data: Data) -> (bodyStart: Int, headers: [String: String])? {
        let terminator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
        guard let range = data.range(of: terminator) else { return nil }
        guard let headerString = String(data: data.subdata(in: data.startIndex..<range.lowerBound), encoding: .utf8) else {
            return nil
        }
        var headers: [String: String] = [:]
        for line in headerString.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return (range.upperBound, headers)
    }

    private static func contentLength(from headers: [String: String]) -> Int {
        guard let value = headers["content-length"], let length = Int(value) else { return 0 }
        return length
    }

    private static func respondOK(on connection: NWConnection) {
        let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

// MARK: - Entry point

let sender = ClipboardSender()
let receiver = ClipboardReceiver(sender: sender)
sender.start()
receiver.start()
RunLoop.main.run()

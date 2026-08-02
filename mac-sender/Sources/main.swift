import AppKit
import Foundation

// MARK: - Configuration

struct Config {
    static let host = ProcessInfo.processInfo.environment["CLIPBOARD_SYNC_HOST"] ?? "localhost"
    static let port = ProcessInfo.processInfo.environment["CLIPBOARD_SYNC_PORT"] ?? "8765"
    static let endpointURL = URL(string: "http://\(host):\(port)/clipboard")!
    static let pollInterval: TimeInterval = 0.3

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

// MARK: - Entry point

let sender = ClipboardSender()
sender.start()
RunLoop.main.run()

import Foundation
import CryptoKit

public enum UpdateInstaller {
    public static func download(_ request: URLRequest, expectedSHA256: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        var req = request
        req.timeoutInterval = 60
        let delegate = DownloadProgress(progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (tmp, response) = try await session.download(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw FalconError.http(status, "download failed") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FalconMail-Update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: tmp, to: fileURL)
        progress(1)
        if let expected = expectedSHA256?.lowercased(), !expected.isEmpty {
            let data = try Data(contentsOf: fileURL)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == expected else { throw FalconError.storage("Downloaded file failed its checksum") }
        }
        return fileURL
    }

    final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @Sendable (Double) -> Void
        init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }

    public static func extractApp(from zip: URL) throws -> URL {
        let dest = zip.deletingLastPathComponent().appendingPathComponent("extracted", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, dest.path])
        let items = try FileManager.default.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil)
        if let app = items.first(where: { $0.pathExtension == "app" }) { return app }
        for folder in items where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let inner = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            if let app = inner.first(where: { $0.pathExtension == "app" }) { return app }
        }
        throw FalconError.storage("No .app found in the downloaded update")
    }

    public static func bundleVersion(of app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        return (NSDictionary(contentsOf: plist) as? [String: Any])?["CFBundleShortVersionString"] as? String
    }

    public static func verifySignature(of app: URL) throws {
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }

    public static func isTranslocated(_ app: URL) -> Bool {
        app.path.contains("/AppTranslocation/")
    }

    public static func isReplaceable(_ app: URL) -> Bool {
        guard !isTranslocated(app) else { return false }
        let parent = app.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent) else { return false }
        if let values = try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey]), values.volumeIsReadOnly == true { return false }
        return true
    }

    public static func preferredInstallLocation(named name: String = "FalconMail.app") -> URL {
        let fm = FileManager.default
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if fm.isWritableFile(atPath: system.path) { return system.appendingPathComponent(name) }
        let user = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        try? fm.createDirectory(at: user, withIntermediateDirectories: true)
        return user.appendingPathComponent(name)
    }

    @discardableResult
    public static func install(newApp: URL, replacing current: URL) throws -> URL {
        let fm = FileManager.default
        try run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path], allowFailure: true)
        let target = isReplaceable(current) ? current : preferredInstallLocation(named: current.lastPathComponent)
        let backup = fm.temporaryDirectory.appendingPathComponent("FalconMail-previous-\(UUID().uuidString).app")
        let hadExisting = fm.fileExists(atPath: target.path)
        if hadExisting { try fm.moveItem(at: target, to: backup) }
        do {
            try fm.copyItem(at: newApp, to: target)
        } catch {
            try? fm.removeItem(at: target)
            if hadExisting { try? fm.moveItem(at: backup, to: target) }
            throw FalconError.storage("Could not install into \(target.deletingLastPathComponent().path): \(error.localizedDescription)")
        }
        if hadExisting { try? fm.removeItem(at: backup) }
        return target
    }

    public static func moveToApplications(from current: URL) throws -> URL {
        let target = preferredInstallLocation(named: current.lastPathComponent)
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.copyItem(at: current, to: target)
        try run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", target.path], allowFailure: true)
        if isReplaceable(current) { try? fm.trashItem(at: current, resultingItemURL: nil) }
        return target
    }

    public static func isInApplicationsFolder(_ app: URL) -> Bool {
        let path = app.deletingLastPathComponent().path
        return path == "/Applications" || path.hasSuffix("/Applications") || path.hasPrefix("/Applications/")
    }

    public static func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open -n \"\(app.path)\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try? p.run()
    }

    static func run(_ tool: String, _ args: [String], allowFailure: Bool = false) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 && !allowFailure {
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw FalconError.storage("\(URL(fileURLWithPath: tool).lastPathComponent) failed: \(text.trimmed)")
        }
    }
}

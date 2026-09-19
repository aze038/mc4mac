import Foundation

public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]
    public let raw: String

    public init(_ string: String) {
        raw = string
        let cleaned = string.trimmed.removingPrefix("v").removingPrefix("V")
        let core = cleaned.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? cleaned
        parts = core.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.parts.count, b.parts.count)
        for i in 0..<n {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    public var description: String { parts.map(String.init).joined(separator: ".") }
}

public struct UpdateManifest: Codable, Sendable {
    public var version: String?
    public var mandatory: Bool?
    public var minimumSupportedVersion: String?
    public var sha256: String?
    public var notes: String?
}

public struct ReleaseInfo: Sendable, Hashable {
    public var version: AppVersionBox
    public var tag: String
    public var title: String
    public var notes: String
    public var publishedAt: Date?
    public var htmlURL: String
    public var downloadURL: URL
    public var assetAPIURL: URL?
    public var assetName: String
    public var assetSize: Int
    public var sha256: String?
    public var mandatory: Bool
    public var minimumSupportedVersion: String?

    public func isMandatory(currentVersion: AppVersion) -> Bool {
        if mandatory { return true }
        if let min = minimumSupportedVersion, currentVersion < AppVersion(min) { return true }
        return false
    }
}

public struct AppVersionBox: Hashable, Sendable {
    public let value: AppVersion
    public init(_ v: AppVersion) { value = v }
    public static func == (a: AppVersionBox, b: AppVersionBox) -> Bool { a.value == b.value }
    public func hash(into hasher: inout Hasher) { hasher.combine(value.description) }
}

public struct GitHubReleaseClient: Sendable {
    public let owner: String
    public let repo: String
    public let token: String?
    private let session: URLSession

    public init(repository: String, token: String? = nil, session: URLSession = .shared) {
        let parts = repository.split(separator: "/").map(String.init)
        owner = parts.first ?? ""
        repo = parts.count > 1 ? parts[1] : ""
        self.token = token
        self.session = session
    }

    struct GHAsset: Decodable {
        var name: String
        var size: Int
        var browser_download_url: String
        var url: String
    }

    struct GHRelease: Decodable {
        var tag_name: String
        var name: String?
        var body: String?
        var draft: Bool
        var prerelease: Bool
        var published_at: String?
        var html_url: String
        var assets: [GHAsset]
    }

    func request(_ url: URL, accept: String) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(accept, forHTTPHeaderField: "Accept")
        r.setValue("FalconMail", forHTTPHeaderField: "User-Agent")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token, !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }

    public func latestRelease(includePrerelease: Bool = false) async throws -> ReleaseInfo? {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=20")!
        let (data, response) = try await session.data(for: request(url, accept: "application/vnd.github+json"))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw FalconError.http(status, "GitHub releases: \(String(data.utf8Lossy.prefix(200)))") }
        let releases = try JSONDecoder().decode([GHRelease].self, from: data)
        let candidates = releases.filter { !$0.draft && (includePrerelease || !$0.prerelease) }
        var best: (GHRelease, AppVersion)?
        for r in candidates {
            let v = AppVersion(r.tag_name)
            if best == nil || best!.1 < v { best = (r, v) }
        }
        guard let (release, version) = best else { return nil }
        guard let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") && $0.name.lowercased().contains("falconmail") })
                ?? release.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }) else { return nil }
        var manifest: UpdateManifest?
        if let m = release.assets.first(where: { $0.name == "update.json" }) {
            manifest = try? await fetchManifest(m)
        }
        let body = release.body ?? ""
        let bodyMandatory = body.range(of: "^\\s*mandatory\\s*:\\s*true\\s*$", options: [.regularExpression, .caseInsensitive, .anchored]) != nil
            || body.lowercased().contains("[mandatory]")
        let published = release.published_at.flatMap { ISO8601DateFormatter.archive.date(from: $0) }
        return ReleaseInfo(
            version: AppVersionBox(version), tag: release.tag_name, title: release.name ?? release.tag_name,
            notes: manifest?.notes ?? body, publishedAt: published, htmlURL: release.html_url,
            downloadURL: URL(string: asset.browser_download_url)!, assetAPIURL: URL(string: asset.url), assetName: asset.name,
            assetSize: asset.size, sha256: manifest?.sha256, mandatory: manifest?.mandatory ?? bodyMandatory,
            minimumSupportedVersion: manifest?.minimumSupportedVersion)
    }

    private func fetchManifest(_ asset: GHAsset) async throws -> UpdateManifest {
        let url = (token?.isEmpty == false) ? URL(string: asset.url)! : URL(string: asset.browser_download_url)!
        let (data, _) = try await session.data(for: request(url, accept: "application/octet-stream"))
        return try JSONDecoder().decode(UpdateManifest.self, from: data)
    }

    public func downloadRequest(for release: ReleaseInfo) -> URLRequest {
        if let token, !token.isEmpty, let api = release.assetAPIURL {
            return request(api, accept: "application/octet-stream")
        }
        return request(release.downloadURL, accept: "application/octet-stream")
    }
}

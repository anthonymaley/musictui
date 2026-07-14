// Real cover art for the Library/Playlists hero panes. Album artwork URLs are
// stable {w}x{h} CDN templates; playlist artwork URLs are pre-signed and expire
// in 24h (both live-probed 2026-07-14) — so bytes are cached on disk forever,
// URLs never are. Rendering reuses artworkToAscii (chafa half-blocks, mono
// fallback). Every failure degrades silently to the caller's gradient
// placeholder; a per-session negative cache stops retry loops.
import Foundation

final class ArtworkStore {
    /// {w}x{h} substitution for album CDN templates; pre-signed playlist URLs
    /// contain no placeholder and pass through verbatim.
    static func resolveURL(_ template: String, width: Int, height: Int) -> String {
        template.replacingOccurrences(of: "{w}x{h}", with: "\(width)x\(height)")
    }

    /// Filesystem-safe cache key from a REST resource id.
    static func cacheKey(_ raw: String) -> String {
        String(raw.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    private let cacheDir: String
    private let fetch: (String) -> Data?
    private let render: (String, Int, Int) -> [String]
    private let queue = DispatchQueue(label: "music.artwork")
    private let lock = NSLock()
    private var rendered: [String: [String]] = [:]   // "\(key)|\(w)x\(h)" → lines
    private var inFlight: Set<String> = []
    private var failed: Set<String> = []             // per-session negative cache

    init(cacheDir: String = NSString(string: "~/.config/music/art-cache").expandingTildeInPath,
         fetch: ((String) -> Data?)? = nil,
         render: ((String, Int, Int) -> [String])? = nil) {
        self.cacheDir = cacheDir
        self.fetch = fetch ?? { urlString in
            guard let url = URL(string: urlString) else { return nil }
            return try? Data(contentsOf: url)   // store's serial queue only, never the main thread
        }
        self.render = render ?? { path, w, h in artworkToAscii(path: path, width: w, height: h) }
    }

    /// Rendered cover lines if ready, else nil — and (once per key+size) a
    /// background fetch+render is kicked; `onReady` fires from the store's queue
    /// when lines land. Callers repaint on their next tick and get the memory hit.
    func lines(key rawKey: String, url: String, width: Int, height: Int,
               onReady: @escaping () -> Void) -> [String]? {
        let key = Self.cacheKey(rawKey)
        let memoKey = "\(key)|\(width)x\(height)"
        lock.lock()
        if let hit = rendered[memoKey] { lock.unlock(); return hit }
        if failed.contains(key) || inFlight.contains(memoKey) { lock.unlock(); return nil }
        inFlight.insert(memoKey)
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let path = "\(self.cacheDir)/\(key)"
            if !FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.createDirectory(atPath: self.cacheDir, withIntermediateDirectories: true)
                guard let data = self.fetch(url), !data.isEmpty else {
                    self.lock.lock(); self.failed.insert(key); self.inFlight.remove(memoKey); self.lock.unlock()
                    return
                }
                try? data.write(to: URL(fileURLWithPath: path))
            }
            let lines = self.render(path, width, height)
            self.lock.lock()
            if lines.isEmpty { self.failed.insert(key) } else { self.rendered[memoKey] = lines }
            self.inFlight.remove(memoKey)
            self.lock.unlock()
            if !lines.isEmpty { onReady() }
        }
        return nil
    }
}

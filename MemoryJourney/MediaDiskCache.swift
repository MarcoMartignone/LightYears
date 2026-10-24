import Foundation
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

/// Rebuildable, private media cache. All file I/O and image encoding are actor-isolated
/// away from the main actor; filenames never contain Photos identifiers.
actor MediaDiskCache {
    static let shared = MediaDiskCache()
    struct Entry: Codable { let filename: String; let bytes: Int; var accessed: Date }
    struct Snapshot: Sendable { let sizes: [String: Int]; var bytes: Int { sizes.values.reduce(0, +) } }
    private let root: URL
    private let limit: Int
    private var entries: [String: Entry] = [:]
    private var loaded = false
    private var protected = Set<String>()
    init(root: URL? = nil, limit: Int = 512 * 1024 * 1024) {
        self.root = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LightYears/Media-v1", isDirectory: true)
        self.limit = limit
    }
    private var manifest: URL { root.appendingPathComponent("index.json") }
    private func load() {
        guard !loaded else { return }
        loaded = true
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var directory = root
        var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true
        try? directory.setResourceValues(attributes)
        if let data = try? Data(contentsOf: manifest), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved.filter { _, entry in
                guard entry.filename == URL(fileURLWithPath: entry.filename).lastPathComponent,
                      entry.bytes > 0,
                      let size = try? root.appendingPathComponent(entry.filename).resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
                return size == entry.bytes
            }
        }
        // Remove abandoned atomic writes and files whose manifest was lost on a crash.
        let known = Set(entries.values.map(\.filename)).union(["index.json"])
        for file in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where !known.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
    private func save() { if let data = try? JSONEncoder().encode(entries) { try? data.write(to: manifest, options: .atomic) } }
    func snapshot() -> Snapshot {
        load()
        for (key, entry) in entries where !FileManager.default.fileExists(atPath: root.appendingPathComponent(entry.filename).path) { entries[key] = nil }
        return Snapshot(sizes: entries.mapValues(\.bytes))
    }
    func protect(_ keys: Set<String>) { protected = keys }
    func data(for key: String) -> Data? {
        guard let url = file(for: key), let data = try? Data(contentsOf: url), !data.isEmpty else { remove(key); return nil }
        return data
    }
    func file(for key: String) -> URL? {
        load()
        guard var entry = entries[key] else { return nil }
        let url = root.appendingPathComponent(entry.filename)
        guard let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes == entry.bytes else { remove(key); return nil }
        entry.accessed = Date(); entries[key] = entry
        return url
    }
    @discardableResult func store(_ data: Data, for key: String, extension suffix: String = "heic") -> Bool {
        load()
        guard !data.isEmpty, data.count <= limit, makeRoom(for: data.count, replacing: key) else { return false }
        let filename = digest(key) + "." + suffix
        let url = root.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            #if os(iOS)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            #endif
            entries[key] = Entry(filename: filename, bytes: data.count, accessed: Date())
            save(); return true
        } catch { return false }
    }
    @discardableResult func storeFile(_ source: URL, for key: String) -> Bool {
        load()
        guard source.isFileURL,
              let bytes = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              bytes > 0, bytes <= limit, makeRoom(for: bytes, replacing: key) else { return false }
        let filename = digest(key) + ".mov"
        let target = root.appendingPathComponent(filename)
        let temporary = root.appendingPathComponent(UUID().uuidString + ".tmp")
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: temporary, to: target)
            #if os(iOS)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
            #endif
            entries[key] = Entry(filename: filename, bytes: bytes, accessed: Date())
            save(); return true
        } catch { try? FileManager.default.removeItem(at: temporary); return false }
    }
    private func makeRoom(for bytes: Int, replacing key: String) -> Bool {
        var used = entries.filter { $0.key != key }.values.reduce(0) { $0 + $1.bytes }
        for (candidate, entry) in entries.sorted(by: { $0.value.accessed < $1.value.accessed }) where candidate != key && !protected.contains(candidate) && used + bytes > limit {
            entries[candidate] = nil
            try? FileManager.default.removeItem(at: root.appendingPathComponent(entry.filename))
            used -= entry.bytes
        }
        save()
        return used + bytes <= limit
    }
    func remove(_ key: String) {
        load()
        if let entry = entries.removeValue(forKey: key) { try? FileManager.default.removeItem(at: root.appendingPathComponent(entry.filename)) }
        save()
    }
    func removeAll() {
        load(); entries.removeAll(); protected.removeAll()
        try? FileManager.default.removeItem(at: root)
        loaded = false
    }
    private func digest(_ key: String) -> String { SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() }

    #if canImport(UIKit)
    func image(for key: String) async -> UIImage? {
        guard let data = data(for: key) else { return nil }
        var options = UIImageReader.Configuration()
        options.prefersHighDynamicRange = true
        options.preparesImagesForDisplay = true
        options.preferredThumbnailSize = CGSize(width: 3200, height: 3200)
        let image = await UIImageReader(configuration: options).image(data: data)
        if image == nil { remove(key) }
        return image
    }
    nonisolated func storeImage(_ image: UIImage, for key: String) async -> Bool {
        // Encoding must not block a foreground cache read on this actor.
        let data = await Task.detached(priority: .utility) {
            image.heicData() ?? (image.isHighDynamicRange ? nil : image.jpegData(compressionQuality: 0.92))
        }.value
        guard !Task.isCancelled, let data else { return false }
        return await store(data, for: key)
    }
    #endif
}

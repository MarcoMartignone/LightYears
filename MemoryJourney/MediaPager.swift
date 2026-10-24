import SwiftUI
import UIKit
import Photos
import AVFoundation
import UniformTypeIdentifiers
import Observation

@MainActor
enum MediaNavigationTrace {
    private static var lines: [String] = []
    private static var flush: Task<Void, Never>?
    static func event(_ message: String) {
        #if DEBUG
        lines.append("\(Int(ProcessInfo.processInfo.systemUptime * 1000)) \(message)")
        if lines.count > 1200 { lines.removeFirst(lines.count - 1200) }
        guard flush == nil else { return }
        flush = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("navigation-diagnostics.txt")
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            flush = nil
        }
        #endif
    }
}

/// Let iOS enforce Silent mode; never infer the ringer switch ourselves.
@MainActor
enum MemoryVideoAudio {
    static func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            if session.category != .ambient || session.mode != .default {
                try session.setCategory(.ambient, mode: .default)
            }
            try session.setActive(true)
        } catch {
            MediaNavigationTrace.event("audio-session activation failed")
        }
    }
}

/// One selected day's metadata, a bounded decoded-image cache, and at most two warm videos.
/// Photos owns iCloud transfers; display images and local video files also use a
/// private, bounded disk cache. Only this day's assets are prepared.
@MainActor
final class DayMediaPipeline {
    let manager: PHCachingImageManager
    let previews = NSCache<NSString, UIImage>()
    let fullImages = NSCache<NSString, UIImage>()
    var onUpdate: ((String) -> Void)?
    var onPreparation: ((MediaPreparationSnapshot) -> Void)?
    private var preparationCollectionID = UUID()
    private let disk = MediaDiskCache.shared
    private var cachedSizes: [String: Int] = [:]
    private var memoryByID: [String: Memory] = [:]
    private var cacheReads: [String: Task<Void, Never>] = [:]
    private var diskWrites: [String: Task<Void, Never>] = [:]
    private var thumbnailReads: [String: Task<Void, Never>] = [:]
    private var failedThumbnails = Set<String>()
    private var thumbnailWatchdogs: [String: Task<Void, Never>] = [:]
    private var preparationUpdate: Task<Void, Never>?
    private var hasPrioritized = false
    private var videoQueue: [String] = []
    private var videoReads: [String: Task<Void, Never>] = [:]
    private var nearbyVideos = Set<String>()
    private var videoMixes: [String: AVAudioMix] = [:]
    private var preparedVideos: [String: AVAsset] = [:]
    private var backgroundVideoID: String?
    private var videoWatchdogs: [String: Task<Void, Never>] = [:]
    private(set) var memories: [Memory] = []
    private(set) var players: [String: AVPlayer] = [:]
    private(set) var messages: [String: String] = [:]
    private(set) var progress: [String: Double] = [:]
    private var assets: [String: PHAsset] = [:]
    private var thumbnailQueue: [String] = []
    private var photoQueue: [String] = []
    private var warmedPhotos = Set<String>()
    private var nearbyPhotos = Set<String>()
    private var backgroundPhotoID: String?
    private var completedThumbnails = Set<String>()
    private var thumbnailRequests: [String: PHImageRequestID] = [:]
    private var imageRequests: [String: PHImageRequestID] = [:]
    private var videoRequests: [String: PHImageRequestID] = [:]
    private var imageTokens: [String: UUID] = [:]
    private var thumbnailTokens: [String: UUID] = [:]
    private var failedPhotos = Set<String>()
    private var photoRetryCounts: [String: Int] = [:]
    private var photoRetryTasks: [String: Task<Void, Never>] = [:]
    private var photoWatchdogs: [String: Task<Void, Never>] = [:]
    private var videoTokens: [String: UUID] = [:]
    private var playerObservers: [String: NSKeyValueObservation] = [:]
    private var pausedVideos = Set<String>()
    private var token = UUID()
    private var version = -1
    private var activeIndex = 0
    // One strong reference: opportunistic NSCache eviction must not downgrade the selected photo.
    private var selectedPhoto: (id: String, image: UIImage)?
    private var suspended = false
    private var scrubbing = false
    func setScrubbing(_ value: Bool) -> Bool {
        guard scrubbing != value else { return false }
        scrubbing = value
        return true
    }
    private(set) var muted = false

    init(manager: PHCachingImageManager = PHCachingImageManager()) {
        self.manager = manager
        previews.countLimit = 128
        previews.totalCostLimit = 64 * 1024 * 1024
        fullImages.countLimit = 4
        fullImages.totalCostLimit = 128 * 1024 * 1024
        manager.allowsCachingHighQualityImages = true
    }
    func configure(_ values: [Memory], revision: Int) {
        guard values != memories || revision != version else { return }
        cancelRequests()
        players.values.forEach { $0.pause() }
        players.removeAll(); playerObservers.removeAll(); assets.removeAll()
        previews.removeAllObjects(); fullImages.removeAllObjects(); selectedPhoto = nil
        completedThumbnails.removeAll(); failedPhotos.removeAll(); photoRetryCounts.removeAll(); messages.removeAll(); progress.removeAll()
        memories = values; version = revision
        preparationCollectionID = UUID()
        memoryByID = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        hasPrioritized = false
        warmedPhotos.removeAll(); preparedVideos.removeAll(); videoMixes.removeAll(); failedThumbnails.removeAll()
        cachedSizes.removeAll()
        let generation = token
        Task { [weak self, disk] in
            let snapshot = await disk.snapshot()
            guard let self, self.token == generation else { return }
            self.cachedSizes = snapshot.sizes
            self.warmedPhotos.formUnion(values.filter { !$0.isVideo && snapshot.sizes[$0.cacheKey("photo")] != nil }.map(\.id))
            self.notifyPreparation(); self.pumpPhotos()
        }
        photoQueue.removeAll(); backgroundPhotoID = nil
        let ids = values.compactMap(\.assetID)
        if !ids.isEmpty {
            PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
                self.assets[asset.localIdentifier] = asset
            }
        }
    }
    func diagnosticIndex(_ id: String) -> Int { memories.firstIndex { $0.id == id } ?? -1 }
    func dimensions(for memory: Memory) -> CGSize {
        guard let id = memory.assetID, let asset = assets[id] else { return CGSize(width: 430, height: 930) }
        return CGSize(width: max(1, asset.pixelWidth), height: max(1, asset.pixelHeight))
    }
    func image(for memory: Memory) -> UIImage? {
        if selectedPhoto?.id == memory.id { return selectedPhoto?.image }
        if let image = fullImages.object(forKey: memory.id as NSString) {
            if memories[safe: activeIndex]?.id == memory.id { selectedPhoto = (memory.id, image) }
            return image
        }
        if let image = previews.object(forKey: memory.id as NSString) { return image }
        guard memory.assetID == nil else { return nil }
        let renderer = ImageRenderer(content: SampleLandscape(scene: memory.scene).frame(width: 430, height: 930))
        renderer.scale = 2
        if let image = renderer.uiImage {
            previews.setObject(image, forKey: memory.id as NSString, cost: Self.cost(image))
            return image
        }
        return nil
    }
    func prioritize(_ index: Int, force: Bool = false) {
        guard memories.indices.contains(index) else { return }
        guard force || !hasPrioritized || activeIndex != index else { return }
        hasPrioritized = true
        let moved = activeIndex != index
        activeIndex = index
        let selectedID = memories[index].id
        if moved && !memories[index].isVideo {
            // A speculative failure must never poison a later foreground visit.
            messages[selectedID] = nil; failedPhotos.remove(selectedID); photoRetryCounts[selectedID] = nil
        }
        for (id, task) in photoRetryTasks where id != selectedID { task.cancel(); photoRetryTasks[id] = nil }
        if selectedPhoto?.id != selectedID {
            selectedPhoto = fullImages.object(forKey: selectedID as NSString).map { (selectedID, $0) }
        }
        guard !suspended else { return }
        DayPlacePreloader.shared.prioritize(memories, index: index)
        let plan = MediaPreloadPlan(memories: memories, selectedIndex: index)
        let nearby = scrubbing ? Set([selectedID]) : Set(plan.fullResolutionIDs)
        nearbyPhotos = nearby
        for (id, request) in imageRequests where !nearby.contains(id) && (scrubbing || id != backgroundPhotoID) {
            manager.cancelImageRequest(request); imageRequests[id] = nil; imageTokens[id] = nil
            photoWatchdogs.removeValue(forKey: id)?.cancel(); progress[id] = nil
            if backgroundPhotoID == id { backgroundPhotoID = nil }
        }
        // Keep in-flight background work alive while the wheel moves. Only
        // obsolete foreground decodes are cancelled; the next queue item reprioritizes.
        for (id, task) in cacheReads where !nearby.contains(id) && (scrubbing || id != backgroundPhotoID) {
            task.cancel(); cacheReads[id] = nil
        }
        let protectedKeys = Set(plan.fullResolutionIDs.compactMap { memoryByID[$0]?.cacheKey("photo") }
            + plan.videoIDs.compactMap { memoryByID[$0]?.cacheKey("video") })
        Task { [disk] in await disk.protect(protectedKeys) }
        let videoIDs = (scrubbing ? Set<String>() : Set(plan.videoIDs)).union(memories[index].isVideo ? [selectedID] : [])
        nearbyVideos = videoIDs
        for (id, request) in videoRequests where !videoIDs.contains(id) && (scrubbing || id != backgroundVideoID) {
            manager.cancelImageRequest(request); videoRequests[id] = nil; videoTokens[id] = nil
            videoWatchdogs.removeValue(forKey: id)?.cancel(); progress[id] = nil
        }
        for (id, task) in videoReads where !videoIDs.contains(id) && (scrubbing || id != backgroundVideoID) {
            task.cancel(); videoReads[id] = nil
        }
        for (id, player) in players where !videoIDs.contains(id) {
            player.pause(); players[id] = nil; playerObservers[id] = nil
        }
        // The displayed photo/video starts before background thumbnail work.
        if !scrubbing {
            for id in plan.fullResolutionIDs { requestFullImage(id) }
            for id in plan.videoIDs { requestVideo(id) }
        } else {
            backgroundPhotoID = nil
            backgroundVideoID = nil
        }
        let previewNeighborhood = Set((max(0, index - 2)...min(memories.count - 1, index + 2)).map { memories[$0].id })
        thumbnailQueue = plan.thumbnailIDs.filter { id in
            (!completedThumbnails.contains(id) || (previewNeighborhood.contains(id) && previews.object(forKey: id as NSString) == nil))
                && thumbnailRequests[id] == nil && thumbnailReads[id] == nil && !failedThumbnails.contains(id)
        }
        pumpThumbnails()
        photoQueue = plan.thumbnailIDs.filter { assets[$0]?.mediaType == .image && !warmedPhotos.contains($0) && messages[$0] == nil }
        videoQueue = plan.thumbnailIDs.filter { assets[$0]?.mediaType == .video && preparedVideos[$0] == nil && messages[$0] == nil }
        pumpPhotos(); pumpVideos(); notifyPreparation()
    }
    func suspend(_ value: Bool) {
        guard value != suspended else { return }
        suspended = value
        if value { DayPlacePreloader.shared.pause(); cancelRequests(); players.values.forEach { $0.pause() } }
        else {
            let generation = token
            Task { [weak self, disk] in
                let snapshot = await disk.snapshot()
                guard let self, self.token == generation else { return }
                self.cachedSizes = snapshot.sizes; self.notifyPreparation()
            }
            prioritize(activeIndex, force: true)
        }
        notifyPreparation()
    }
    func memoryWarning() {
        previews.removeAllObjects(); fullImages.removeAllObjects()
        completedThumbnails.removeAll()
        guard memories.indices.contains(activeIndex) else { return }
        let keep = memories[activeIndex].id
        for (id, player) in players where id != keep { player.pause(); players[id] = nil; playerObservers[id] = nil }
    }
    func shutdown() {
        DayPlacePreloader.shared.clear()
        suspended = true
        cancelRequests()
        players.values.forEach { $0.pause() }
        playerObservers.removeAll()
    }
    func restartPlayback(_ id: String) {
        pausedVideos.remove(id); players[id]?.seek(to: .zero); onUpdate?(id)
    }
    private var seekingVideos = Set<String>()
    func wantsPlayback(_ id: String) -> Bool { !pausedVideos.contains(id) && !seekingVideos.contains(id) }
    func beginSeeking(_ id: String) { seekingVideos.insert(id); players[id]?.pause() }
    func endSeeking(_ id: String) { seekingVideos.remove(id); onUpdate?(id) }
    func togglePlayback(_ id: String) {
        if pausedVideos.contains(id) { pausedVideos.remove(id) } else { pausedVideos.insert(id) }
        onUpdate?(id)
    }
    func toggleSound() {
        muted.toggle()
        if !muted {
            MemoryVideoAudio.activate()
        }
        players.values.forEach { $0.isMuted = muted }
        if memories.indices.contains(activeIndex) { onUpdate?(memories[activeIndex].id) }
    }
    func retry(_ id: String) {
        messages[id] = nil; completedThumbnails.remove(id); failedPhotos.remove(id); photoRetryCounts[id] = nil
        photoRetryTasks.removeValue(forKey: id)?.cancel()
        players[id]?.pause(); players[id] = nil; playerObservers[id] = nil
        failedThumbnails.remove(id)
        prioritize(activeIndex, force: true)
    }
    func retryPreparation() {
        failedPhotos.removeAll(); failedThumbnails.removeAll(); messages.removeAll(); photoRetryCounts.removeAll()
        prioritize(activeIndex, force: true)
    }
    private func cancelRequests() {
        token = UUID()
        progress.removeAll()
        thumbnailWatchdogs.values.forEach { $0.cancel() }; thumbnailWatchdogs.removeAll()
        preparationUpdate?.cancel(); preparationUpdate = nil
        for task in Array(cacheReads.values) + Array(thumbnailReads.values) + Array(diskWrites.values) + Array(videoReads.values) { task.cancel() }
        cacheReads.removeAll(); thumbnailReads.removeAll(); diskWrites.removeAll(); videoReads.removeAll()
        videoWatchdogs.values.forEach { $0.cancel() }; videoWatchdogs.removeAll(); backgroundVideoID = nil
        for request in Array(thumbnailRequests.values) + Array(imageRequests.values) + Array(videoRequests.values) { manager.cancelImageRequest(request) }
        thumbnailRequests.removeAll(); imageRequests.removeAll(); videoRequests.removeAll()
        imageTokens.removeAll(); thumbnailTokens.removeAll(); videoTokens.removeAll(); backgroundPhotoID = nil
        photoWatchdogs.values.forEach { $0.cancel() }; photoWatchdogs.removeAll()
        photoRetryTasks.values.forEach { $0.cancel() }; photoRetryTasks.removeAll()
    }
    private func pumpPhotos() {
        // Only one background photo, after the visible neighborhood has finished.
        guard !suspended, !scrubbing, imageRequests.isEmpty, cacheReads.isEmpty, diskWrites.count < 2, backgroundPhotoID == nil else { return }
        while !photoQueue.isEmpty {
            let id = photoQueue.removeFirst()
            guard !warmedPhotos.contains(id), !failedPhotos.contains(id), messages[id] == nil, assets[id] != nil else { continue }
            if fullImages.object(forKey: id as NSString) != nil || selectedPhoto?.id == id { markWarm(id); continue }
            backgroundPhotoID = id
            if requestFullImage(id) { return }
            backgroundPhotoID = nil
        }
    }
    private func markWarm(_ id: String) {
        warmedPhotos.insert(id)
        notifyPreparation()
    }
    private func notifyPreparation() {
        guard preparationUpdate == nil else { return }
        let generation = token
        preparationUpdate = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard let self, self.token == generation else { return }
            self.preparationUpdate = nil
            let real = self.memories.filter { $0.assetID != nil }
            let ready = real.filter { $0.isVideo ? self.preparedVideos[$0.id] != nil : self.warmedPhotos.contains($0.id) }.count
            let cached = real.filter { self.cachedSizes[$0.cacheKey($0.isVideo ? "video" : "photo")] != nil }.count
            let failures = real.filter { self.failedPhotos.contains($0.id) || self.messages[$0.id] != nil || self.failedThumbnails.contains($0.id) }.count
            let downloading = self.progress.values.filter { $0 < 1 }.count
            self.onPreparation?(MediaPreparationSnapshot(collectionID: self.preparationCollectionID, total: real.count, ready: ready,
                previews: self.completedThumbnails.count, cached: cached, cacheBytes: self.cachedSizes.values.reduce(0, +),
                failures: failures, transfers: downloading,
                fraction: real.isEmpty ? 0 : min(1, Double(ready) / Double(real.count)), suspended: self.suspended))
        }
    }
    private func persist(_ image: UIImage, id: String, kind: String) {
        // Backpressure bounds retained full-size images during very fast scrubbing.
        // Speculative queues wait below; foreground display never waits for encoding.
        guard diskWrites.count < 4, let key = memoryByID[id]?.cacheKey(kind), diskWrites[key] == nil else { return }
        let generation = token
        diskWrites[key] = Task { @MainActor [weak self, disk] in
            _ = await disk.storeImage(image, for: key)
            let snapshot = await disk.snapshot()
            guard let self, self.token == generation, !Task.isCancelled else { return }
            self.diskWrites[key] = nil
            self.cachedSizes = snapshot.sizes
            self.notifyPreparation(); self.pumpPhotos(); self.pumpVideos(); self.pumpThumbnails()
        }
    }
    private func pumpThumbnails() {
        guard !suspended else { return }
        while thumbnailRequests.count + thumbnailReads.count < 2 && !thumbnailQueue.isEmpty && diskWrites.count < 4 {
            let id = thumbnailQueue.removeFirst()
            guard let asset = assets[id], let key = memoryByID[id]?.cacheKey("preview") else { continue }
            let generation = token
            thumbnailReads[id] = Task { @MainActor [weak self, disk] in
                let cached = await disk.image(for: key)
                guard let self, self.token == generation, !Task.isCancelled else { return }
                self.thumbnailReads[id] = nil
                if let cached {
                    self.storePreview(cached, for: id)
                    self.completedThumbnails.insert(id)
                    self.onUpdate?(id); self.notifyPreparation(); self.pumpThumbnails()
                } else { self.requestThumbnail(asset, id: id, generation: generation) }
            }
        }
    }
    private func requestThumbnail(_ asset: PHAsset, id: String, generation: UUID) {
        let requestToken = UUID(); thumbnailTokens[id] = requestToken
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.progressHandler = { [weak self] _, _, _, _ in
            Task { @MainActor in
                guard let self, self.token == generation, self.thumbnailTokens[id] == requestToken else { return }
                self.watchThumbnail(id, generation: generation, requestToken: requestToken)
            }
        }
        watchThumbnail(id, generation: generation, requestToken: requestToken)
        thumbnailRequests[id] = manager.requestImage(for: asset, targetSize: CGSize(width: 420, height: 420), contentMode: .aspectFit, options: options) { [weak self] image, info in
            let outcome = PhotoDeliveryOutcome.classify(hasImage: image != nil,
                degraded: info?[PHImageResultIsDegradedKey] as? Bool ?? false,
                cancelled: info?[PHImageCancelledKey] as? Bool ?? false, failed: info?[PHImageErrorKey] != nil)
            Task { @MainActor in
                guard let self, self.token == generation, self.thumbnailTokens[id] == requestToken else { return }
                if let image, outcome != .failure { self.storePreview(image, for: id) }
                guard outcome != .preview else { self.onUpdate?(id); return }
                self.thumbnailRequests[id] = nil; self.thumbnailTokens[id] = nil
                self.thumbnailWatchdogs.removeValue(forKey: id)?.cancel()
                if outcome == .complete, let image {
                    self.completedThumbnails.insert(id); self.persist(image, id: id, kind: "preview")
                } else { self.failedThumbnails.insert(id) }
                self.onUpdate?(id); self.notifyPreparation(); self.pumpThumbnails()
            }
        }
    }
    private func watchThumbnail(_ id: String, generation: UUID, requestToken: UUID) {
        thumbnailWatchdogs.removeValue(forKey: id)?.cancel()
        thumbnailWatchdogs[id] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard let self, self.token == generation, self.thumbnailTokens[id] == requestToken,
                  let request = self.thumbnailRequests.removeValue(forKey: id) else { return }
            self.thumbnailTokens[id] = nil; self.thumbnailWatchdogs[id] = nil
            self.manager.cancelImageRequest(request); self.failedThumbnails.insert(id)
            self.notifyPreparation(); self.pumpThumbnails()
        }
    }
    @discardableResult
    private func requestFullImage(_ id: String) -> Bool {
        guard !suspended, let key = memoryByID[id]?.cacheKey("photo"), assets[id]?.mediaType == .image,
              fullImages.object(forKey: id as NSString) == nil, selectedPhoto?.id != id,
              imageRequests[id] == nil, cacheReads[id] == nil, messages[id] == nil,
              photoRetryTasks[id] == nil, !failedPhotos.contains(id) || memories[safe: activeIndex]?.id == id else { return false }
        let generation = token
        cacheReads[id] = Task { @MainActor [weak self, disk] in
            let image = await disk.image(for: key)
            guard let self, self.token == generation, !Task.isCancelled else { return }
            self.cacheReads[id] = nil
            let sufficient = image.map { image in
                guard let asset = self.assets[id] else { return false }
                return PhotoPixelQuality.isSufficient(deliveredLongestEdge: Double(max(image.size.width, image.size.height) * image.scale), sourceLongestEdge: max(asset.pixelWidth, asset.pixelHeight))
            } ?? false
            if let image, sufficient {
                self.storeFullImage(image, for: id); self.markWarm(id)
                if self.backgroundPhotoID == id { self.backgroundPhotoID = nil }
                self.onUpdate?(id); self.pumpPhotos()
            } else {
                if let image { self.storePreview(image, for: id) }
                // Fetch full quality immediately; remove only this undersized cache entry.
                if image != nil {
                    await disk.remove(key)
                    guard self.token == generation, !Task.isCancelled else { return }
                }
                self.cachedSizes[key] = nil; self.warmedPhotos.remove(id); self.notifyPreparation()
                if !self.requestPhotoKitImage(id), self.backgroundPhotoID == id { self.backgroundPhotoID = nil; self.pumpPhotos() }
            }
        }
        return true
    }
    @discardableResult
    private func requestPhotoKitImage(_ id: String) -> Bool {
        guard let asset = assets[id], asset.mediaType == .image,
              fullImages.object(forKey: id as NSString) == nil, selectedPhoto?.id != id,
              imageRequests[id] == nil, messages[id] == nil, photoRetryTasks[id] == nil,
              !failedPhotos.contains(id) || memories[safe: activeIndex]?.id == id else { return false }
        let generation = token
        let requestToken = UUID(); imageTokens[id] = requestToken
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.preferHDR = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.progressHandler = { [weak self] value, _, _, _ in
            Task { @MainActor in
                guard let self, self.token == generation, self.imageTokens[id] == requestToken, self.imageRequests[id] != nil else { return }
                if value > (self.progress[id] ?? -1) { self.watchPhoto(id, generation: generation, requestToken: requestToken) }
                // Cells never draw progress; the debounced preparation snapshot does.
                self.progress[id] = value; self.notifyPreparation()
            }
        }
        let ratio = min(1, 3200 / CGFloat(max(asset.pixelWidth, asset.pixelHeight, 1)))
        let size = CGSize(width: CGFloat(asset.pixelWidth) * ratio, height: CGFloat(asset.pixelHeight) * ratio)
        imageRequests[id] = manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { [weak self] image, info in
            let outcome = PhotoDeliveryOutcome.classify(hasImage: image != nil,
                degraded: info?[PHImageResultIsDegradedKey] as? Bool ?? false,
                cancelled: info?[PHImageCancelledKey] as? Bool ?? false,
                failed: info?[PHImageErrorKey] != nil)
            Task { @MainActor in
                await self?.receivePhoto(image, outcome: outcome, id: id, generation: generation, requestToken: requestToken)
            }
        }
        watchPhoto(id, generation: generation, requestToken: requestToken)
        return true
    }
    private func receivePhoto(_ image: UIImage?, outcome: PhotoDeliveryOutcome, id: String, generation: UUID, requestToken: UUID, fromSourceData: Bool = false) async {
        guard token == generation, imageTokens[id] == requestToken, imageRequests[id] != nil else { return }
        if outcome == .complete, !fromSourceData, let image, let asset = assets[id],
           !PhotoPixelQuality.isSufficient(deliveredLongestEdge: Double(max(image.size.width, image.size.height) * image.scale),
                                           sourceLongestEdge: max(asset.pixelWidth, asset.pixelHeight)) {
            // Never mark a thumbnail-sized final callback as a completed photo.
            storePreview(image, for: id)
            requestSourceImage(asset, id: id, generation: generation)
            onUpdate?(id)
            return
        }
        if let image, outcome != .failure {
            if outcome == .preview { storePreview(image, for: id) }
            else {
                let prepared = await image.byPreparingForDisplay() ?? image
                guard token == generation, imageTokens[id] == requestToken else { return }
                storeFullImage(prepared, for: id)
                persist(prepared, id: id, kind: "photo")
            }
        }
        if outcome != .preview {
            imageRequests[id] = nil; imageTokens[id] = nil; progress[id] = nil
            photoWatchdogs.removeValue(forKey: id)?.cancel()
            if backgroundPhotoID == id { backgroundPhotoID = nil }
            if outcome == .complete { markWarm(id); failedPhotos.remove(id); photoRetryCounts[id] = nil }
            else {
                failedPhotos.insert(id)
                if memories[safe: activeIndex]?.id == id {
                    if (photoRetryCounts[id] ?? 0) < 1 {
                        photoRetryCounts[id, default: 0] += 1
                        photoRetryTasks[id] = Task { @MainActor [weak self] in
                            do { try await Task.sleep(for: .seconds(1)) } catch { return }
                            guard let self, self.token == generation, !self.suspended,
                                  self.memories[safe: self.activeIndex]?.id == id else { return }
                            self.photoRetryTasks[id] = nil
                            self.requestFullImage(id)
                        }
                    } else { messages[id] = "Couldn’t load this moment. Tap Retry." }
                }
            }
            pumpPhotos()
        }
        onUpdate?(id); notifyPreparation()
    }
    private func requestSourceImage(_ asset: PHAsset, id: String, generation: UUID) {
        progress[id] = nil
        let requestToken = UUID(); imageTokens[id] = requestToken
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.progressHandler = { [weak self] value, _, _, _ in
            Task { @MainActor in
                guard let self, self.token == generation, self.imageTokens[id] == requestToken else { return }
                if value > (self.progress[id] ?? -1) { self.watchPhoto(id, generation: generation, requestToken: requestToken) }
                self.progress[id] = value; self.notifyPreparation()
            }
        }
        imageRequests[id] = manager.requestImageDataAndOrientation(for: asset, options: options) { [weak self] data, _, _, info in
            let failed = info?[PHImageErrorKey] != nil || (info?[PHImageCancelledKey] as? Bool ?? false)
            Task { @MainActor in
                guard let self, self.token == generation, self.imageTokens[id] == requestToken else { return }
                var image: UIImage?
                if !failed, let data {
                    var configuration = UIImageReader.Configuration()
                    configuration.prefersHighDynamicRange = true
                    configuration.preparesImagesForDisplay = true
                    configuration.preferredThumbnailSize = CGSize(width: 3200, height: 3200)
                    image = await UIImageReader(configuration: configuration).image(data: data)
                }
                await self.receivePhoto(image, outcome: image == nil ? .failure : .complete,
                                  id: id, generation: generation, requestToken: requestToken, fromSourceData: true)
            }
        }
        watchPhoto(id, generation: generation, requestToken: requestToken)
    }
    func isLoadingPhoto(_ id: String) -> Bool { imageRequests[id] != nil || cacheReads[id] != nil || photoRetryTasks[id] != nil }
    private func watchPhoto(_ id: String, generation: UUID, requestToken: UUID) {
        photoWatchdogs.removeValue(forKey: id)?.cancel()
        photoWatchdogs[id] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard let self, self.token == generation, self.imageTokens[id] == requestToken,
                  let request = self.imageRequests[id] else { return }
            self.manager.cancelImageRequest(request)
            await self.receivePhoto(nil, outcome: .failure, id: id, generation: generation, requestToken: requestToken)
        }
    }
    private func pumpVideos() {
        guard !suspended, !scrubbing, videoRequests.isEmpty, videoReads.isEmpty,
              backgroundVideoID == nil, diskWrites.count < 2 else { return }
        while !videoQueue.isEmpty {
            let id = videoQueue.removeFirst()
            guard preparedVideos[id] == nil, messages[id] == nil, assets[id] != nil else { continue }
            backgroundVideoID = id
            requestVideo(id)
            return
        }
    }
    private func requestVideo(_ id: String) {
        if let asset = preparedVideos[id] {
            if let url = (asset as? AVURLAsset)?.url, url.isFileURL,
               !FileManager.default.fileExists(atPath: url.path) {
                preparedVideos[id] = nil; videoMixes[id] = nil
            } else { makePlayer(asset, id: id); return }
        }
        guard !suspended, let asset = assets[id], asset.mediaType == .video,
              let key = memoryByID[id]?.cacheKey("video"),
              videoRequests[id] == nil, videoReads[id] == nil, messages[id] == nil else { return }
        let generation = token
        videoReads[id] = Task { @MainActor [weak self, disk] in
            let url = await disk.file(for: key)
            let cachedAsset = url.map { AVURLAsset(url: $0) }
            let playable = if let cachedAsset { (try? await cachedAsset.load(.isPlayable)) == true } else { false }
            guard let self, self.token == generation, !Task.isCancelled else { return }
            self.videoReads[id] = nil
            if playable, let cachedAsset { self.receiveVideo(cachedAsset, mix: nil, id: id, persist: false) }
            else {
                if url != nil { await disk.remove(key) }
                self.cachedSizes[key] = nil
                self.requestPhotoKitVideo(asset, id: id, generation: generation)
            }
        }
    }
    private func requestPhotoKitVideo(_ asset: PHAsset, id: String, generation: UUID) {
        guard token == generation, !suspended else { return }
        let requestToken = UUID(); videoTokens[id] = requestToken
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        options.progressHandler = { [weak self] value, _, _, _ in
            Task { @MainActor in
                guard let self, self.token == generation, self.videoTokens[id] == requestToken else { return }
                if value > (self.progress[id] ?? -1) { self.watchVideo(id, generation: generation, requestToken: requestToken) }
                self.progress[id] = value; self.notifyPreparation()
            }
        }
        videoRequests[id] = manager.requestAVAsset(forVideo: asset, options: options) { [weak self] asset, mix, info in
            let failed = info?[PHImageErrorKey] != nil || (info?[PHImageCancelledKey] as? Bool ?? false)
            Task { @MainActor in
                guard let self, self.token == generation, self.videoTokens[id] == requestToken else { return }
                self.videoRequests[id] = nil; self.videoTokens[id] = nil; self.progress[id] = nil
                self.videoWatchdogs.removeValue(forKey: id)?.cancel()
                if !failed, let asset { self.receiveVideo(asset, mix: mix, id: id, persist: true) }
                else { self.failVideo(id) }
            }
        }
        watchVideo(id, generation: generation, requestToken: requestToken)
    }
    private func receiveVideo(_ asset: AVAsset, mix: AVAudioMix?, id: String, persist: Bool) {
        preparedVideos[id] = asset
        videoMixes[id] = mix
        if backgroundVideoID == id { backgroundVideoID = nil }
        makePlayer(asset, id: id)
        // Keep edited compositions/audio mixes in Photos' representation rather
        // than silently caching an unedited source file. Plain local files can
        // be copied cheaply without decoding or transcoding the video.
        if persist, mix == nil, let url = (asset as? AVURLAsset)?.url, url.isFileURL,
           let key = memoryByID[id]?.cacheKey("video"), diskWrites[key] == nil, diskWrites.count < 4 {
            let generation = token
            diskWrites[key] = Task { @MainActor [weak self, disk] in
                _ = await disk.storeFile(url, for: key)
                let snapshot = await disk.snapshot()
                guard let self, self.token == generation, !Task.isCancelled else { return }
                self.diskWrites[key] = nil; self.cachedSizes = snapshot.sizes
                self.notifyPreparation(); self.pumpVideos(); self.pumpPhotos(); self.pumpThumbnails()
            }
        }
        onUpdate?(id); notifyPreparation(); pumpVideos()
    }
    private func makePlayer(_ asset: AVAsset, id: String) {
        guard nearbyVideos.contains(id), players[id] == nil else { return }
        let item = AVPlayerItem(asset: asset)
        item.audioMix = videoMixes[id]
        item.preferredForwardBufferDuration = 6
        let player = AVPlayer(playerItem: item)
        player.isMuted = muted
        player.automaticallyWaitsToMinimizeStalling = true
        players[id] = player
        playerObservers[id] = item.observe(\.status, options: [.initial, .new]) { [weak self, weak player] item, _ in
            Task { @MainActor in
                guard let self, let player, self.players[id] === player else { return }
                if item.status == .failed {
                    self.preparedVideos[id] = nil; self.videoMixes[id] = nil
                    if let key = self.memoryByID[id]?.cacheKey("video") {
                        self.cachedSizes[key] = nil
                        await self.disk.remove(key)
                    }
                    self.messages[id] = "Couldn’t play this video. Tap Retry."
                }
                if item.status == .readyToPlay, self.memories[safe: self.activeIndex]?.id != id { player.preroll(atRate: 1) { _ in } }
                self.onUpdate?(id); self.notifyPreparation()
            }
        }
    }
    private func watchVideo(_ id: String, generation: UUID, requestToken: UUID) {
        videoWatchdogs.removeValue(forKey: id)?.cancel()
        videoWatchdogs[id] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard let self, self.token == generation, self.videoTokens[id] == requestToken,
                  let request = self.videoRequests.removeValue(forKey: id) else { return }
            self.videoTokens[id] = nil; self.manager.cancelImageRequest(request)
            self.failVideo(id)
        }
    }
    private func failVideo(_ id: String) {
        progress[id] = nil
        if backgroundVideoID == id { backgroundVideoID = nil }
        messages[id] = "Couldn’t load this video. Tap Retry."
        onUpdate?(id); notifyPreparation(); pumpVideos()
    }
    private func storePreview(_ image: UIImage, for id: String) {
        if let current = previews.object(forKey: id as NSString), Self.pixelCount(current) > Self.pixelCount(image) { return }
        previews.setObject(image, forKey: id as NSString, cost: Self.cost(image))
    }
    private func storeFullImage(_ image: UIImage, for id: String) {
        MediaNavigationTrace.event("full-image index=\(diagnosticIndex(id)) object=\(ObjectIdentifier(image))")
        if memories[safe: activeIndex]?.id == id { selectedPhoto = (id, image) }
        if nearbyPhotos.contains(id) { fullImages.setObject(image, forKey: id as NSString, cost: Self.cost(image)) }
    }
    static func pixelCount(_ image: UIImage) -> CGFloat {
        image.size.width * image.size.height * image.scale * image.scale
    }
    private static func cost(_ image: UIImage) -> Int {
        image.cgImage.map { $0.bytesPerRow * $0.height } ?? Int(image.size.width * image.size.height * image.scale * image.scale * 8)
    }
}

@Observable @MainActor
final class MediaPreparationState {
    var snapshot = MediaPreparationSnapshot()
    var notice = PreparationNoticeDismissal()
    func dismissReady() { notice.dismiss(snapshot) }
    var retry: (() -> Void)?
}

struct MemoryPager: UIViewControllerRepresentable {
    let memories: [Memory]
    let selectedID: String
    let revision: Int
    let controlsVisible: Bool
    let active: Bool
    let foreground: Bool
    let reduceMotion: Bool
    let videoControls: VideoControlState
    let preparation: MediaPreparationState
    let onSelect: (String) -> Void
    let onRevealControls: () -> Void
    let onToggleControls: () -> Void
    var onTapSelection: ((String) -> Void)? = nil
    var scrubbing: Bool = false
    func makeUIViewController(context: Context) -> MemoryPagerController { MemoryPagerController() }
    func updateUIViewController(_ controller: MemoryPagerController, context: Context) {
        controller.videoControls = videoControls
        controller.preparation = preparation
        preparation.retry = { [weak controller] in controller?.pipeline.retryPreparation() }
        controller.onSelect = onSelect
        controller.onRevealControls = onRevealControls
        controller.onToggleControls = onToggleControls
        controller.onTapSelection = onTapSelection
        controller.update(memories, selectedID: selectedID, revision: revision, controlsVisible: controlsVisible, active: active, foreground: foreground, reduceMotion: reduceMotion, scrubbing: scrubbing)
    }
    static func dismantleUIViewController(_ controller: MemoryPagerController, coordinator: ()) { controller.pipeline.shutdown() }
}

/// A single fixed row: each asset owns exactly one viewport, including fractional Duo widths.
/// Flow layout can reposition items while cells are prepared; paging does not need that machinery.
@MainActor
final class MemoryPageLayout: UICollectionViewLayout {
    override var collectionViewContentSize: CGSize {
        guard let collectionView else { return .zero }
        return CGSize(width: collectionView.bounds.width * CGFloat(collectionView.numberOfItems(inSection: 0)), height: collectionView.bounds.height)
    }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let collectionView else { return nil }
        let attribute = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attribute.frame = CGRect(x: CGFloat(indexPath.item) * collectionView.bounds.width, y: 0,
                                 width: collectionView.bounds.width, height: collectionView.bounds.height)
        return attribute
    }
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let collectionView, collectionView.bounds.width > 0 else { return [] }
        let count = collectionView.numberOfItems(inSection: 0)
        guard count > 0 else { return [] }
        let first = max(0, min(count - 1, Int(floor(rect.minX / collectionView.bounds.width))))
        let last = max(first, min(count - 1, Int(floor(rect.maxX / collectionView.bounds.width))))
        return (first...last).compactMap { layoutAttributesForItem(at: IndexPath(item: $0, section: 0)) }
    }
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        collectionView?.bounds.size != newBounds.size
    }
}

@MainActor
final class MemoryPagerController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching, UIGestureRecognizerDelegate {
    let pipeline = DayMediaPipeline()
    private let flow = MemoryPageLayout()
    private lazy var pages = UICollectionView(frame: .zero, collectionViewLayout: flow)
    private var memories: [Memory] = []
    private var selectedIndex = 0
    private var lastExternalSelection: String?
    private var pendingSelections: [String] = []
    private var lastSize = CGSize.zero
    private var resizing = false
    private var userPaging = false
    private var timelineScrubbing = false
    private var viewports: [String: MediaViewport] = [:]
    private var revision = -1
    private var controlsVisible = true
    private var active = true
    private var reduceMotion = false
    private var memoryObserver: NSObjectProtocol?
    private var lastSelectionFade = 0.0
    weak var videoControls: VideoControlState?
    weak var preparation: MediaPreparationState?
    var onSelect: ((String) -> Void)?
    var onRevealControls: (() -> Void)?
    var onToggleControls: (() -> Void)?
    var onTapSelection: ((String) -> Void)?
    private let tapFeedback = UISelectionFeedbackGenerator()
    private lazy var navigationTap = UITapGestureRecognizer(target: self, action: #selector(handleNavigationTap(_:)))

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        tapFeedback.prepare()
        pages.isPagingEnabled = true; pages.showsHorizontalScrollIndicator = false
        pages.contentInsetAdjustmentBehavior = .never; pages.backgroundColor = .black
        pages.dataSource = self; pages.delegate = self; pages.prefetchDataSource = self
        pages.register(MediaPageCell.self, forCellWithReuseIdentifier: "media")
        pages.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pages)
        navigationTap.delegate = self
        navigationTap.cancelsTouchesInView = false
        navigationTap.numberOfTouchesRequired = 1
        view.addGestureRecognizer(navigationTap)
        NSLayoutConstraint.activate([
            pages.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pages.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pages.topAnchor.constraint(equalTo: view.topAnchor),
            pages.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        pipeline.onUpdate = { [weak self] id in
            guard let self else { return }
            for case let cell as MediaPageCell in self.pages.visibleCells where cell.memory?.id == id { cell.refresh() }
            if self.memories[safe: self.selectedIndex]?.id == id { self.bindVideoControls() }
        }
        pipeline.onPreparation = { [weak self] snapshot in self?.preparation?.snapshot = snapshot }
        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pipeline.memoryWarning() }
        }
    }
    deinit { if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) } }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.size != .zero, lastSize != view.bounds.size else { return }
        resizing = true
        for case let cell as MediaPageCell in pages.visibleCells {
            if let id = cell.memory?.id { viewports[id] = cell.viewport }
        }
        lastSize = view.bounds.size
        UIView.performWithoutAnimation {
            flow.invalidateLayout()
            pages.layoutIfNeeded()
            if memories.indices.contains(selectedIndex) {
                pages.setContentOffset(CGPoint(x: CGFloat(selectedIndex) * pages.bounds.width, y: 0), animated: false)
            }
            for case let cell as MediaPageCell in pages.visibleCells {
                cell.layoutIfNeeded()
                if let id = cell.memory?.id, let viewport = viewports[id] { cell.restore(viewport) }
            }
        }
        resizing = false
        if let memory = memories[safe: selectedIndex], !memory.isVideo {
            pipeline.prioritize(selectedIndex, force: true)
        }
        refreshVisible()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        view.layoutIfNeeded()
        pipeline.prioritize(selectedIndex)
        refreshVisible()
    }
    func update(_ values: [Memory], selectedID: String, revision: Int, controlsVisible: Bool, active: Bool, foreground: Bool, reduceMotion: Bool, scrubbing: Bool = false) {
        loadViewIfNeeded()
        timelineScrubbing = scrubbing
        let scrubChanged = pipeline.setScrubbing(scrubbing)
        self.controlsVisible = controlsVisible; self.active = active; self.reduceMotion = reduceMotion
        let changed = values != memories || revision != self.revision
        let incomingTarget = values.firstIndex { $0.id == selectedID } ?? 0
        // UIKit navigation is immediate; SwiftUI may acknowledge an older tap on its next update.
        // Chrome/loading updates with the same external selection must not rewind the pager.
        let ownedID = memories[safe: selectedIndex]?.id
        var acceptsSelection = lastExternalSelection == nil || lastExternalSelection != selectedID
        if let acknowledged = pendingSelections.lastIndex(of: selectedID) {
            pendingSelections.removeFirst(acknowledged + 1)
            acceptsSelection = pendingSelections.isEmpty
        } else if acceptsSelection { pendingSelections.removeAll() }
        lastExternalSelection = selectedID
        let retainedTarget = ownedID.flatMap { id in values.firstIndex { $0.id == id } }
        let target = acceptsSelection ? incomingTarget : (retainedTarget ?? incomingTarget)
        if changed || incomingTarget != selectedIndex {
            MediaNavigationTrace.event("update owned=\(selectedIndex) incoming=\(incomingTarget) target=\(target) changed=\(changed) count=\(values.count) pending=\(pendingSelections.count)")
        }
        if changed {
            let valid = Set(values.map(\.id))
            viewports = viewports.filter { valid.contains($0.key) }
            memories = values; self.revision = revision; selectedIndex = target
            pipeline.configure(values, revision: revision)
            pages.reloadData(); pages.layoutIfNeeded()
        }
        pipeline.suspend(!foreground)
        if changed || reduceMotion || !foreground { pages.layer.removeAnimation(forKey: "wheelSelection") }
        if changed || (target != selectedIndex && !pages.isDragging && !pages.isDecelerating) {
            selectedIndex = target
            if values.indices.contains(target) {
                pages.isScrollEnabled = true
                let now = CACurrentMediaTime()
                if !changed && !reduceMotion && foreground && now - lastSelectionFade >= 0.12 {
                    // One replaceable short dissolve; never animate through every
                    // intervening page or queue a transition for each skipped photo.
                    let fade = CATransition()
                    fade.type = .fade
                    fade.duration = 0.12
                    fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    pages.layer.add(fade, forKey: "wheelSelection")
                    lastSelectionFade = now
                }
                pages.setContentOffset(CGPoint(x: CGFloat(target) * pages.bounds.width, y: 0), animated: false)
            }
        }
        pipeline.prioritize(selectedIndex, force: scrubChanged)
        refreshVisible()
    }
    private func bindVideoControls() {
        let memory = memories[safe: selectedIndex]
        videoControls?.bind(memory: memory, pipeline: pipeline)
    }
    private func refreshVisible() {
        let visible = pages.visibleCells.compactMap { ($0 as? MediaPageCell)?.memory?.id }.map { pipeline.diagnosticIndex($0) }
        MediaNavigationTrace.event("visible selected=\(selectedIndex) cells=\(visible) offset=\(pages.contentOffset.x) width=\(pages.bounds.width)")
        bindVideoControls()
        for case let cell as MediaPageCell in pages.visibleCells {
            cell.setActive(active && !userPaging && !timelineScrubbing && cell.memory?.id == memories[safe: selectedIndex]?.id, controlsVisible: controlsVisible)
        }
    }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { memories.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "media", for: indexPath) as! MediaPageCell
        cell.configure(memories[indexPath.item], pipeline: pipeline)
        if let viewport = viewports[memories[indexPath.item].id] { cell.restore(viewport) }
        cell.onAdvance = { [weak self, weak cell] in self?.navigateFrom(cell, by: 1) }
        cell.onPrevious = { [weak self, weak cell] in self?.navigateFrom(cell, by: -1) }
        cell.onReveal = { [weak self] in self?.onRevealControls?() }
        cell.onToggle = { [weak self] in self?.onToggleControls?() }
        cell.onZoom = { [weak self, weak cell] zoomed in
            guard let self, cell?.memory?.id == self.memories[safe: self.selectedIndex]?.id else { return }
            self.pages.isScrollEnabled = !zoomed
        }
        cell.setActive(active && !userPaging && !timelineScrubbing && indexPath.item == selectedIndex, controlsVisible: controlsVisible)
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let cell = cell as? MediaPageCell else { return }
        cell.setNeedsLayout(); cell.layoutIfNeeded()
        cell.setActive(active && !userPaging && !timelineScrubbing && indexPath.item == selectedIndex, controlsVisible: controlsVisible)
    }
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) { pipeline.prioritize(selectedIndex) }
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let cell = cell as? MediaPageCell else { return }
        if let id = cell.memory?.id { viewports[id] = cell.viewport }
        // A resize can deliver an old end-display callback after the same cell is visible again.
        if pages.visibleCells.contains(where: { $0 === cell }) {
            refreshVisible()
        } else if !resizing {
            cell.setActive(false, controlsVisible: false)
        }
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        userPaging = true
        onRevealControls?()
        pages.layer.removeAnimation(forKey: "wheelSelection")
        for case let cell as MediaPageCell in pages.visibleCells { cell.pauseForScroll() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { settle() } }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { refreshVisible() }
    private func settle() {
        guard userPaging, !resizing, pages.bounds.width > 0, !memories.isEmpty else { return }
        userPaging = false
        selectedIndex = min(max(Int((pages.contentOffset.x / pages.bounds.width).rounded()), 0), memories.count - 1)
        pipeline.prioritize(selectedIndex); refreshVisible()
        publishSelection()
    }
    private func publishSelection() {
        let id = memories[selectedIndex].id
        if pendingSelections.last != id { pendingSelections.append(id) }
        if pendingSelections.count > 64 { pendingSelections.removeFirst(pendingSelections.count - 64) }
        onSelect?(id)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // The SwiftUI reveal gesture must not win exclusively over media navigation.
        gestureRecognizer === navigationTap || otherGestureRecognizer === navigationTap
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var target = touch.view
        while let candidate = target, candidate !== view {
            if candidate is UIControl { return false }
            target = candidate.superview
        }
        return active
    }
    @objc private func handleNavigationTap(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended, active, pages.bounds.width > 0, !memories.isEmpty else { return }
        let location = tap.location(in: view)
        guard view.bounds.contains(location) else { return }
        // Tap navigation owns its logical index. Scroll offsets can lag during layout.
        // Only a completed user swipe may derive a selection from the content offset.
        userPaging = false
        onRevealControls?()
        navigate(by: location.x < view.bounds.width * 0.4 ? -1 : 1, directTap: true)
    }
    private func navigateFrom(_ cell: MediaPageCell?, by offset: Int) {
        guard active, let cell, cell.memory?.id == memories[safe: selectedIndex]?.id else { return }
        navigate(by: offset, directTap: true)
    }
    private func navigate(by offset: Int, directTap: Bool = false) {
        userPaging = false
        let next = selectedIndex + offset
        guard memories.indices.contains(next) else { onRevealControls?(); return }
        if directTap {
            // Acknowledge the recognized tap before layout, decoding or SwiftUI selection updates.
            tapFeedback.selectionChanged()
            tapFeedback.prepare()
            onTapSelection?(memories[next].id)
        }
        pages.isScrollEnabled = true
        for case let cell as MediaPageCell in pages.visibleCells { cell.resetZoom(); cell.pauseForScroll() }
        MediaNavigationTrace.event("navigate from=\(selectedIndex) to=\(next) count=\(memories.count) offset=\(pages.contentOffset.x) width=\(pages.bounds.width)")
        selectedIndex = next
        pages.setContentOffset(CGPoint(x: CGFloat(selectedIndex) * pages.bounds.width, y: 0), animated: false)
        pages.layoutIfNeeded()
        pipeline.prioritize(selectedIndex)
        publishSelection()
        refreshVisible()
    }
}

/// Photos and videos initially fill the pane; pinching out reveals their original ratio.
@MainActor
final class MediaZoomScroll: UIScrollView {
    weak var surface: ZoomableMedia.ZoomSurface?
    private var mediaSize = CGSize(width: 1, height: 1)
    private var laidOutSize = CGSize.zero
    private var needsMediaLayout = true
    private(set) var isApplyingLayout = false
    var userHasZoomed = false
    private var fillScale: CGFloat = 1

    func setMediaSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let oldRatio = mediaSize.width / mediaSize.height
        let newRatio = size.width / size.height
        guard abs(oldRatio - newRatio) / max(oldRatio, newRatio) > 0.01 else { return }
        mediaSize = size
        needsMediaLayout = true
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, let surface else { return }
        guard needsMediaLayout || laidOutSize != bounds.size else { return }
        needsMediaLayout = false
        let previous = MediaViewport.capture(scale: zoomScale, content: contentSize,
                                             viewport: laidOutSize, offset: contentOffset)
        let preserve = userHasZoomed && laidOutSize != .zero
        laidOutSize = bounds.size
        isApplyingLayout = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
        let ratio = min(bounds.width / mediaSize.width, bounds.height / mediaSize.height)
        let fit = CGSize(width: mediaSize.width * ratio, height: mediaSize.height * ratio)
        minimumZoomScale = 1
        fillScale = max(bounds.width / fit.width, bounds.height / fit.height)
        maximumZoomScale = max(6, fillScale * 3)
        setZoomScale(1, animated: false)
        surface.frame = CGRect(origin: .zero, size: fit)
        contentSize = fit
        surface.setNeedsLayout(); surface.layoutIfNeeded()
        setZoomScale(fillScale, animated: false)
        centerContent()
        contentOffset = CGPoint(x: (contentSize.width - bounds.width) / 2, y: (contentSize.height - bounds.height) / 2)
        userHasZoomed = preserve
        if preserve {
            setZoomScale(min(previous.scale, maximumZoomScale), animated: false)
            centerContent()
            contentOffset = previous.offset(content: contentSize, viewport: bounds.size)
        }
        panGestureRecognizer.isEnabled = userHasZoomed && zoomScale > 1.01
        }
        CATransaction.commit()
        isApplyingLayout = false
    }
    var viewport: MediaViewport {
        MediaViewport.capture(scale: zoomScale, content: contentSize, viewport: bounds.size, offset: contentOffset, userAdjusted: userHasZoomed)
    }
    func restore(_ viewport: MediaViewport) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        layoutIfNeeded()
        guard viewport.userAdjusted else { resetToInitial(); return }
        isApplyingLayout = true
        setZoomScale(min(viewport.scale, maximumZoomScale), animated: false)
        userHasZoomed = true
        centerContent()
        contentOffset = viewport.offset(content: contentSize, viewport: bounds.size)
        panGestureRecognizer.isEnabled = userHasZoomed && zoomScale > 1.01
        isApplyingLayout = false
    }
    func resetToInitial() {
        isApplyingLayout = true
        userHasZoomed = false
        setZoomScale(fillScale, animated: false)
        centerContent()
        contentOffset = CGPoint(x: (contentSize.width - bounds.width) / 2, y: (contentSize.height - bounds.height) / 2)
        panGestureRecognizer.isEnabled = false
        isApplyingLayout = false
    }
    func centerContent() {
        contentInset = UIEdgeInsets(top: max(0, (bounds.height - contentSize.height) / 2), left: max(0, (bounds.width - contentSize.width) / 2), bottom: max(0, (bounds.height - contentSize.height) / 2), right: max(0, (bounds.width - contentSize.width) / 2))
    }
}

@MainActor
final class MediaPageCell: UICollectionViewCell, UIScrollViewDelegate {
    private let zoom = MediaZoomScroll()
    private let surface = ZoomableMedia.ZoomSurface()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()
    private let retry = UIButton(type: .system)
    private var pipeline: DayMediaPipeline?
    private(set) var memory: Memory?
    private var isActive = false
    private var chromeVisible = false
    private weak var attachedPlayer: AVPlayer?
    private var readyObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var playbackGeneration = 0
    var onAdvance: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onReveal: (() -> Void)?
    var onToggle: (() -> Void)?
    var onZoom: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .black
        contentView.clipsToBounds = true
        surface.clipsToBounds = true
        surface.isOpaque = true
        surface.backgroundColor = .black
        surface.imageView.contentMode = .scaleAspectFit
        surface.videoLayer.videoGravity = .resizeAspect
        zoom.surface = surface; zoom.addSubview(surface); zoom.delegate = self
        zoom.minimumZoomScale = 1; zoom.maximumZoomScale = 6; zoom.bouncesZoom = true
        zoom.showsVerticalScrollIndicator = false; zoom.showsHorizontalScrollIndicator = false
        zoom.contentInsetAdjustmentBehavior = .never
        zoom.panGestureRecognizer.isEnabled = false
        contentView.addSubview(zoom)
        spinner.color = .white; contentView.addSubview(spinner)
        statusLabel.textColor = .white; statusLabel.numberOfLines = 0; statusLabel.textAlignment = .center
        statusLabel.font = .preferredFont(forTextStyle: .caption1); statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5); statusLabel.layer.cornerRadius = 10; statusLabel.clipsToBounds = true
        contentView.addSubview(statusLabel)
        retry.setTitle("Retry", for: .normal); retry.tintColor = .white
        retry.addTarget(self, action: #selector(retryLoad), for: .touchUpInside); contentView.addSubview(retry)
        zoom.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Next moment", target: self, selector: #selector(accessibleNext)),
            UIAccessibilityCustomAction(name: "Previous moment", target: self, selector: #selector(accessiblePrevious)),
            UIAccessibilityCustomAction(name: "Show controls", target: self, selector: #selector(accessibleControls)),
            UIAccessibilityCustomAction(name: "Reset zoom", target: self, selector: #selector(accessibleReset)),
            UIAccessibilityCustomAction(name: "Fit whole image", target: self, selector: #selector(accessibleFit))
        ]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    override func layoutSubviews() {
        super.layoutSubviews()
        zoom.frame = contentView.bounds
        zoom.layoutIfNeeded()
        if let pendingViewport, zoom.bounds.width > 0, zoom.bounds.height > 0 {
            zoom.restore(pendingViewport)
            self.pendingViewport = nil
            onZoom?(pendingViewport.userAdjusted && pendingViewport.scale > 1.01)
        }
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        statusLabel.frame = CGRect(x: 40, y: bounds.midY - 44, width: max(0, bounds.width - 80), height: 40)
        retry.frame = CGRect(x: (bounds.width - 100)/2, y: bounds.midY + 4, width: 100, height: 44)
    }
    override func prepareForReuse() {
        super.prepareForReuse(); detachPlayer(); isActive = false; memory = nil; pipeline = nil
        surface.imageView.image = nil; resetZoom()
    }
    func configure(_ memory: Memory, pipeline: DayMediaPipeline) {
        if self.memory?.id != memory.id { detachPlayer(); resetZoom(); surface.imageView.image = nil }
        self.memory = memory; self.pipeline = pipeline
        zoom.setMediaSize(pipeline.dimensions(for: memory))
        zoom.isAccessibilityElement = true
        zoom.accessibilityLabel = "\(memory.isVideo ? "Video" : "Photo"), \(memory.date.formatted(date: .abbreviated, time: .shortened))"
        zoom.accessibilityHint = "Tap the left side for the previous moment or the right side for the next. Swipe to browse. Pinch to zoom. Use actions for Next moment, Previous moment, or Show controls."
        refresh()
    }
    func setActive(_ active: Bool, controlsVisible: Bool) {
        if isActive && !active { attachedPlayer?.pause() }
        isActive = active; chromeVisible = controlsVisible
        refresh()
    }
    func refresh() {
        guard let memory, let pipeline else { return }
        if let image = pipeline.image(for: memory),
           surface.imageView.image.map({ DayMediaPipeline.pixelCount(image) >= DayMediaPipeline.pixelCount($0) }) ?? true {
            // Late previews/cache eviction may not replace a sharper frame already on screen.
            if surface.imageView.image !== image {
                MediaNavigationTrace.event("image cell=\(pipeline.diagnosticIndex(memory.id)) object=\(ObjectIdentifier(image)) pixels=\(Int(DayMediaPipeline.pixelCount(image)))")
            }
            UIView.performWithoutAnimation {
                surface.imageView.image = image
                surface.imageView.layer.removeAllAnimations()
                if !memory.isVideo { zoom.setMediaSize(image.size) }
                zoom.layoutIfNeeded()
            }
        }
        let player = pipeline.players[memory.id]
        if attachedPlayer !== player { attach(player) }
        if let player {
            if let size = player.currentItem?.presentationSize, size.width > 0, size.height > 0 { zoom.setMediaSize(size) }
            player.isMuted = pipeline.muted
            if isActive && pipeline.wantsPlayback(memory.id) {
                if player.rate == 0 && !pipeline.muted { MemoryVideoAudio.activate() }
                player.play()
            } else { player.pause() }
        }
        let videoReady = player != nil && surface.videoLayer.isReadyForDisplay
        surface.videoLayer.isHidden = !videoReady
        surface.imageView.isHidden = videoReady
        let error = pipeline.messages[memory.id]
        // Video loading belongs exclusively to the visible control card.
        let waiting = !memory.isVideo && memory.assetID != nil && surface.imageView.image == nil
        if waiting && error == nil { spinner.startAnimating() } else { spinner.stopAnimating() }
        spinner.accessibilityLabel = "Loading full-quality photo"
        statusLabel.isHidden = error == nil
        statusLabel.text = error
        retry.isHidden = error == nil
    }
    private func attach(_ player: AVPlayer?) {
        detachPlayer()
        attachedPlayer = player; surface.videoLayer.player = player
        guard let player else { return }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self, weak player] _ in
            Task { @MainActor in self?.loopIfCurrent(player) }
        }
        readyObserver = surface.videoLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    private func loopIfCurrent(_ player: AVPlayer?) {
        guard let player, player === attachedPlayer, isActive,
              let memory, pipeline?.wantsPlayback(memory.id) == true else { return }
        let generation = playbackGeneration
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] finished in
            Task { @MainActor in
                guard finished, let self, let player, self.playbackGeneration == generation,
                      player === self.attachedPlayer, self.isActive,
                      self.pipeline?.wantsPlayback(memory.id) == true else { return }
                player.play()
            }
        }
    }
    private func detachPlayer() {
        playbackGeneration += 1
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        readyObserver = nil; surface.videoLayer.player = nil; attachedPlayer = nil
    }
    func pauseForScroll() { isActive = false; attachedPlayer?.pause() }
    var viewport: MediaViewport { zoom.viewport }
    private var pendingViewport: MediaViewport?
    func restore(_ viewport: MediaViewport) {
        pendingViewport = viewport
        setNeedsLayout()
    }
    func resetZoom() { pendingViewport = nil; zoom.resetToInitial(); onZoom?(false) }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { surface }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        zoom.userHasZoomed = true
        onZoom?(true)
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView.isDragging { onReveal?() }
    }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        if scrollView.isZooming { onReveal?() }
        zoom.centerContent()
        guard !zoom.isApplyingLayout else { return }
        let zoomed = zoom.userHasZoomed && scrollView.zoomScale > 1.01
        zoom.panGestureRecognizer.isEnabled = zoomed
        onZoom?(zoomed)
    }
    @objc private func retryLoad() { if let memory { pipeline?.retry(memory.id) } }
    @objc private func accessibleNext() -> Bool { onAdvance?(); return true }
    @objc private func accessiblePrevious() -> Bool { onPrevious?(); return true }
    @objc private func accessibleControls() -> Bool { onReveal?(); return true }
    @objc private func accessibleReset() -> Bool { resetZoom(); return true }
    @objc private func accessibleFit() -> Bool {
        zoom.userHasZoomed = true
        zoom.setZoomScale(1, animated: false)
        zoom.centerContent()
        zoom.panGestureRecognizer.isEnabled = false
        onZoom?(false)
        return true
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}


struct MediaSharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

/// Export only after an explicit Share tap; remove the temporary copy after dismissal.
@MainActor
final class MediaShareStore: ObservableObject {
    @Published var payload: MediaSharePayload?
    @Published var isPreparing = false
    @Published var error: String?
    private var directory: URL?

    func prepare(_ memory: Memory) async {
        guard !isPreparing else { return }
        cleanUp()
        isPreparing = true
        defer { isPreparing = false }
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("memory-share-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            directory = folder
            let url: URL
            if let id = memory.assetID {
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
                    throw ShareFailure.unavailable
                }
                let resources = PHAssetResource.assetResources(for: asset)
                let preferred: PHAssetResourceType = memory.isVideo ? .fullSizeVideo : .fullSizePhoto
                let original: PHAssetResourceType = memory.isVideo ? .video : .photo
                guard let resource = resources.first(where: { $0.type == preferred }) ?? resources.first(where: { $0.type == original }) else {
                    throw ShareFailure.unavailable
                }
                let ext = UTType(resource.uniformTypeIdentifier)?.preferredFilenameExtension ?? (memory.isVideo ? "mov" : "heic")
                url = folder.appendingPathComponent("Memory.\(ext)")
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = true
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
            } else {
                let renderer = ImageRenderer(content: SampleLandscape(scene: memory.scene).frame(width: 430, height: 930))
                renderer.scale = 2
                guard let data = renderer.uiImage?.pngData() else { throw ShareFailure.unavailable }
                url = folder.appendingPathComponent("Sample-illustration.png")
                try data.write(to: url)
            }
            payload = MediaSharePayload(url: url)
        } catch {
            self.error = "This item couldn’t be prepared. Check your photo access and internet connection, then try again."
            cleanUp()
        }
    }
    func cleanUp() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
    private enum ShareFailure: Error { case unavailable }
}

struct MediaShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Bridges only the currently selected player into the contextual control card.
@MainActor
final class VideoControlState: ObservableObject {
    @Published private(set) var duration: Double = 0
    @Published private(set) var position: Double = 0
    @Published private(set) var playing = false
    @Published private(set) var muted = false
    @Published private(set) var ready = false
    @Published private(set) var buffering = false
    @Published private(set) var seeking = false
    @Published private(set) var isHDR = false
    private var id: String?
    private weak var pipeline: DayMediaPipeline?
    private weak var player: AVPlayer?
    private var observer: Any?
    private var statusObserver: NSKeyValueObservation?
    private var itemObserver: NSKeyValueObservation?
    private var generation = 0
    var ended: Bool { duration > 0 && position >= duration - 0.1 }

    func bind(memory: Memory?, pipeline: DayMediaPipeline) {
        let id = memory?.id
        let next = id.flatMap { pipeline.players[$0] }
        let photoHDR = id.flatMap { pipeline.fullImages.object(forKey: $0 as NSString) ?? pipeline.previews.object(forKey: $0 as NSString) }?.isHighDynamicRange ?? false
        guard self.id != id || player !== next else {
            if next == nil && isHDR != photoHDR {
                let token = generation
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.isHDR = photoHDR
                }
            }
            return
        }
        let oldID = self.id
        let oldPipeline = self.pipeline
        if let observer, let player { player.removeTimeObserver(observer) }
        observer = nil; statusObserver = nil; itemObserver = nil
        self.id = id; self.pipeline = pipeline; self.player = next
        generation += 1
        let token = generation
        // Binding can happen during a SwiftUI representable update.
        Task { @MainActor [weak self, weak next] in
            guard let self, token == self.generation else { return }
            if let oldID { oldPipeline?.endSeeking(oldID) }
            self.seeking = false
            self.position = 0
            self.isHDR = photoHDR
            self.refresh()
            guard let next else { return }
            self.observer = next.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, token == self.generation else { return }
                    self.refresh()
                }
            }
            self.statusObserver = next.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in
                    guard let self, token == self.generation else { return }; self.refresh()
                }
            }
            if let asset = next.currentItem?.asset {
                Task { @MainActor [weak self] in
                    let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
                    var hdr = false
                    for track in tracks {
                        if let characteristics = try? await track.load(.mediaCharacteristics), characteristics.contains(.containsHDRVideo) { hdr = true; break }
                    }
                    guard let self, self.generation == token else { return }
                    self.isHDR = hdr
                }
            }
            self.itemObserver = next.currentItem?.observe(\.status, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in
                    guard let self, token == self.generation else { return }; self.refresh()
                }
            }
        }
    }
    private func refresh() {
        // @Published emits on every assignment; the 5 Hz time observer should only
        // invalidate the control card for values that actually changed.
        let length = player?.currentItem?.duration.seconds ?? 0
        let nextDuration = length.isFinite && length > 0 ? length : 0
        if duration != nextDuration { duration = nextDuration }
        let nextReady = player?.currentItem?.status == .readyToPlay && duration > 0
        if ready != nextReady { ready = nextReady }
        if !seeking {
            let time = player?.currentTime().seconds ?? 0
            let nextPosition = time.isFinite ? min(max(time, 0), duration) : 0
            if position != nextPosition { position = nextPosition }
        }
        let nextPlaying = player?.timeControlStatus == .playing
        if playing != nextPlaying { playing = nextPlaying }
        let nextBuffering = player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if buffering != nextBuffering { buffering = nextBuffering }
        let nextMuted = pipeline?.muted ?? false
        if muted != nextMuted { muted = nextMuted }
    }
    func togglePlayback() {
        guard ready, let id, let pipeline else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        if ended { pipeline.restartPlayback(id) } else { pipeline.togglePlayback(id) }
        refresh()
    }
    func toggleSound() {
        guard ready else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        pipeline?.toggleSound(); refresh()
    }
    func beginSeek() {
        guard ready, !seeking, let id else { return }
        seeking = true
        pipeline?.beginSeeking(id)
        UISelectionFeedbackGenerator().selectionChanged()
    }
    func seek(to value: Double) {
        guard ready else { return }
        if !seeking { beginSeek() }
        position = min(max(value, 0), duration)
        player?.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600), toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600))
    }
    func endSeek() {
        guard seeking, let id, let player else { return }
        let token = generation
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.seeking = false
                self.pipeline?.endSeeking(id)
                self.refresh()
            }
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

struct VideoControlCard: View {
    @ObservedObject var state: VideoControlState
    let isVisible: Bool
    let onInteraction: (Bool) -> Void
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        HStack(spacing: LightYearsStyle.smallGap) {
            Button { state.togglePlayback(); onInteraction(false) } label: {
                Image(systemName: state.ended ? "arrow.counterclockwise" : state.playing || state.buffering ? "pause.fill" : "play.fill")
                    .font(.title3.weight(.semibold))
                    .frame(width: LightYearsStyle.touchTarget, height: LightYearsStyle.touchTarget)
            }
            .disabled(!state.ready)
            .accessibilityLabel(state.ended ? "Replay video" : state.playing || state.buffering ? "Pause video" : "Play video")

            VStack(spacing: 0) {
                CompactVideoSlider(state: state, onInteraction: onInteraction)
                    .frame(height: LightYearsStyle.touchTarget)
                if !state.ready || state.buffering {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini).accessibilityHidden(true)
                        Text(state.ready ? "Buffering" : "Loading video")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Text(time(state.position))
                            Spacer(minLength: 8)
                            Text("−" + time(max(0, state.duration - state.position)))
                                .foregroundStyle(.secondary)
                        }
                        Text(time(state.position))
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(time(state.position)) elapsed, \(time(state.duration)) total")
                }
            }
            .font(.caption.monospacedDigit())
            .frame(maxWidth: .infinity)

            Button { state.toggleSound(); onInteraction(false) } label: {
                Image(systemName: state.muted ? "speaker.slash" : "speaker.wave.2")
                    .font(.title3.weight(.medium))
                    .frame(width: LightYearsStyle.touchTarget, height: LightYearsStyle.touchTarget)
            }
            .disabled(!state.ready)
            .accessibilityLabel(state.muted ? "Unmute video" : "Mute video")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, textSize.isAccessibilitySize ? 8 : 12)
        .padding(.vertical, LightYearsStyle.smallGap)
        .cameraGlass(LightYearsStyle.cardRadius)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video controls")
        .accessibilityHidden(!isVisible)
        .allowsHitTesting(isVisible)
        .onDisappear {
            state.endSeek()
            onInteraction(false)
        }
    }
    private func time(_ value: Double) -> String {
        let seconds = Int(value.isFinite ? max(value, 0) : 0)
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Slim visual track with the full native slider hit area and accessibility behavior.
private struct CompactVideoSlider: UIViewRepresentable {
    @ObservedObject var state: VideoControlState
    let onInteraction: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(state: state, onInteraction: onInteraction) }
    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider()
        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.35)
        let thumb = UIGraphicsImageRenderer(size: CGSize(width: 22, height: 22)).image { context in
            context.cgContext.setFillColor(UIColor.white.cgColor)
            context.cgContext.fillEllipse(in: CGRect(x: 1, y: 1, width: 20, height: 20))
        }
        slider.setThumbImage(thumb, for: .normal)
        slider.setThumbImage(thumb, for: .highlighted)
        slider.accessibilityLabel = "Video position"
        slider.addTarget(context.coordinator, action: #selector(Coordinator.begin), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.end), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }
    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.onInteraction = onInteraction
        slider.isEnabled = state.ready
        slider.minimumValue = 0
        slider.maximumValue = Float(max(1, state.duration))
        if !slider.isTracking { slider.value = Float(state.position) }
        slider.accessibilityValue = "\(Int(state.position)) seconds of \(Int(state.duration)) seconds"
    }
    @MainActor final class Coordinator: NSObject {
        let state: VideoControlState
        var onInteraction: (Bool) -> Void
        init(state: VideoControlState, onInteraction: @escaping (Bool) -> Void) { self.state = state; self.onInteraction = onInteraction }
        @objc func begin() { state.beginSeek(); onInteraction(true) }
        @objc func changed(_ sender: UISlider) {
            state.seek(to: Double(sender.value))
            if !sender.isTracking { state.endSeek(); onInteraction(false) }
        }
        @objc func end() { state.endSeek(); onInteraction(false) }
    }
}

struct HDRBadge: View {
    @ObservedObject var state: VideoControlState
    var body: some View {
        if state.isHDR {
            Text("HDR").font(.caption2.weight(.semibold))
                .padding(.horizontal, LightYearsStyle.smallGap).padding(.vertical, 4)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("High dynamic range media")
        }
    }
}

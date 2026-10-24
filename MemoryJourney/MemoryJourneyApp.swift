import SwiftUI

@main
struct MemoryJourneyApp: App {
    var body: some Scene {
        WindowGroup { TodayView() }
    }
}

import Photos
import PhotosUI
import AVKit
import UIKit

@MainActor
final class PhotoLibraryStore: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published var collection = MemoryCollection(memories: [])
    @Published var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var revision = 0
    @Published var isLoading = false
    @Published var usingLibrary = UserDefaults.standard.bool(forKey: "useLocalLibrary")
    private var date = Date()
    private var lastRequestDay: LocalDayKey?
    private var hasLoaded = false
    private var generation = 0
    private var observing = false
    var allowed: Bool { status == .authorized || status == .limited }

    func connect(on date: Date) async {
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        usingLibrary = true
        UserDefaults.standard.set(true, forKey: "useLocalLibrary")
        refresh(on: date)
    }
    func mostRecentDate() -> Date? {
        guard allowed else { return nil }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var date: Date?
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, stop in
            guard !asset.mediaSubtypes.contains(.photoScreenshot), let captured = asset.creationDate else { return }
            date = captured
            stop.pointee = true
        }
        return date
    }
    func samples() {
        generation += 1
        hasLoaded = false
        lastRequestDay = nil
        usingLibrary = false
        isLoading = false
        collection = MemoryCollection(memories: [])
        UserDefaults.standard.set(false, forKey: "useLocalLibrary")
    }
    func refreshIfNeeded(on date: Date) {
        let key = LocalDayKey(date, calendar: .current)
        guard lastRequestDay != key || (!hasLoaded && !isLoading) || status != PHPhotoLibrary.authorizationStatus(for: .readWrite) else { return }
        refresh(on: date)
    }
    func refresh(on date: Date) {
        let nextStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let calendar = Calendar.current
        let day = LocalDayKey(date, calendar: calendar)
        let changed = (lastRequestDay.map { !$0.sameCivilDay(as: day) } ?? false) || status != nextStatus
        lastRequestDay = day
        self.date = date
        status = nextStatus
        generation += 1
        let request = generation
        guard usingLibrary, allowed else {
            if !allowed { Task { await MediaDiskCache.shared.removeAll() } }
            collection = MemoryCollection(memories: [])
            isLoading = false
            hasLoaded = true
            return
        }
        if !observing { PHPhotoLibrary.shared().register(self); observing = true }
        isLoading = true
        if changed { collection = MemoryCollection(memories: []) }
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Self.fetchMemories(on: date, calendar: calendar)
            }.value
            guard request == generation else { return }
            if collection.memories != result.memories {
                collection = result
            }
            hasLoaded = true
            isLoading = false
        }
    }
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refresh(on: self.date)
        }
    }
    nonisolated private static func fetchMemories(on date: Date, calendar: Calendar) -> MemoryCollection {
        let oldestOptions = PHFetchOptions()
        oldestOptions.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        oldestOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        oldestOptions.fetchLimit = 1
        guard let oldest = PHAsset.fetchAssets(with: oldestOptions).firstObject?.creationDate else {
            return MemoryCollection(memories: [])
        }
        let currentYear = calendar.component(.year, from: date)
        let firstYear = calendar.component(.year, from: oldest)
        guard firstYear <= currentYear else { return MemoryCollection(memories: []) }
        let day = calendar.dateComponents([.month, .day], from: date)
        var windows: [NSPredicate] = []
        for year in firstYear...currentYear {
            guard let center = calendar.date(from: DateComponents(year: year, month: day.month, day: day.day)),
                  calendar.component(.month, from: center) == day.month,
                  calendar.component(.day, from: center) == day.day,
                  let start = calendar.date(byAdding: .day, value: -3, to: center),
                  let end = calendar.date(byAdding: .day, value: 4, to: center) else { continue }
            windows.append(NSPredicate(format: "creationDate >= %@ AND creationDate < %@", start as NSDate, end as NSDate))
        }
        let options = PHFetchOptions()
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            oldestOptions.predicate!, NSCompoundPredicate(orPredicateWithSubpredicates: windows)
        ])
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: options)
        var result: [Memory] = []
        assets.enumerateObjects { asset, _, _ in
            guard let date = asset.creationDate else { return }
            let video = asset.mediaType == .video
            result.append(Memory(id: asset.localIdentifier, date: date,
                                 title: date.formatted(.dateTime.hour().minute()),
                                 connection: "Nearby in time", scene: 0,
                                 assetID: asset.localIdentifier, isVideo: video, modificationDate: asset.modificationDate, isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot)))
        }
        return MemoryCollection(memories: result)
    }
}

@MainActor
final class LocalMediaLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var player: AVPlayer?
    @Published var message: String?
    @Published var loading = false
    private var requestID: PHImageRequestID?
    private var token = UUID()
    private let manager = PHImageManager.default()

    func load(_ memory: Memory, full: Bool) {
        cancel()
        guard let id = memory.assetID else { return }
        let current = UUID()
        token = current
        image = nil
        message = nil
        loading = true
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            loading = false
            message = "This item is no longer accessible. Check your selected photos in Library settings."
            return
        }
        if memory.isVideo && full {
            let options = PHVideoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            requestID = manager.requestPlayerItem(forVideo: asset, options: options) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, self.token == current else { return }
                    self.loading = false
                    if let item { self.player = AVPlayer(playerItem: item) }
                    else { self.message = "Couldn’t load video from Photos or iCloud. Check your connection and try again." }
                }
            }
        } else {
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact
            options.isNetworkAccessAllowed = true
            options.preferHDR = true
            // Keep decoding bounded; preserve the system's HDR representation.
            let maxSide: CGFloat = full ? 4096 : 640
            let ratio = min(1, maxSide / CGFloat(max(asset.pixelWidth, asset.pixelHeight, 1)))
            let size = CGSize(width: CGFloat(asset.pixelWidth) * ratio, height: CGFloat(asset.pixelHeight) * ratio)
            requestID = manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { [weak self] image, info in
                Task { @MainActor in
                    guard let self, self.token == current else { return }
                    if let image { self.image = image }
                    let degraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
                    if !degraded {
                        self.loading = false
                        if image == nil { self.message = "Couldn’t load this item from Photos or iCloud. Check your connection and try again." }
                    }
                }
            }
        }
    }
    func cancel() {
        token = UUID()
        if let requestID { manager.cancelImageRequest(requestID) }
        requestID = nil
        player?.pause()
        player = nil
    }
}

struct HDRImage: UIViewRepresentable {
    let image: UIImage
    var fill = true
    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.clipsToBounds = true
        view.preferredImageDynamicRange = .high
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }
    func updateUIView(_ view: UIImageView, context: Context) {
        view.image = image
        view.contentMode = fill ? .scaleAspectFill : .scaleAspectFit
    }
}

struct MemoryArtwork: View {
    let memory: Memory
    @StateObject private var loader = LocalMediaLoader()
    var body: some View {
        Group {
            if memory.assetID == nil { SampleLandscape(scene: memory.scene) }
            else {
                ZStack {
                    Color.black
                    if let image = loader.image { HDRImage(image: image) }
                    else if loader.loading { ProgressView().tint(.white) }
                    else {
                        VStack(spacing: 8) {
                            Image(systemName: "icloud").font(.title)
                            Text(loader.message ?? "Photo unavailable").font(.caption).multilineTextAlignment(.center)
                        }.foregroundStyle(.white).padding()
                    }
                    if memory.isVideo {
                        Image(systemName: "play.circle.fill").font(.system(size: 44)).foregroundStyle(.white)
                            .shadow(radius: 4).accessibilityHidden(true)
                    }
                }
                .task(id: memory.id) { loader.load(memory, full: false) }
                .onDisappear { loader.cancel() }
            }
        }.clipped()
    }
}

/// Native pinch, pan and double-tap zoom, shared by still images and AVPlayer video.
struct ZoomableMedia: UIViewRepresentable {
    let image: UIImage?
    let player: AVPlayer?
    let resetID: Int
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIScrollView {
        let view = ZoomScroll()
        view.delegate = context.coordinator
        view.minimumZoomScale = 1
        view.maximumZoomScale = 6
        view.bouncesZoom = true
        view.showsHorizontalScrollIndicator = false
        view.showsVerticalScrollIndicator = false
        view.backgroundColor = .black
        view.contentInsetAdjustmentBehavior = .never
        let content = ZoomSurface()
        view.addSubview(content)
        view.surface = content
        context.coordinator.surface = content
        context.coordinator.scroll = view
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        view.addGestureRecognizer(tap)
        return view
    }
    func updateUIView(_ view: UIScrollView, context: Context) {
        guard let surface = context.coordinator.surface else { return }
        surface.imageView.image = image
        surface.videoLayer.player = player
        surface.imageView.isHidden = player != nil
        if context.coordinator.lastReset != resetID {
            view.setZoomScale(1, animated: false)
            context.coordinator.lastReset = resetID
        }
        view.setNeedsLayout()
    }
    final class ZoomScroll: UIScrollView {
        weak var surface: ZoomSurface?
        private var laidOutSize = CGSize.zero
        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.size != .zero, bounds.size != laidOutSize, let surface else { return }
            laidOutSize = bounds.size
            setZoomScale(1, animated: false)
            surface.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
            surface.setNeedsLayout()
        }
    }
    static func dismantleUIView(_ uiView: UIScrollView, coordinator: Coordinator) {
        coordinator.surface?.videoLayer.player = nil
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var surface: ZoomSurface?
        weak var scroll: UIScrollView?
        var baseSize = CGSize.zero
        var lastReset = 0
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { surface }
        @objc func doubleTap(_ tap: UITapGestureRecognizer) {
            guard let scroll, let surface else { return }
            if scroll.zoomScale > 1.01 { scroll.setZoomScale(1, animated: !UIAccessibility.isReduceMotionEnabled) }
            else {
                let point = tap.location(in: surface)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: point.x - size.width/2, y: point.y - size.height/2, width: size.width, height: size.height), animated: !UIAccessibility.isReduceMotionEnabled)
            }
        }
    }
    final class ZoomSurface: UIView {
        let imageView = UIImageView()
        let videoLayer = AVPlayerLayer()
        override init(frame: CGRect) {
            super.init(frame: frame)
            imageView.contentMode = .scaleAspectFit
            imageView.preferredImageDynamicRange = .high
            addSubview(imageView)
            videoLayer.videoGravity = .resizeAspect
            layer.addSublayer(videoLayer)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
        override func layoutSubviews() {
            super.layoutSubviews()
            imageView.frame = bounds
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            videoLayer.frame = bounds
            CATransaction.commit()
        }
    }
}

struct MediaDetailView: View {
    let memory: Memory
    @Environment(\.dismiss) private var dismiss
    @StateObject private var loader = LocalMediaLoader()
    @State private var resetID = 0
    @State private var playing = false
    @State private var progress = 0.0
    @State private var duration = 0.0
    @State private var seeking = false
    @State private var observer: Any?
    @State private var observedPlayer: AVPlayer?
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if memory.assetID == nil { SampleLandscape(scene: memory.scene) }
                    else if loader.image != nil || loader.player != nil {
                        ZoomableMedia(image: loader.image, player: loader.player, resetID: resetID)
                            .accessibilityLabel(memory.isVideo ? "Video. Pinch to zoom and drag to pan." : "Photo. Pinch to zoom and drag to pan.")
                    } else if loader.loading { ProgressView("Loading from Photos…") }
                    else {
                        ContentUnavailableView("Not available on this device", systemImage: "icloud", description: Text(loader.message ?? "Try opening this item in Photos first."))
                    }
                }
                if let player = loader.player {
                    HStack {
                        Button(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill") {
                            if playing { player.pause() } else {
                                if progress >= duration - 0.25 { player.seek(to: .zero) }
                                MemoryVideoAudio.activate()
                                player.play()
                            }
                            playing.toggle()
                        }.labelStyle(.iconOnly).frame(width: 44, height: 44)
                        Slider(value: $progress, in: 0...max(duration, 1), onEditingChanged: { editing in
                            if editing { seeking = true; player.pause() }
                            else {
                                seeking = false
                                player.seek(to: CMTime(seconds: progress, preferredTimescale: 600))
                                if playing { player.play() }
                            }
                        }).accessibilityLabel("Video position")
                        Text(Duration.seconds(progress).formatted(.time(pattern: .minuteSecond))).font(.caption.monospacedDigit())
                    }.padding(.horizontal)
                }
                HStack {
                    Text(memory.date.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                    Spacer()
                    Button("Reset zoom") { resetID += 1 }
                }.padding()
                Text("Pinch to zoom · Double-tap to zoom or reset").font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
            }
            .background(.black)
            .navigationTitle(memory.isVideo ? "Video" : "Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { loader.load(memory, full: true) }
            .onReceive(loader.$player) { player in
                if let observer, let observedPlayer { observedPlayer.removeTimeObserver(observer) }
                observer = nil
                observedPlayer = player
                guard let player else { return }
                observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { time in
                    if !seeking { progress = max(0, time.seconds.isFinite ? time.seconds : 0) }
                    let seconds = player.currentItem?.duration.seconds ?? 0
                    duration = seconds.isFinite ? seconds : 0
                    if !seeking { playing = player.rate > 0 }
                }
            }
            .onDisappear {
                if let observer, let observedPlayer { observedPlayer.removeTimeObserver(observer) }
                observer = nil
                observedPlayer = nil
                loader.cancel()
            }
        }.preferredColorScheme(.dark)
    }
}

struct LimitedLibraryPicker: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> PickerHost { PickerHost() }
    func updateUIViewController(_ controller: PickerHost, context: Context) {}
    final class PickerHost: UIViewController {
        private var shown = false
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !shown else { return }
            shown = true
            PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: self)
        }
    }
}

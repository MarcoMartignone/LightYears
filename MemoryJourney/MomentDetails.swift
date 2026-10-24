import SwiftUI
import Photos
import ImageIO
import MapKit

enum LightYearsStyle {
    static let pageInset: CGFloat = 20
    static let cardInset: CGFloat = 16
    static let tileInset: CGFloat = 12
    static let gap: CGFloat = 12
    static let smallGap: CGFloat = 8
    static let touchTarget: CGFloat = 44
    static let cardRadius: CGFloat = 26
    static let valueFont = Font.body.weight(.medium)
    static let labelFont = Font.caption.weight(.medium)
}

struct CameraGlass: ViewModifier {
    let radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(iOS 26.0, *) {
            // Native glass adapts to Reduce Transparency, Increase Contrast and Reduce Motion.
            content.glassEffect(.regular, in: shape)
        } else if reduceTransparency || contrast == .increased {
            content.background(Color(white: 0.10), in: shape)
                .overlay(shape.stroke(.white.opacity(0.55), lineWidth: 1))
        } else {
            content.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.14), lineWidth: 0.5))
        }
    }
}
extension View {
    func cameraGlass(_ radius: CGFloat = 26) -> some View { modifier(CameraGlass(radius: radius)) }
}

/// A single contextual glass surface. Inner fact tiles use simple fills, never stacked glass.
struct InPlaceCard<Content: View>: View {
    let title: String
    var mediaStatus: VideoControlState? = nil
    let close: () -> Void
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: LightYearsStyle.gap) {
                Image(systemName: "viewfinder").font(.subheadline)
                Text(title.uppercased()).font(.caption.monospaced().weight(.semibold)).tracking(1.4)
                Spacer()
                if let mediaStatus { HDRBadge(state: mediaStatus) }
                Button(action: close) {
                    Image(systemName: "xmark").font(.subheadline.weight(.semibold)).frame(width: 44, height: 44)
                }.accessibilityLabel("Close \(title)")
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 20).onEnded { value in
                if value.translation.height > 45 { close() }
            })
            .padding(.horizontal, LightYearsStyle.cardInset).padding(.top, LightYearsStyle.smallGap)
            content
        }
        .cameraGlass(30)
        .accessibilityAction(.escape, close)
    }
}

struct DetailFact: Identifiable, Sendable {
    var id: String { title }
    let title: String
    let value: String
    let note: String
    let symbol: String
}

@MainActor
final class MomentMetadata: ObservableObject {
    @Published var facts: [DetailFact] = []
    @Published var camera: [DetailFact] = []
    @Published var tags: [String] = []
    @Published var coordinate: CLLocationCoordinate2D?
    @Published var isReading = false
    @Published var unavailable = false
    private var asset: PHAsset?
    private var request: PHContentEditingInputRequestID?
    private var token = UUID()
    private static var cameraCache: [String: [DetailFact]] = [:]

    func load(_ memory: Memory, allowNetwork: Bool = true) {
        cancel()
        facts = []; camera = Self.cameraCache[memory.cacheKey("metadata")] ?? []; tags = []; coordinate = nil; unavailable = false
        let captured = memory.date
        facts.append(DetailFact(title: "CAPTURED", value: captured.formatted(.dateTime.month(.abbreviated).day().year()), note: captured.formatted(.dateTime.weekday(.wide)), symbol: "calendar"))
        facts.append(DetailFact(title: "TIME", value: captured.formatted(.dateTime.hour().minute()), note: "Device time zone · \(TimeZone.current.abbreviation() ?? TimeZone.current.identifier)", symbol: "clock"))
        guard let id = memory.assetID else {
            tags = ["Fictional sample", "Illustration"]
            return
        }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            unavailable = true; return
        }
        self.asset = asset
        coordinate = asset.location?.coordinate
        facts.append(DetailFact(title: "RESOLUTION", value: "\(asset.pixelWidth) × \(asset.pixelHeight)", note: String(format: "%.1f MP", Double(asset.pixelWidth * asset.pixelHeight) / 1_000_000), symbol: "aspectratio"))
        if memory.isVideo {
            let seconds = Int(asset.duration.rounded())
            facts.append(DetailFact(title: "DURATION", value: String(format: "%d:%02d", seconds / 60, seconds % 60), note: "Video", symbol: "film"))
        }
        let resources = PHAssetResource.assetResources(for: asset)
        if let file = resources.first(where: { $0.type == .photo || $0.type == .video }) {
            facts.append(DetailFact(title: "FILE", value: file.originalFilename, note: file.uniformTypeIdentifier, symbol: "doc"))
        }
        if asset.mediaSubtypes.contains(.photoLive) { tags.append("Live Photo") }
        if asset.mediaSubtypes.contains(.photoPanorama) { tags.append("Panorama") }
        if asset.mediaSubtypes.contains(.photoDepthEffect) { tags.append("Depth effect") }
        if asset.mediaSubtypes.contains(.videoHighFrameRate) { tags.append("High frame rate") }
        if asset.mediaSubtypes.contains(.videoTimelapse) { tags.append("Time-lapse") }
        if asset.isFavorite { tags.append("Favorite") }
        guard !memory.isVideo, Self.cameraCache[memory.cacheKey("metadata")] == nil else { return }
        isReading = true
        let generation = token
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        request = asset.requestContentEditingInput(with: options) { [weak self] input, _ in
            let url = input?.fullSizeImageURL
            Task { @MainActor in
                guard let self, self.token == generation else { return }
                let values = await Task.detached(priority: .utility) { Self.readCamera(at: url) }.value
                guard self.token == generation else { return }
                if url != nil {
                    if Self.cameraCache.count >= 128 { Self.cameraCache.removeAll() }
                    Self.cameraCache[memory.cacheKey("metadata")] = values
                }
                self.camera = values
                self.isReading = false
                self.unavailable = url == nil
            }
        }
    }
    func cancel() {
        token = UUID()
        if let request, let asset { asset.cancelContentEditingInputRequest(request) }
        request = nil; asset = nil; isReading = false
    }
    nonisolated private static func readCamera(at url: URL?) -> [DetailFact] {
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return [] }
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        var result: [DetailFact] = []
        if let model = tiff[kCGImagePropertyTIFFModel as String] as? String {
            result.append(DetailFact(title: "CAMERA", value: model, note: tiff[kCGImagePropertyTIFFMake as String] as? String ?? "", symbol: "camera"))
        }
        if let lens = exif[kCGImagePropertyExifLensModel as String] as? String {
            result.append(DetailFact(title: "LENS", value: lens, note: "Recorded by camera", symbol: "camera.aperture"))
        }
        if let focal = exif[kCGImagePropertyExifFocalLength as String] as? NSNumber {
            result.append(DetailFact(title: "FOCAL LENGTH", value: String(format: "%.1f mm", focal.doubleValue), note: "Actual focal length", symbol: "viewfinder"))
        }
        if let aperture = exif[kCGImagePropertyExifFNumber as String] as? NSNumber {
            result.append(DetailFact(title: "APERTURE", value: String(format: "ƒ/%.1f", aperture.doubleValue), note: "Lens opening", symbol: "camera.aperture"))
        }
        if let exposure = exif[kCGImagePropertyExifExposureTime as String] as? NSNumber, exposure.doubleValue > 0 {
            let seconds = exposure.doubleValue
            let value = seconds < 1 ? "1/\(Int((1 / seconds).rounded())) s" : String(format: "%.1f s", seconds)
            result.append(DetailFact(title: "SHUTTER", value: value, note: "Exposure time", symbol: "timer"))
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first {
            result.append(DetailFact(title: "ISO", value: iso.stringValue, note: "Recorded sensitivity", symbol: "sun.max"))
        }
        return result
    }
}

struct MomentDetails: View {
    let memory: Memory
    var showsLocation = true
    var allowsNetworkMetadata = true
    var measuredHeight: Binding<CGFloat>? = nil
    @StateObject private var metadata = MomentMetadata()
    @State private var expanded: String?
    @State private var showMap = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var textSize
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: LightYearsStyle.gap), count: textSize.isAccessibilitySize ? 1 : 2)
    }
    var body: some View {
        ScrollView {
            VStack(spacing: LightYearsStyle.gap) {
                if showsLocation, let coordinate = metadata.coordinate {
                    VStack(spacing: LightYearsStyle.gap) {
                        Button {
                            UISelectionFeedbackGenerator().selectionChanged()
                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { showMap.toggle() }
                        } label: {
                            VStack(alignment: .leading, spacing: LightYearsStyle.smallGap) {
                                Label("RECORDED LOCATION", systemImage: "location.fill").font(.caption.monospaced().weight(.semibold))
                                Text(String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)).font(.subheadline.monospacedDigit())
                                Text(showMap ? "Hide map" : "Explore map").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
                        }.buttonStyle(.plain).accessibilityLabel("Recorded location. \(showMap ? "Hide" : "Show") map")
                        if showMap {
                            Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)))) {
                                Marker("Recorded location", coordinate: coordinate)
                            }.frame(height: 160).clipShape(RoundedRectangle(cornerRadius: 14))
                            Text("Recorded location · Map provided by Apple").font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(LightYearsStyle.tileInset)
                        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
                }
                LazyVGrid(columns: columns, spacing: LightYearsStyle.gap) {
                    ForEach(metadata.facts + metadata.camera) { fact in
                        Button {
                            UISelectionFeedbackGenerator().selectionChanged()
                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { expanded = expanded == fact.id ? nil : fact.id }
                        } label: {
                            VStack(alignment: .leading, spacing: LightYearsStyle.smallGap) {
                                Label(fact.title, systemImage: fact.symbol).font(LightYearsStyle.labelFont).foregroundStyle(.secondary)
                                Text(fact.value).font(LightYearsStyle.valueFont)
                                    .lineLimit(expanded == fact.id ? nil : 2).frame(maxWidth: .infinity, alignment: .leading)
                                if expanded == fact.id { Text(fact.note).font(.caption).foregroundStyle(.secondary) }
                            }
                            .padding(LightYearsStyle.tileInset).frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
                            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.09), lineWidth: 0.5))
                        }.buttonStyle(.plain)
                            .accessibilityLabel("\(fact.title), \(fact.value)")
                            .accessibilityHint("Tap to \(expanded == fact.id ? "collapse" : "show the source detail")")
                    }
                }
                if !metadata.tags.isEmpty {
                    Text(metadata.tags.joined(separator: "  ·  ")).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
                }
                if metadata.isReading { ProgressView().controlSize(.small).accessibilityLabel("Reading camera metadata") }
                if metadata.unavailable {
                    Button(allowsNetworkMetadata ? "Retry camera details" : "Load camera details") { metadata.load(memory) }.font(.caption).frame(minHeight: 44)
                }
            }.padding(LightYearsStyle.cardInset)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    measuredHeight?.wrappedValue = height
                }
        }
        .task(id: memory.id) { expanded = nil; showMap = true; metadata.load(memory, allowNetwork: allowsNetworkMetadata) }
        .onDisappear { metadata.cancel() }
    }
}

/// Header lookup uses Apple's geocoder only where explicitly enabled.
/// City-name lookup sends capture coordinates, never media, to Apple.
@MainActor
final class RecordedPlaceStore: ObservableObject {
    typealias Resolver = (CLLocation) async throws -> String?
    @Published private var selection = RecordedPlaceSelection()
    private let resolver: Resolver?
    init(resolver: Resolver? = nil) { self.resolver = resolver }
    private static var cityCache: [String: String] = [:]
    static func cityName(for location: CLLocation) async throws -> String? {
        let key = String(format: "%.5f,%.5f", location.coordinate.latitude, location.coordinate.longitude)
        if let cached = cityCache[key] { return cached }
        let city: String?
        if #available(iOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
            let items = try await withTaskCancellationHandler {
                try await request.mapItems
            } onCancel: {
                Task { @MainActor in request.cancel() }
            }
            city = items.first?.addressRepresentations?.cityName
        } else {
            city = try await CLGeocoder().reverseGeocodeLocation(location).first?.locality
        }
        try Task.checkCancellation()
        guard let city = city?.trimmingCharacters(in: .whitespacesAndNewlines), !city.isEmpty else { return nil }
        if cityCache.count >= 128 { cityCache.removeAll(keepingCapacity: true) }
        cityCache[key] = city
        return city
    }
    func label(for memory: Memory) -> String? { selection.label(for: memory) }
    func load(_ memory: Memory) async {
        let token = selection.begin(memory)
        guard let resolver, let id = memory.assetID,
              let location = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject?.location,
              CLLocationCoordinate2DIsValid(location.coordinate) else { return }
        do {
            try await Task.sleep(for: .milliseconds(350))
            try Task.checkCancellation()
            let name = try await resolver(location)
            try Task.checkCancellation()
            selection.resolve(name, request: token)
        } catch { selection.resolve(nil, request: token) }
    }
}

struct RecordedPlaceHeader: View {
    let memory: Memory
    @StateObject private var place = RecordedPlaceStore()
    var body: some View {
        Group {
            if let name = place.label(for: memory) {
                Label(name, systemImage: "mappin.and.ellipse")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.tail)
                    .accessibilityLabel("Recorded location: \(name)")
            }
        }
        .task(id: memory) { await place.load(memory) }
    }
}

/// Reads only local PhotoKit metadata; never infers a place or sample capture time.
struct CaptureMetadataHeader: View {
    let memory: Memory
    @State private var loadedMemory: Memory?
    @State private var location: String?
    @State private var captureDate: Date?

    private var locationText: String {
        guard memory.assetID != nil else { return "Sample image" }
        return loadedMemory == memory ? location ?? "No recorded location" : "Reading metadata…"
    }
    private var dateText: String {
        guard memory.assetID != nil else { return "Illustration" }
        guard loadedMemory == memory else { return "" }
        return captureDate?.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()) ?? "No capture time"
    }
    var body: some View {
        HStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Text(locationText)
                    Spacer(minLength: 0)
                    Text(dateText).monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(locationText)
                    Text(dateText).monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(locationText). \(dateText). Capture time uses your device’s time zone.")

        }
        .padding(.leading, LightYearsStyle.pageInset)
        .padding(.trailing, LightYearsStyle.pageInset)
        .padding(.vertical, 10)
        .background(.black)
        .task(id: memory) {
            location = nil; captureDate = nil
            if let id = memory.assetID,
               let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject {
                captureDate = asset.creationDate
                if let coordinate = asset.location?.coordinate, CLLocationCoordinate2DIsValid(coordinate) {
                    location = String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
                }
            }
            loadedMemory = memory
        }
    }
}

/// Native button material owns interaction and accessibility adaptation on iOS 26+.
private struct ControlGlassButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glass).buttonBorderShape(.circle)
                .controlSize(.regular)
                .frame(minWidth: 44, minHeight: 44)
        } else {
            content.buttonStyle(.bordered).buttonBorderShape(.circle)
                .controlSize(.regular)
                .frame(minWidth: 44, minHeight: 44)
        }
    }
}
extension View {
    func controlGlassButton() -> some View { modifier(ControlGlassButton()) }
}

/// Groups neighboring control surfaces without adding another glass background.
struct GlassControlGroup<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 8) { content }
        } else {
            content
        }
    }
}


/// A factual anniversary title, with no invented location or sample narrative.
struct MemoryStoryHeader: View {
    let memory: Memory
    let today: Date
    @ObservedObject private var place = DayPlacePreloader.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(memory.assetID == nil ? "Sample memory" : MemoryAge(captured: memory.date, now: today).title)
                .font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.leading)
        .accessibilityElement(children: .combine)
    }
    private var subtitle: String {
        let date = memory.date.formatted(.dateTime.month(.wide).day())
        if let name = place.label(for: memory) { return "\(date) in \(name)" }
        return date
    }
}


/// Shares the day's image preload ordering. One lookup at a time; no work on sample assets.
@MainActor
final class DayPlacePreloader: ObservableObject {
    static let shared = DayPlacePreloader()
    @Published private var names: [Memory: String] = [:]
    private var completed: Set<Memory> = []
    private var source: [Memory] = []
    private var queue: [Memory] = []
    private var current: Memory?
    private var worker: Task<Void, Never>?
    private var generation = UUID()

    func label(for memory: Memory) -> String? { names[memory] }
    func prioritize(_ memories: [Memory], index: Int) {
        guard memories.indices.contains(index) else { return }
        if source != memories {
            pause()
            source = memories
            let keep = Set(memories)
            names = names.filter { keep.contains($0.key) }
            completed.formIntersection(keep)
        }
        let byAsset = Dictionary(memories.compactMap { memory in memory.assetID.map { ($0, memory) } }, uniquingKeysWith: { first, _ in first })
        queue = MediaPreloadPlan(memories: memories, selectedIndex: index).thumbnailIDs
            .compactMap { byAsset[$0] }
            .filter { !completed.contains($0) && $0 != current }
        guard worker == nil, !queue.isEmpty else { return }
        let token = generation
        worker = Task { [weak self] in
            guard let self else { return }
            while !self.queue.isEmpty && !Task.isCancelled && self.generation == token {
                let memory = self.queue.removeFirst()
                self.current = memory
                guard let id = memory.assetID,
                      let location = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject?.location,
                      CLLocationCoordinate2DIsValid(location.coordinate) else {
                    self.completed.insert(memory); self.current = nil; continue
                }
                do {
                    let name = try await RecordedPlaceStore.cityName(for: location)
                    try Task.checkCancellation()
                    guard self.generation == token else { return }
                    if let name { self.names[memory] = name }
                    self.completed.insert(memory)
                } catch {
                    guard !Task.isCancelled, self.generation == token else { return }
                    // Back off on service failure rather than flooding the geocoder.
                    try? await Task.sleep(for: .seconds(2))
                }
                self.current = nil
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard self.generation == token else { return }
            self.worker = nil; self.current = nil
        }
    }
    func pause() {
        generation = UUID()
        worker?.cancel(); worker = nil; current = nil; queue = []
    }
    func clear() {
        pause(); names = [:]; completed = []; source = []
    }
}


struct MemoryMapPoint: Identifiable, Equatable, Sendable {
    let memory: Memory
    let latitude: Double
    let longitude: Double
    var id: String { memory.id }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

@MainActor
final class MemoryMapStore: ObservableObject {
    @Published private(set) var points: [MemoryMapPoint] = []
    @Published private(set) var loading = false
    func load(_ memories: [Memory]) async {
        loading = true
        let result = await Task.detached(priority: .utility) {
            let ids = memories.compactMap(\.assetID)
            guard !ids.isEmpty else { return [MemoryMapPoint]() }
            let source = Dictionary(memories.compactMap { memory in memory.assetID.map { ($0, memory) } }, uniquingKeysWith: { first, _ in first })
            var result: [MemoryMapPoint] = []
            PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
                guard let memory = source[asset.localIdentifier], let coordinate = asset.location?.coordinate,
                      CLLocationCoordinate2DIsValid(coordinate) else { return }
                result.append(MemoryMapPoint(memory: memory, latitude: coordinate.latitude, longitude: coordinate.longitude))
            }
            return result.sorted { $0.memory.date < $1.memory.date }
        }.value
        guard !Task.isCancelled else { return }
        points = result; loading = false
    }
}

struct MemoryJourneyContext: View {
    let memories: [Memory]
    let selected: Memory
    let safeFrame: CGRect
    let headerTop: CGFloat?
    let controlsVisible: Bool
    let onTracking: (Bool) -> Void
    let onSelect: (String) -> Void
    let onInteraction: () -> Void
    @StateObject private var locations = MemoryMapStore()
    @ObservedObject private var places = DayPlacePreloader.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var overview = false
    @State private var focusRevision = 0
    @State private var cardHeight: CGFloat = 240
    @State private var stableSafeFrame: CGRect?

    private var visiblePoints: [MemoryMapPoint] {
        if !overview { return locations.points.filter { $0.id == selected.id } }
        // One native marker per recorded coordinate, not a stack of differently colored pins.
        var seen = Set<String>()
        return locations.points.filter {
            seen.insert(String(format: "%.5f,%.5f", $0.latitude, $0.longitude)).inserted
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let frame = geometry.frame(in: .global)
            let layoutSafeFrame = stableSafeFrame ?? safeFrame
            let leadingInset = max(12, layoutSafeFrame.minX - frame.minX + 12)
            let trailingInset = max(12, frame.maxX - layoutSafeFrame.maxX + 12)
            let topInset = max(12, (headerTop ?? (safeFrame.minY + 8)) - frame.minY)
            // This pane already occupies its assigned unobscured region. A cached toolbar
            // safe frame can retain a former horizontal bar and lift the entire row.
            let bottomInset = max(28, geometry.safeAreaInsets.bottom)

            ZStack(alignment: .bottom) {
                StableMemoryMap(points: visiblePoints, selectedID: selected.id, overview: overview, focusRevision: focusRevision,
                                bottomOcclusion: cardHeight + bottomInset + 12,
                                trailingOcclusion: trailingInset, reduceMotion: reduceMotion, onSelect: onSelect)
                .overlay(alignment: .topLeading) {
                    if controlsVisible {
                        Button {
                            onInteraction()
                            overview.toggle()
                            MediaNavigationTrace.event("map-button overview=\(overview) selectedHasLocation=\(locations.points.contains { $0.id == selected.id })")
                            focusRevision += 1
                            if !overview { focusSelected(animated: true) }
                        } label: {
                            Label(overview ? "Selected location" : "All locations", systemImage: "map")
                                .font(.caption.weight(.semibold))
                                .padding(10)
                        }
                        .buttonStyle(.plain).cameraGlass(18)
                        .padding(.leading, leadingInset).padding(.trailing, trailingInset).padding(.top, topInset)
                        .disabled(locations.points.isEmpty)
                    }
                }
                HStack(alignment: .bottom, spacing: 12) {
                CompactMomentFacts(memory: selected,
                                   place: places.label(for: selected) ?? (locations.points.contains { $0.id == selected.id } ? "Recorded location" : "No recorded location"),
                                   maximumHeight: max(100, geometry.size.height - topInset - bottomInset - 60))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .cameraGlass(26)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .frame(maxWidth: .infinity)
                VStack(spacing: 8) {
                    Text(String(selected.year)).font(.caption.bold().monospacedDigit())
                    MemoryTimelineSlider(memories: memories,
                        selectedIndex: memories.firstIndex(where: { $0.id == selected.id }) ?? 0,
                        isActive: controlsVisible, vertical: true,
                        onSelect: { index in onSelect(memories[index].id) }, onTracking: onTracking)
                }
                .padding(12)
                .cameraGlass(30)
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)
                .accessibilityHidden(!controlsVisible)
                }
                .padding(.leading, leadingInset).padding(.trailing, 16)
                .padding(.bottom, bottomInset)
            }
            .clipped()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in
                stableSafeFrame = safeFrame
            }
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in onInteraction() })
        }
        .task(id: memories) {
            await locations.load(memories)
            focusSelected(animated: false)
        }
        .onChange(of: selected.id) { _, _ in focusSelected(animated: true) }
    }
    private func focusSelected(animated: Bool) {
        overview = false
        focusRevision += 1
    }
}


/// Persistent details use natural row heights instead of large, tappable bento tiles.
private struct CompactMomentFacts: View {
    let memory: Memory
    let place: String
    let maximumHeight: CGFloat
    @StateObject private var metadata = MomentMetadata()
    @State private var contentHeight: CGFloat = 160
    @Environment(\.dynamicTypeSize) private var textSize

    private var facts: [DetailFact] {
        guard !memory.isVideo else { return metadata.facts }
        // Stable factual slots avoid collapsing the panel while EXIF arrives.
        let slots = [("CAMERA", "camera"), ("LENS", "camera.aperture"),
                     ("FOCAL LENGTH", "viewfinder"), ("APERTURE", "camera.aperture"),
                     ("SHUTTER", "timer"), ("ISO", "sun.max")]
        return metadata.facts + slots.map { title, symbol in
            metadata.camera.first { $0.title == title }
                ?? DetailFact(title: title, value: "—", note: "Not available", symbol: symbol)
        }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(place).font(.headline).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: textSize.isAccessibilitySize ? 1 : 2), alignment: .leading, spacing: 12) {
                ForEach(facts) { fact in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(fact.title, systemImage: fact.symbol)
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(fact.value).font(.subheadline.weight(.medium))
                            .lineLimit(2, reservesSpace: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            if !metadata.tags.isEmpty {
                Text(metadata.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            if metadata.unavailable {
                Button("Load camera details") { metadata.load(memory) }.font(.caption)
            }
        }.padding(16)
    }
    var body: some View {
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollDisabled(contentHeight <= maximumHeight)
        .frame(height: min(contentHeight, maximumHeight))
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        .task(id: memory.id) { metadata.load(memory, allowNetwork: false) }
        .onDisappear { metadata.cancel() }
    }
}


/// Map framing and attribution are independent of transient toolbar safe areas.
private struct StableMemoryMap: UIViewRepresentable {
    let points: [MemoryMapPoint]
    let selectedID: String
    let overview: Bool
    let focusRevision: Int
    let bottomOcclusion: CGFloat
    let trailingOcclusion: CGFloat
    let reduceMotion: Bool
    let onSelect: (String) -> Void

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: StableMemoryMap
        var signature = ""
        var framing = ""
        var applying = false
        var lastOverview = false
        init(_ parent: StableMemoryMap) { self.parent = parent }
        func mapView(_ mapView: MKMapView, didSelect annotation: any MKAnnotation) {
            guard let point = annotation as? MemoryAnnotation, point.id != parent.selectedID else { return }
            parent.onSelect(point.id)
        }
    }
    final class MemoryAnnotation: NSObject, MKAnnotation {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let title: String? = "Recorded location"
        init(_ point: MemoryMapPoint) { id = point.id; coordinate = point.coordinate }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class LayoutMap: MKMapView {
        var onLayout: ((MKMapView) -> Void)?
        override func layoutSubviews() { super.layoutSubviews(); onLayout?(self) }
    }
    func makeUIView(context: Context) -> MKMapView {
        let map = LayoutMap()
        map.onLayout = { [weak coordinator = context.coordinator] map in
            guard let coordinator else { return }
            coordinator.parent.apply(map, coordinator: coordinator)
        }
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.insetsLayoutMarginsFromSafeArea = false
        map.layoutMargins = UIEdgeInsets(top: 12, left: 12, bottom: 4, right: 12)
        return map
    }
    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        apply(map, coordinator: context.coordinator)
    }
    private func apply(_ map: MKMapView, coordinator: Coordinator) {
        guard !coordinator.applying else { return }
        coordinator.applying = true
        defer { coordinator.applying = false }
        let signature = points.map { "\($0.id):\($0.latitude):\($0.longitude)" }.joined(separator: "|")
        if coordinator.signature != signature {
            coordinator.signature = signature
            map.removeAnnotations(map.annotations)
            map.addAnnotations(points.map(MemoryAnnotation.init))
        }
        let framing = "\(signature):\(selectedID):\(overview):\(focusRevision):\(map.bounds.size):\(Int(bottomOcclusion)):\(Int(trailingOcclusion))"
        guard !points.isEmpty, map.bounds.width > 0, map.bounds.height > 0,
              coordinator.framing != framing else { return }
        let returningToSelected = coordinator.lastOverview && !overview
        let animate = !coordinator.framing.isEmpty && !reduceMotion && !returningToSelected
        coordinator.lastOverview = overview
        coordinator.framing = framing
        MediaNavigationTrace.event("map-focus overview=\(overview) points=\(points.count) explicitReturn=\(returningToSelected)")
        var rect = MKMapRect.null
        for point in points {
            let center = MKMapPoint(point.coordinate)
            let radius = (overview ? 700.0 : 250.0) * MKMapPointsPerMeterAtLatitude(point.latitude)
            rect = rect.union(MKMapRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        if returningToSelected {
            // Cancel an unfinished world/overview flight before restoring the selected close-up.
            map.setVisibleMapRect(map.visibleMapRect, animated: false)
        }
        map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 70, left: 24,
            bottom: min(bottomOcclusion, map.bounds.height * 0.75),
            right: max(24, trailingOcclusion)), animated: animate)
    }
}

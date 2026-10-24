import SwiftUI
import Photos
import UIKit

/// UI state lives outside the grid so collapsing it retains the browsing anchor.
@MainActor
final class MemoryGridState: ObservableObject {
    var anchorID: String?
    var anchorOffset: CGFloat = 0
}

struct MemoryYearGrid: UIViewControllerRepresentable {
    let memories: [Memory]
    let selectedID: String
    let state: MemoryGridState
    let active: Bool
    let onSelect: (String) -> Void
    func makeUIViewController(context: Context) -> MemoryYearGridController { MemoryYearGridController(state: state) }
    func updateUIViewController(_ controller: MemoryYearGridController, context: Context) {
        controller.onSelect = onSelect
        controller.setActive(active)
        controller.configure(memories, selectedID: selectedID)
    }
    static func dismantleUIViewController(_ controller: MemoryYearGridController, coordinator: ()) {
        controller.saveAnchor()
        controller.thumbnails.stop()
    }
}

/// Thumbnail-only PhotoKit client: four requests at a time, canceled when no longer useful.
/// The full-quality pager remains the owner of playback and day preparation.
@MainActor
final class GridThumbnails {
    private let manager = PHCachingImageManager()
    private let cache = NSCache<NSString, UIImage>()
    private let preheatOptions: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        return options
    }()
    private var requests: [String: PHImageRequestID] = [:]
    private var tokens: [String: UUID] = [:]
    private var watchdogs: [String: Task<Void, Never>] = [:]
    private var desired: [(Memory, CGFloat)] = []
    private var completed = Set<String>()
    private var heated: [PHAsset] = []
    private var heatSize = CGSize.zero
    var onImage: ((String) -> Void)?
    init() { cache.totalCostLimit = 48 * 1024 * 1024; cache.countLimit = 160 }
    private func key(_ memory: Memory, _ pixels: CGFloat) -> String { memory.cacheKey("grid-\(Int(pixels))") }
    func image(_ memory: Memory, pixels: CGFloat) -> UIImage? { cache.object(forKey: key(memory, pixels) as NSString) }
    func update(_ memories: [Memory], pixels: CGFloat) {
        desired = memories.map { ($0, pixels) }
        let wanted = Set(desired.map { key($0.0, $0.1) })
        for (key, request) in requests where !wanted.contains(key) {
            tokens[key] = nil; requests[key] = nil
            watchdogs.removeValue(forKey: key)?.cancel()
            manager.cancelImageRequest(request)
        }
        completed.formIntersection(wanted)
        pump()
    }
    func preheat(_ memories: [Memory], pixels: CGFloat) {
        let ids = memories.compactMap(\.assetID)
        let oldIDs = heated.map(\.localIdentifier)
        let size = CGSize(width: pixels, height: pixels)
        guard oldIDs != ids || heatSize != size else { return }
        if !heated.isEmpty { manager.stopCachingImages(for: heated, targetSize: heatSize, contentMode: .aspectFit, options: preheatOptions) }
        heated = []
        if !ids.isEmpty {
            PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in self.heated.append(asset) }
        }
        heatSize = size
        // Speculative preheating is local only; explicit visible requests may download.
        if !heated.isEmpty { manager.startCachingImages(for: heated, targetSize: size, contentMode: .aspectFit, options: preheatOptions) }
    }
    private func pump() {
        for (memory, pixels) in desired where requests.count < 4 {
            let key = key(memory, pixels)
            guard requests[key] == nil, !completed.contains(key), image(memory, pixels: pixels) == nil else { continue }
            if memory.assetID == nil {
                let renderer = ImageRenderer(content: SampleLandscape(scene: memory.scene).frame(width: 150, height: 324))
                renderer.scale = 2
                if let image = renderer.uiImage {
                    cache.setObject(image, forKey: key as NSString, cost: Int(DayMediaPipeline.pixelCount(image) * 4))
                    onImage?(memory.id)
                }
                completed.insert(key)
                continue
            }
            guard let id = memory.assetID,
                  let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { continue }
            let token = UUID(); tokens[key] = token
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            requests[key] = manager.requestImage(for: asset, targetSize: CGSize(width: pixels, height: pixels), contentMode: .aspectFit, options: options) { [weak self] image, info in
                let terminal = !(info?[PHImageResultIsDegradedKey] as? Bool ?? false)
                    || info?[PHImageErrorKey] != nil || (info?[PHImageCancelledKey] as? Bool ?? false)
                Task { @MainActor in
                    guard let self, self.tokens[key] == token else { return }
                    if let image {
                        let old = self.cache.object(forKey: key as NSString)
                        if old == nil || DayMediaPipeline.pixelCount(image) >= DayMediaPipeline.pixelCount(old!) {
                            self.cache.setObject(image, forKey: key as NSString, cost: Int(DayMediaPipeline.pixelCount(image) * 4))
                            self.onImage?(memory.id)
                        }
                    }
                    if terminal {
                        self.requests[key] = nil; self.tokens[key] = nil; self.completed.insert(key)
                        self.watchdogs.removeValue(forKey: key)?.cancel()
                        self.pump()
                    }
                }
            }
            watchdogs[key] = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                guard let self, self.tokens[key] == token else { return }
                self.tokens[key] = nil
                if let request = self.requests.removeValue(forKey: key) { self.manager.cancelImageRequest(request) }
                self.watchdogs[key] = nil; self.completed.insert(key)
                self.pump()
            }
        }
    }
    func stop() {
        tokens.removeAll()
        watchdogs.values.forEach { $0.cancel() }; watchdogs.removeAll()
        for request in requests.values { manager.cancelImageRequest(request) }
        requests.removeAll(); desired = []; completed.removeAll()
        if !heated.isEmpty { manager.stopCachingImagesForAllAssets() }
        heated = []
    }
}

@MainActor
final class MemoryYearGridController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UICollectionViewDataSourcePrefetching {
    let thumbnails = GridThumbnails()
    private let state: MemoryGridState
    private let flow = UICollectionViewFlowLayout()
    private lazy var grid = UICollectionView(frame: .zero, collectionViewLayout: flow)
    private var sections: [MemoryYearSection] = []
    private var memories: [Memory] = []
    private var selectedID = ""
    private var previousSize = CGSize.zero
    private var lastDisplayScale: CGFloat = 0
    private var restoring = false
    private var needsRestore = true
    private var pixels: CGFloat = 320
    private var active = true
    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        if !value { thumbnails.stop() } else if isViewLoaded { requestVisible() }
    }
    var onSelect: ((String) -> Void)?
    init(state: MemoryGridState) { self.state = state; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        grid.backgroundColor = .black
        grid.alwaysBounceVertical = true
        grid.contentInsetAdjustmentBehavior = .never
        grid.dataSource = self; grid.delegate = self; grid.prefetchDataSource = self
        grid.register(MemoryThumbnailCell.self, forCellWithReuseIdentifier: "memory")
        grid.register(MemoryYearHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "year")
        flow.minimumInteritemSpacing = 8; flow.minimumLineSpacing = 8
        flow.sectionInset = UIEdgeInsets(top: 0, left: 12, bottom: 16, right: 12)
        flow.sectionHeadersPinToVisibleBounds = true
        view.addSubview(grid)
        thumbnails.onImage = { [weak self] id in self?.refreshVisible(id: id) }
    }
    func configure(_ memories: [Memory], selectedID: String) {
        loadViewIfNeeded()
        if self.memories != memories {
            saveAnchor(); thumbnails.stop()
            self.memories = memories; sections = MemoryYearSection.sections(memories)
            let valid = Set(memories.map(\.id))
            if let anchor = state.anchorID, !valid.contains(anchor) { state.anchorID = nil; state.anchorOffset = 0 }
            grid.reloadData(); needsRestore = true
        }
        self.selectedID = selectedID
        if state.anchorID == nil { state.anchorID = selectedID }
        refreshVisible()
        view.setNeedsLayout()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }
        let headerHeight = max(44, UIFont.preferredFont(forTextStyle: .headline).lineHeight + 20)
        let changed = previousSize != view.bounds.size || lastDisplayScale != traitCollection.displayScale || flow.headerReferenceSize.height != headerHeight
        if changed {
            // Save against the old collection frame before changing it.
            if previousSize != .zero && !needsRestore { saveAnchor() }
            restoring = true
            previousSize = view.bounds.size
            lastDisplayScale = traitCollection.displayScale
            grid.frame = view.bounds
            let columns = MemoryBrowserLayout.columns(width: view.bounds.width)
            let side = floor((view.bounds.width - 24 - CGFloat(columns - 1) * 8) / CGFloat(columns))
            flow.itemSize = CGSize(width: side, height: side)
            flow.headerReferenceSize = CGSize(width: view.bounds.width, height: headerHeight)
            pixels = min(960, max(160, ceil(side * traitCollection.displayScale / 160) * 160))
            flow.invalidateLayout()
        }
        if changed || needsRestore {
            restoring = true
            grid.layoutIfNeeded()
            restoreAnchor()
            restoring = false; needsRestore = false
        }
        refreshVisible(); requestVisible()
    }
    private func memory(_ path: IndexPath) -> Memory { sections[path.section].memories[path.item] }
    private func path(for id: String) -> IndexPath? {
        for (section, value) in sections.enumerated() {
            if let item = value.memories.firstIndex(where: { $0.id == id }) { return IndexPath(item: item, section: section) }
        }
        return nil
    }
    func saveAnchor() {
        guard isViewLoaded, !restoring, grid.bounds.height > 0 else { return }
        let region = CGRect(x: grid.contentOffset.x, y: grid.contentOffset.y + flow.headerReferenceSize.height,
                            width: grid.bounds.width, height: max(1, grid.bounds.height - flow.headerReferenceSize.height))
        let visible = (flow.layoutAttributesForElements(in: region) ?? [])
            .filter { $0.representedElementCategory == .cell && $0.frame.intersects(region) }
            .map(\.indexPath).sorted()
        guard let first = visible.first, let frame = grid.layoutAttributesForItem(at: first)?.frame,
              sections.indices.contains(first.section), sections[first.section].memories.indices.contains(first.item) else { return }
        state.anchorID = memory(first).id
        state.anchorOffset = (grid.contentOffset.y + flow.headerReferenceSize.height - frame.minY) / max(1, frame.height)
    }
    private func restoreAnchor() {
        guard let id = state.anchorID, let path = path(for: id), let frame = grid.layoutAttributesForItem(at: path)?.frame else { return }
        let y = frame.minY + state.anchorOffset * frame.height - flow.headerReferenceSize.height
        grid.setContentOffset(CGPoint(x: 0, y: min(max(0, grid.contentSize.height - grid.bounds.height), max(0, y))), animated: false)
    }
    func numberOfSections(in collectionView: UICollectionView) -> Int { sections.count }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { sections[section].memories.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "memory", for: indexPath) as! MemoryThumbnailCell
        let memory = memory(indexPath)
        cell.configure(memory, image: thumbnails.image(memory, pixels: pixels), selected: memory.id == selectedID)
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "year", for: indexPath) as! MemoryYearHeader
        header.label.text = String(sections[indexPath.section].year)
        return header
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        saveAnchor()
        onSelect?(memory(indexPath).id)
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !restoring else { return }
        if grid.isDragging || grid.isDecelerating { saveAnchor() }
        requestVisible()
    }
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // UIKit reports scrolling before every new cell is attached. Reconcile
        // once the display pass finishes so the final row is never left unrequested.
        Task { @MainActor [weak self] in self?.requestVisible() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { saveAnchor(); requestVisible() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { saveAnchor(); requestVisible() }
    }
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        guard active else { return }
        thumbnails.preheat(Array(indexPaths.prefix(24)).map(memory), pixels: pixels)
    }
    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        thumbnails.preheat([], pixels: pixels)
    }
    private func requestVisible() {
        guard !restoring, active else { return }
        let visible = grid.indexPathsForVisibleItems.sorted().map(memory)
        thumbnails.update(visible, pixels: pixels)
    }
    private func refreshVisible(id: String? = nil) {
        for case let cell as MemoryThumbnailCell in grid.visibleCells {
            guard let path = grid.indexPath(for: cell), sections.indices.contains(path.section), sections[path.section].memories.indices.contains(path.item) else { continue }
            let memory = memory(path)
            if id == nil || id == memory.id { cell.configure(memory, image: thumbnails.image(memory, pixels: pixels), selected: memory.id == selectedID) }
        }
    }
}

private final class MemoryThumbnailCell: UICollectionViewCell {
    private let image = UIImageView()
    private let badge = UIImageView(image: UIImage(systemName: "play.fill"))
    private let placeholder = UIImageView(image: UIImage(systemName: "photo"))
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = UIColor(white: 0.045, alpha: 1)
        contentView.layer.cornerRadius = 8; contentView.clipsToBounds = true
        image.contentMode = .scaleAspectFit
        badge.tintColor = .white; badge.contentMode = .scaleAspectFit
        badge.backgroundColor = UIColor.black.withAlphaComponent(0.6); badge.layer.cornerRadius = 6
        placeholder.tintColor = .secondaryLabel; placeholder.contentMode = .scaleAspectFit
        [image, placeholder, badge].forEach(contentView.addSubview)
        isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    override func layoutSubviews() {
        super.layoutSubviews()
        image.frame = contentView.bounds.insetBy(dx: 2, dy: 2)
        placeholder.frame = CGRect(x: bounds.midX - 12, y: bounds.midY - 12, width: 24, height: 24)
        badge.frame = CGRect(x: 8, y: bounds.height - 30, width: 26, height: 22)
    }
    func configure(_ memory: Memory, image: UIImage?, selected: Bool) {
        self.image.image = image
        placeholder.isHidden = image != nil
        badge.isHidden = !memory.isVideo
        contentView.layer.borderWidth = selected ? 2 : 0
        contentView.layer.borderColor = UIColor.white.cgColor
        accessibilityLabel = "\(memory.isVideo ? "Video" : "Photo"), \(memory.date.formatted(date: .abbreviated, time: .shortened))"
        accessibilityTraits = selected ? [.button, .selected] : [.button]
        accessibilityHint = "Open this memory"
    }
}

private final class MemoryYearHeader: UICollectionReusableView {
    let label = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        label.font = .preferredFont(forTextStyle: .headline); label.adjustsFontForContentSizeCategory = true
        label.textColor = .white; label.accessibilityTraits = .header
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    override func layoutSubviews() { super.layoutSubviews(); label.frame = bounds.insetBy(dx: 12, dy: 8) }
}

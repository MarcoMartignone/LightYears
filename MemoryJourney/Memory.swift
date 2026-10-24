import Foundation
import CoreGraphics

struct Memory: Identifiable, Hashable, Sendable {
    let id: String
    let date: Date
    let title: String
    let connection: String
    let scene: Int
    var assetID: String? = nil
    var isVideo: Bool = false
    var modificationDate: Date? = nil
    var isScreenshot: Bool = false
    var year: Int { Calendar.current.component(.year, from: date) }
}

struct MemoryCollection: Sendable {
    let memories: [Memory]
    init(memories: [Memory]) {
        self.memories = memories.filter { !$0.isScreenshot }.sorted {
            $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date
        }
    }
    func onThisDay(_ date: Date, calendar: Calendar = .current) -> [Memory] {
        let target = calendar.dateComponents([.month, .day], from: date)
        return memories.filter {
            let parts = calendar.dateComponents([.month, .day], from: $0.date)
            return parts.month == target.month && parts.day == target.day
        }.sorted {
            let leftYear = calendar.component(.year, from: $0.date)
            let rightYear = calendar.component(.year, from: $1.date)
            if leftYear != rightYear { return leftYear > rightYear }
            return $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date
        }
    }
    func journey(from memory: Memory) -> [Memory] {
        memories.filter {
            if memory.assetID != nil {
                return $0.assetID != nil && abs($0.date.timeIntervalSince(memory.date)) <= 3 * 24 * 60 * 60
            }
            return $0.connection == memory.connection
        }.sorted { $0.date < $1.date }
    }
    static func sample(today: Date = Date(), calendar: Calendar = .current) -> MemoryCollection {
        let day = calendar.dateComponents([.month, .day], from: today)
        let thisYear = calendar.component(.year, from: today)
        func date(_ yearsAgo: Int, offset: Int = 0) -> Date {
            // Clamp leap day in non-leap years instead of silently rolling into March.
            let start = calendar.date(from: DateComponents(year: thisYear - yearsAgo, month: day.month, day: 1))!
            let last = calendar.range(of: .day, in: .month, for: start)!.count
            let base = calendar.date(byAdding: .day, value: min(day.day!, last) - 1, to: start)!
            return calendar.date(byAdding: .day, value: offset, to: base)!
        }
        return MemoryCollection(memories: [
            Memory(id: "shore-recent", date: date(1), title: "At the water’s edge", connection: "By the water", scene: 0),
            Memory(id: "mountain", date: date(3), title: "A little higher", connection: "Open horizons", scene: 1),
            Memory(id: "shore-early", date: date(5), title: "The long way home", connection: "By the water", scene: 2),
            Memory(id: "lake", date: date(4, offset: -22), title: "Still water", connection: "By the water", scene: 3),
            Memory(id: "coast", date: date(2, offset: 38), title: "Following the coast", connection: "By the water", scene: 0),
            Memory(id: "hills", date: date(2, offset: -12), title: "Beyond the hills", connection: "Open horizons", scene: 1)
        ])
    }
}

/// Small full-resolution working set; the whole chosen day gets low-cost thumbnails.
struct MediaPreloadPlan {
    let thumbnailIDs: [String]
    let fullResolutionIDs: [String]
    let videoIDs: [String]
    init(memories: [Memory], selectedIndex: Int) {
        guard memories.indices.contains(selectedIndex) else {
            thumbnailIDs = []; fullResolutionIDs = []; videoIDs = []; return
        }
        var order = [selectedIndex]
        let radius = max(selectedIndex, memories.count - 1 - selectedIndex)
        if radius > 0 {
            for distance in 1...radius {
                if selectedIndex + distance < memories.count { order.append(selectedIndex + distance) }
                if selectedIndex - distance >= 0 { order.append(selectedIndex - distance) }
            }
        }
        thumbnailIDs = order.compactMap { memories[$0].assetID }
        let nearby = order.filter { abs($0 - selectedIndex) <= 1 }
        fullResolutionIDs = nearby.filter { !memories[$0].isVideo }.compactMap { memories[$0].assetID }
        videoIDs = Array(order.filter { abs($0 - selectedIndex) <= 2 && memories[$0].isVideo }.prefix(2)).compactMap { memories[$0].assetID }
    }
}

/// Snapshot the civil day instead of reinterpreting an old Date after a timezone change.
struct LocalDayKey: Equatable {
    let era: Int
    let year: Int
    let month: Int
    let day: Int
    let timeZone: String
    init(_ date: Date, calendar: Calendar) {
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: date)
        era = parts.era ?? 0; year = parts.year ?? 0
        month = parts.month ?? 0; day = parts.day ?? 0
        timeZone = calendar.timeZone.identifier
    }
    func sameCivilDay(as other: Self) -> Bool {
        era == other.era && year == other.year && month == other.month && day == other.day
    }
}

struct LocalDayClock {
    enum Change: Equatable { case unchanged, timeZoneChanged, newDay(Date) }
    private let now: () -> Date
    private let calendar: () -> Calendar
    private var observed: LocalDayKey
    init(now: @escaping () -> Date = Date.init, calendar: @escaping () -> Calendar = { .autoupdatingCurrent }) {
        self.now = now; self.calendar = calendar
        observed = LocalDayKey(now(), calendar: calendar())
    }
    mutating func check() -> Change {
        let date = now()
        let next = LocalDayKey(date, calendar: calendar())
        let previous = observed
        observed = next
        if !next.sameCivilDay(as: previous) { return .newDay(date) }
        return next.timeZone == previous.timeZone ? .unchanged : .timeZoneChanged
    }
}

struct MemoryAge {
    let title: String
    let isAnniversary: Bool
    init(captured: Date, now: Date, calendar: Calendar = .current) {
        let start = calendar.startOfDay(for: captured)
        let end = calendar.startOfDay(for: now)
        let capturedDay = calendar.dateComponents([.month, .day], from: start)
        let currentDay = calendar.dateComponents([.month, .day], from: end)
        isAnniversary = start <= end && capturedDay.month == currentDay.month && capturedDay.day == currentDay.day
        guard start <= end else { title = "Captured"; return }
        let years = calendar.dateComponents([.year], from: start, to: end).year ?? 0
        if years > 0 {
            title = "\(years) \(years == 1 ? "year" : "years") ago"
        } else if calendar.isDate(start, inSameDayAs: end) {
            title = "Today"
        } else {
            let months = calendar.dateComponents([.month], from: start, to: end).month ?? 0
            if months > 0 { title = "\(months) \(months == 1 ? "month" : "months") ago" }
            else {
                let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
                title = days == 1 ? "Yesterday" : "\(days) days ago"
            }
        }
    }
}

/// Keeps asynchronous place results tied to the exact selected asset version.
struct RecordedPlaceSelection {
    private(set) var memory: Memory?
    private(set) var name: String?
    private var request = UUID()
    mutating func begin(_ memory: Memory) -> UUID {
        self.memory = memory; name = nil; request = UUID()
        return request
    }
    mutating func resolve(_ name: String?, request: UUID) {
        guard self.request == request else { return }
        self.name = name
    }
    func label(for memory: Memory) -> String? { self.memory == memory ? name : nil }
    static func name(neighborhood: String?, city: String?) -> String? {
        for value in [neighborhood, city] {
            if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        }
        return nil
    }
}

/// Errors/cancellation terminate requests even if Photos also marks a result degraded.
enum PhotoDeliveryOutcome: Equatable {
    case preview, complete, failure
    static func classify(hasImage: Bool, degraded: Bool, cancelled: Bool, failed: Bool) -> Self {
        if cancelled || failed { return .failure }
        if degraded { return .preview }
        return hasImage ? .complete : .failure
    }
}

/// Compare real delivered pixels with the requested display target, not callback flags alone.
enum PhotoPixelQuality {
    static func isSufficient(deliveredLongestEdge: Double, sourceLongestEdge: Int) -> Bool {
        guard deliveredLongestEdge.isFinite, deliveredLongestEdge > 0, sourceLongestEdge > 0 else { return false }
        return deliveredLongestEdge >= Double(min(3200, sourceLongestEdge)) * 0.95
    }
}

/// Relative scrubbing in a metric that blends photo spacing with equal year spans.
/// Changing scale reanchors at the current fractional photo, so it never selects by itself.
struct PhotoWheelMotion {
    static let photoPitch = 15.0
    static let yearPitch = 24.0
    let years: [Int]
    let yearStarts: [Int]
    private let yearPositions: [Double]
    private(set) var position: Double
    private(set) var scale = 0.0
    private var direction = 0.0
    private var coastVelocity = 0.0
    private var coastTime = 0.0
    private var snapsToYear = false
    var selected: Int { Int(position.rounded()) }

    init(years: [Int], selected: Int) {
        self.years = years
        position = Double(min(max(0, selected), max(0, years.count - 1)))
        let starts = years.indices.filter { $0 == 0 || years[$0] != years[$0 - 1] }
        yearStarts = starts
        var positions = [Double](repeating: 0, count: years.count)
        var origin = 0.0
        for (group, start) in starts.enumerated() {
            let end = group + 1 < starts.count ? starts[group + 1] : years.count
            // Sparse years never become slower than the precise photo wheel.
            let spacing = min(Self.photoPitch, Self.yearPitch / Double(end - start))
            for index in start..<end { positions[index] = origin + Double(index - start) * spacing }
            origin += Double(end - start) * spacing
        }
        yearPositions = positions
    }

    mutating func drag(distance: Double, velocity: Double, elapsed: Double) {
        guard distance.isFinite, velocity.isFinite, elapsed.isFinite else { return }
        coastVelocity = 0; coastTime = 0; snapsToYear = false
        let nextDirection = distance == 0 ? direction : (distance > 0 ? 1.0 : -1.0)
        if direction != 0 && direction != nextDirection { scale = 0 }
        direction = nextDirection
        let speed = abs(velocity)
        let t = min(1, max(0, (speed - 100) / 300))
        let target = t * t * (3 - 2 * t)
        // Reach full year compression within 60 ms; recover fine control sooner.
        let duration = min(0.25, max(0, elapsed))
        let slices = max(1, Int(ceil(duration * 240)))
        // Integrate the changing metric in small time slices so 60/120 Hz input
        // produces the same travel, including the moment full compression arrives.
        for _ in 0..<slices {
            let step = duration / Double(slices) * (target > scale ? (1 / 0.06) : 22)
            var nextScale = scale + min(step, max(-step, target - scale))
            if abs(nextScale - target) < 0.000001 { nextScale = target }
            if speed <= 100 { scale = 0; nextScale = 0 }
            scale = (scale + nextScale) / 2
            advance(distance / Double(slices))
            scale = nextScale
        }
    }

    mutating func end(velocity: Double, allowsMomentum: Bool) {
        snapsToYear = scale >= 0.65 && velocity.isFinite && abs(velocity) >= 180
        coastTime = 0
        coastVelocity = allowsMomentum && velocity.isFinite && abs(velocity) > 250
            ? min(600, max(-600, velocity)) : 0
        if coastVelocity == 0 { snap() }
        if !allowsMomentum { scale = 0 }
    }

    private mutating func snap() {
        if snapsToYear, let nearest = yearStarts.min(by: {
            abs(coordinate(at: $0) - offset) < abs(coordinate(at: $1) - offset)
        }) {
            position = Double(nearest)
        } else {
            position = Double(selected)
        }
        snapsToYear = false
    }

    /// A short, bounded coast, followed by expansion around the chosen photo.
    @discardableResult mutating func tick(elapsed: Double) -> Bool {
        guard elapsed.isFinite, elapsed > 0 else { return coastVelocity != 0 || scale > 0 }
        if coastVelocity != 0 {
            let dt = min(elapsed, max(0, 0.18 - coastTime))
            let decay = exp(-dt / 0.06)
            let oldPosition = position
            advance(coastVelocity * 0.06 * (1 - decay))
            coastVelocity *= decay
            coastTime += dt
            if coastTime >= 0.18 || abs(coastVelocity) < 20 || position == oldPosition {
                coastVelocity = 0
                snap()
            }
        } else {
            scale = max(0, scale - elapsed * 10)
        }
        return coastVelocity != 0 || scale > 0
    }

    mutating func stop() {
        position = Double(selected)
        scale = 0; direction = 0; coastVelocity = 0; coastTime = 0; snapsToYear = false
    }

    /// Rendering can ease toward a new scale/snap without delaying gesture input.
    func presentation(position: Double, scale: Double) -> Self {
        var result = self
        result.position = min(Double(max(0, years.count - 1)), max(0, position))
        result.scale = min(1, max(0, scale))
        return result
    }

    func coordinate(at index: Int) -> Double {
        guard years.indices.contains(index) else { return 0 }
        return Double(index) * Self.photoPitch * (1 - scale) + yearPositions[index] * scale
    }
    var offset: Double {
        let lower = Int(position)
        let upper = min(lower + 1, max(0, years.count - 1))
        return coordinate(at: lower) + (position - Double(lower)) * (coordinate(at: upper) - coordinate(at: lower))
    }
    func index(at coordinate: Double) -> Double {
        guard years.count > 1 else { return 0 }
        if coordinate <= 0 { return 0 }
        if coordinate >= self.coordinate(at: years.count - 1) { return Double(years.count - 1) }
        var low = 0, high = years.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if self.coordinate(at: mid) <= coordinate { low = mid } else { high = mid }
        }
        let start = self.coordinate(at: low)
        return Double(low) + (coordinate - start) / (self.coordinate(at: high) - start)
    }
    private mutating func advance(_ distance: Double) { position = index(at: offset + distance) }
}

struct MediaPreparationSnapshot: Equatable {
    var collectionID = UUID()
    var isReady: Bool { total > 0 && ready == total && failures == 0 && transfers == 0 && !suspended }
    var total = 0
    var ready = 0
    var previews = 0
    var cached = 0
    var cacheBytes = 0
    var failures = 0
    var transfers = 0
    var fraction = 0.0
    var suspended = false
}

extension Memory {
    /// Edits invalidate the cached representation; display format changes bump v2.
    func cacheKey(_ representation: String) -> String {
        "v2|\(assetID ?? id)|\(modificationDate?.timeIntervalSince1970 ?? date.timeIntervalSince1970)|\(representation)"
    }
}

/// Acknowledgement belongs to a collection, not an individual view or cache update.
struct PreparationNoticeDismissal {
    private var dismissedCollection: UUID?
    func isVisible(_ snapshot: MediaPreparationSnapshot) -> Bool {
        snapshot.total > 0 && (!snapshot.isReady || dismissedCollection != snapshot.collectionID)
    }
    mutating func dismiss(_ snapshot: MediaPreparationSnapshot) {
        guard snapshot.isReady else { return }
        dismissedCollection = snapshot.collectionID
    }
}


/// Media-relative coordinates survive changes in viewport dimensions.
struct MediaViewport: Equatable {
    var userAdjusted: Bool
    var scale: CGFloat = 1
    var center = CGPoint(x: 0.5, y: 0.5)
    init(scale: CGFloat = 1, center: CGPoint = CGPoint(x: 0.5, y: 0.5), userAdjusted: Bool? = nil) {
        self.scale = scale.isFinite ? max(1, scale) : 1
        self.userAdjusted = userAdjusted ?? (self.scale > 1.01)
        self.center = CGPoint(x: center.x.isFinite ? min(1, max(0, center.x)) : 0.5,
                              y: center.y.isFinite ? min(1, max(0, center.y)) : 0.5)
    }
    static func capture(scale: CGFloat, content: CGSize, viewport: CGSize, offset: CGPoint, userAdjusted: Bool? = nil) -> Self {
        guard content.width > 0, content.height > 0 else { return .init() }
        return .init(scale: scale, center: CGPoint(x: (offset.x + viewport.width / 2) / content.width,
                                                 y: (offset.y + viewport.height / 2) / content.height), userAdjusted: userAdjusted)
    }
    func offset(content: CGSize, viewport: CGSize) -> CGPoint {
        func axis(_ center: CGFloat, _ content: CGFloat, _ viewport: CGFloat) -> CGFloat {
            guard content > viewport else { return (content - viewport) / 2 }
            return min(content - viewport, max(0, center * content - viewport / 2))
        }
        return CGPoint(x: axis(center.x, content.width, viewport.width), y: axis(center.y, content.height, viewport.height))
    }
}

struct MemoryYearSection: Equatable {
    let year: Int
    let memories: [Memory]
    static func sections(_ memories: [Memory]) -> [Self] {
        let grouped = Dictionary(grouping: memories, by: \.year)
        return grouped.keys.sorted(by: >).map { year in
            Self(year: year, memories: grouped[year, default: []].sorted {
                $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date
            })
        }
    }
}

struct MemoryBrowserLayout {
    /// Keep a continuous, scrollable grid outside active system occlusions.
    /// Zero-width division regions are left to ArrangementView, not treated as holes.
    static func unobscuredRegion(bounds: CGRect, obstacles: [CGRect]) -> CGRect {
        var regions = [bounds]
        for obstacle in obstacles where !obstacle.isEmpty && !obstacle.isNull {
            regions = regions.flatMap { region -> [CGRect] in
                let cut = region.intersection(obstacle)
                guard !cut.isNull && !cut.isEmpty else { return [region] }
                return [
                    CGRect(x: region.minX, y: region.minY, width: cut.minX - region.minX, height: region.height),
                    CGRect(x: cut.maxX, y: region.minY, width: region.maxX - cut.maxX, height: region.height),
                    CGRect(x: region.minX, y: region.minY, width: region.width, height: cut.minY - region.minY),
                    CGRect(x: region.minX, y: cut.maxY, width: region.width, height: region.maxY - cut.maxY)
                ].filter { !$0.isEmpty }
            }
        }
        return regions.max { $0.width * $0.height < $1.width * $1.height } ?? .zero
    }

    static func showsContactSheet(width: CGFloat, height: CGFloat) -> Bool {
        width >= 760 && height >= 420
    }
    static func columns(width: CGFloat) -> Int {
        // Even columns allow a later reserved-region layout to divide cleanly.
        max(2, min(8, Int(width / 150) / 2 * 2))
    }
}


/// Open displays use equal rows in portrait and columns in landscape. Active folds define their own panes.
struct MemoryContextPanes {
    let media: CGRect
    let context: CGRect
    init(size: CGSize, showsContext: Bool, division: CGRect?) {
        let bounds = CGRect(origin: .zero, size: size)
        guard showsContext else { media = bounds; context = .zero; return }
        if let division, !division.isEmpty, bounds.intersects(division) {
            let cut = bounds.intersection(division)
            if cut.height > cut.width && cut.minX > 0 && cut.maxX < size.width {
                media = CGRect(x: 0, y: 0, width: cut.minX, height: size.height)
                context = CGRect(x: cut.maxX, y: 0, width: size.width - cut.maxX, height: size.height)
                return
            }
            if cut.width > cut.height && cut.minY > 0 && cut.maxY < size.height {
                media = CGRect(x: 0, y: 0, width: size.width, height: cut.minY)
                context = CGRect(x: 0, y: cut.maxY, width: size.width, height: size.height - cut.maxY)
                return
            }
        }
        if size.height > size.width {
            media = CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
            context = CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        } else {
            media = CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
            context = CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        }
    }
}

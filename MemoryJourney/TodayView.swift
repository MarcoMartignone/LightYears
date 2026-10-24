import SwiftUI
import Photos

struct TodayView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library = PhotoLibraryStore()
    @StateObject private var share = MediaShareStore()
    @State private var videoControls = VideoControlState()
    @State private var preparation = MediaPreparationState()
    @StateObject private var gridState = MemoryGridState()
    @State private var contactSheet = true
    @State private var showMapPanel = true
    @State private var wheelFrame: CGRect?
    @State private var storyHeaderTop: CGFloat?
    @State private var immersiveGrid = false
    @State private var videoScrubbing = false
    @State private var samples = MemoryCollection.sample()
    private var collection: MemoryCollection { library.usingLibrary ? library.collection : samples }
    @State private var selectedID = ""
    @State private var tapSelectionID: String?
    @State private var showDetails = false
    private var overlayOpen: Bool { showDetails }
    @State private var today = Date()
    @State private var dayClock = LocalDayClock()
    @State private var automaticDateChange = false
    @State private var controlsVisible = true
    @State private var controlsIdleTask: Task<Void, Never>?
    @State private var rulerScrolling = false
    @State private var selectionFeedback = UISelectionFeedbackGenerator()
    @State private var boundaryFeedback = UIImpactFeedbackGenerator(style: .soft)
    @State private var yearFeedback = UIImpactFeedbackGenerator(style: .medium)
    @State private var dayCache = OnThisDayCache()
    private var memories: [Memory] { dayCache.memories(in: collection, on: today) }
    private var selected: Memory? { memories.first { $0.id == selectedID } ?? memories.first }

    private var usesNativeControls: Bool {
        if #available(iOS 27.1, *) { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            GeometryReader { safeGeometry in
            ZStack {
                Color.black.ignoresSafeArea()
                if !library.usingLibrary || !library.allowed {
                    photoAccessView
                } else if let selected {
                    GeometryReader { geometry in
                        let expanded = horizontalSizeClass == .regular && geometry.size.width >= 640 && geometry.size.height >= 420
                        let showGrid = immersiveGrid
                        let gridWidth = immersiveGrid ? geometry.size.width : showGrid ? min(380, geometry.size.width * 0.34) : 0
                        let gridRegion = unobscuredGridRegion(in: geometry, bounds: CGRect(x: immersiveGrid ? 0 : geometry.size.width - gridWidth, y: 0, width: gridWidth, height: geometry.size.height))
                        ZStack(alignment: .leading) {
                    MemoryContextArrangement(showContext: expanded && showMapPanel) {
                    VStack(spacing: 0) {
                        if !usesNativeControls { CaptureMetadataHeader(memory: selected) }
                        FoldAwareMediaArrangement {
                    MemoryPager(memories: memories, selectedID: selected.id, revision: library.revision,
                                controlsVisible: controlsVisible, active: scenePhase == .active && !overlayOpen && !immersiveGrid && share.payload == nil, foreground: scenePhase == .active,
                                reduceMotion: reduceMotion,
                                videoControls: videoControls, preparation: preparation,
                                onSelect: { rulerScrolling = false; selectedID = $0 }, onRevealControls: revealControls, onToggleControls: toggleControls,
                                onTapSelection: { tapSelectionID = $0 }, scrubbing: rulerScrolling)
                        .transaction { $0.animation = nil }
                        } controls: {
                        if !usesNativeControls {
                        controls(selected, expanded: expanded)
                            .opacity(controlsVisible && !overlayOpen ? 1 : 0)
                            .allowsHitTesting(controlsVisible && !overlayOpen)
                            .accessibilityHidden(!controlsVisible || overlayOpen)
                        }
                        }
                    }
                    } context: {
                        MemoryJourneyContext(memories: memories, selected: selected,
                                             safeFrame: safeGeometry.frame(in: .global),
                                             headerTop: storyHeaderTop,
                                             controlsVisible: controlsVisible,
                                             onTracking: { rulerScrolling = $0 },
                                             onSelect: { selectedID = $0; revealControls() },
                                             onInteraction: revealControls)
                    }
                    .opacity(immersiveGrid ? 0 : 1)
                    .allowsHitTesting(!immersiveGrid)
                    .accessibilityHidden(immersiveGrid)
                    if showGrid {
                        gridPanel(expanded: expanded)
                            .frame(width: gridRegion.width, height: gridRegion.height)
                            .position(x: gridRegion.midX, y: gridRegion.midY)
                    }
                        }
                    }
                    .ignoresSafeArea(.container, edges: usesNativeControls ? .all : [])
                } else if library.isLoading {
                    ProgressView().accessibilityLabel("Finding memories")
                } else {
                    ContentUnavailableView {
                        Label("A quiet day", systemImage: "sun.horizon")
                    } description: {
                        Text(library.allowed ? "No accessible photos or videos from this day yet." : "Photo access is off. You can allow access in iPhone Settings.")
                    }
                }
            }
            .foregroundStyle(.primary)
            .toolbar(usesNativeControls && controlsVisible ? .visible : .hidden, for: .navigationBar)
            .toolbar(controlsVisible ? .visible : .hidden, for: .bottomBar)
            .toolbar {
                if #available(iOS 27.1, *), usesNativeControls, library.allowed, let selected {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { Task { await share.prepare(selected) } } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }.disabled(share.isPreparing)
                    }
                    if horizontalSizeClass == .regular {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { showMapPanel.toggle(); revealControls() } label: {
                                Label(showMapPanel ? "Photo full screen" : "Show map beside photo",
                                      systemImage: showMapPanel ? "arrow.up.left.and.arrow.down.right" : "rectangle.split.2x1")
                            }
                        }
                    }
                    if horizontalSizeClass != .regular || !showMapPanel {
                    ToolbarItem(placement: .bottomBar) {
                        NativePhotoWheel(memories: memories, selectedIndex: memories.firstIndex(where: { $0.id == selected.id }) ?? 0,
                                         isActive: !overlayOpen && !immersiveGrid && scenePhase == .active,
                                         onSelect: { selectedID = memories[$0].id },
                                         onTracking: { rulerScrolling = $0 },
                                         onFrame: { if controlsVisible { wheelFrame = $0 } })
                    }.axisBehavior(.verticalPreferred)
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if usesNativeControls, library.allowed, let selected {
                    MemoryStoryHeader(memory: selected, today: today)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .cameraGlass(20)
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { storyHeaderTop = $0 }
                        .padding(.leading, 16).padding(.top, 8)
                        .allowsHitTesting(false)
                        .opacity(controlsVisible ? 1 : 0)
                        .accessibilityHidden(!controlsVisible)
                }
            }
            .overlay(alignment: .bottom) {
                GeometryReader { geometry in
                    VStack {
                        Spacer(minLength: 0)
                        if overlayOpen {
                            InPlaceCard(title: "Photo info", mediaStatus: videoControls, close: closeCards) {
                                if let selected {
                                    if usesNativeControls && selected.isVideo {
                                        VideoControlCard(state: videoControls, isVisible: true, onInteraction: { videoScrubbing = $0 })
                                    }
                                    MomentDetails(memory: selected)
                                }
                            }
                            .frame(maxWidth: 520)
                            .frame(height: min(geometry.size.height * (textSize.isAccessibilitySize ? 0.78 : 0.60),
                                               textSize.isAccessibilitySize ? 650 : selected?.assetID == nil ? 250 : 410))
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                        }
                    }.frame(maxWidth: .infinity).padding(.horizontal, LightYearsStyle.pageInset).padding(.bottom, 8)
                }.allowsHitTesting(overlayOpen)
            }
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.88), value: showDetails)
            .sheet(item: $share.payload, onDismiss: { share.cleanUp() }) { payload in
                MediaShareSheet(url: payload.url)
            }
            .alert("Couldn’t share this moment", isPresented: Binding(get: { share.error != nil }, set: { if !$0 { share.error = nil } })) {
                Button("OK") { share.error = nil }
            } message: { Text(share.error ?? "") }
            .onChange(of: overlayOpen) { _, opened in
                UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: opened ? 0.35 : 0.22)
            }
            .onAppear {
                revealControls()
                selectionFeedback.prepare()
                boundaryFeedback.prepare()
                yearFeedback.prepare()
                synchronizeDay(refreshIfNeeded: true)
                if selectedID.isEmpty { selectedID = memories.first?.id ?? "" }
            }
            .onChange(of: selectedID) { previous, next in
                MediaNavigationTrace.event("swiftui-selection old=\(memories.firstIndex { $0.id == previous } ?? -1) new=\(memories.firstIndex { $0.id == next } ?? -1)")
                revealControls()
                if tapSelectionID == next { tapSelectionID = nil; return }
                tapSelectionID = nil
                guard let old = memories.first(where: { $0.id == previous }),
                      let new = memories.first(where: { $0.id == next }), old.id != new.id else { return }
                guard !rulerScrolling else { return }
                if old.year != new.year {
                    yearFeedback.impactOccurred(intensity: 0.6)
                    yearFeedback.prepare()
                } else {
                    selectionFeedback.selectionChanged()
                    selectionFeedback.prepare()
                }
            }
            .onDisappear { controlsIdleTask?.cancel() }
            .onChange(of: rulerScrolling) { _, _ in revealControls() }
            .onChange(of: videoScrubbing) { _, _ in revealControls() }
            .onChange(of: overlayOpen) { _, _ in revealControls() }
            .onChange(of: immersiveGrid) { _, _ in revealControls() }
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in revealControls() })
            .onChange(of: today) { previous, date in
                if !automaticDateChange && Calendar.current.component(.month, from: previous) != Calendar.current.component(.month, from: date) {
                    boundaryFeedback.impactOccurred(intensity: 0.45)
                }
                automaticDateChange = false
                library.refresh(on: date); selectedID = ""
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { revealControls(); synchronizeDay(refreshIfNeeded: true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                if scenePhase == .active { synchronizeDay() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                if scenePhase == .active { synchronizeDay() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                if scenePhase == .active { synchronizeDay() }
            }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.white)
    }

    private var photoAccessView: some View {
        ContentUnavailableView {
            Label("Your memories", systemImage: "photo.on.rectangle")
        } description: {
            switch library.status {
            case .denied:
                Text("Photo access is off. Allow access in Settings to see your memories.")
            case .restricted:
                Text("Photo access is restricted on this iPhone.")
            default:
                Text("Connect Photos to see memories from this day across the years.")
            }
        } actions: {
            if library.status == .denied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
            } else if library.status != .restricted {
                Button("Connect Photos") { Task { await library.connect(on: today) } }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
            }
        }
    }

    private func controls(_ memory: Memory, expanded: Bool) -> some View {
        let activeIndex = memories.firstIndex(where: { $0.id == memory.id }) ?? 0
        return GlassControlGroup {
            VStack(spacing: LightYearsStyle.gap) {
                MediaPreparationView(state: preparation)
                if memory.isVideo {
                    VideoControlCard(state: videoControls, isVisible: controlsVisible && !overlayOpen, onInteraction: { scrubbing in
                        videoScrubbing = scrubbing
                        revealControls()
                    })
                }
                HStack(alignment: .center, spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            if expanded { contactSheet.toggle() } else { immersiveGrid = true }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 4) {
                                    Text(String(memory.year)).monospacedDigit()
                                    Image(systemName: "square.grid.2x2").imageScale(.small)
                                }.font(.caption.weight(.semibold))
                                Text("\(activeIndex + 1) / \(memories.count)")
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(expanded && contactSheet ? "Hide year grid" : "Browse across years")
                        .accessibilityValue("\(memory.year), memory \(activeIndex + 1) of \(memories.count)")
                        .fixedSize(horizontal: true, vertical: false)
                        PhotoWheel(memories: memories, selectedIndex: activeIndex,
                                   isActive: controlsVisible && !overlayOpen && share.payload == nil && scenePhase == .active,
                                   onSelect: { index in selectedID = memories[index].id },
                                   onTracking: { tracking in
                                       rulerScrolling = tracking
                                       if tracking { controlsVisible = true }
                                   })
                            .frame(height: 44)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, textSize.isAccessibilitySize ? 8 : 6)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .cameraGlass(28)
                    Button { showDetails = true } label: {
                        Image(systemName: "info.circle").font(.system(size: 17)).frame(width: 20, height: 20)
                    }
                    .controlGlassButton()
                    .accessibilityLabel("Photo info")
                    Button {
                        selectionFeedback.selectionChanged()
                        Task { await share.prepare(memory) }
                    } label: {
                        Group {
                            if share.isPreparing { ProgressView() }
                            else { Image(systemName: "square.and.arrow.up").font(.system(size: 17)) }
                        }.frame(width: 20, height: 20)
                    }
                    .controlGlassButton()
                    .disabled(share.isPreparing)
                    .accessibilityLabel(share.isPreparing ? "Preparing share" : "Share this photo or video")
                }
            }
            .padding(.horizontal, LightYearsStyle.pageInset).padding(.bottom, 8)
            .frame(maxWidth: .infinity)
        }
    }

    private func gridPanel(expanded: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Across the years").font(.headline)
                    Text(today.formatted(.dateTime.day().month(.wide))).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if expanded {
                    Button { immersiveGrid.toggle() } label: {
                        Image(systemName: immersiveGrid ? "rectangle.lefthalf.inset.filled" : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 17, weight: .medium))
                            .frame(width: 44, height: 44)
                    }.accessibilityLabel(immersiveGrid ? "Show selected memory" : "Expand year grid")
                }
                Button {
                    if immersiveGrid { immersiveGrid = false } else { contactSheet = false }
                } label: { Image(systemName: "xmark").font(.system(size: 17, weight: .medium)).frame(width: 44, height: 44) }
                    .accessibilityLabel("Close year grid")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 6)
            MemoryYearGrid(memories: memories, selectedID: selected?.id ?? "", state: gridState, active: scenePhase == .active && !overlayOpen && share.payload == nil) { id in
                selectedID = id
                immersiveGrid = false
                revealControls()
            }
        }
        .background(.black)
        .accessibilityAction(.escape) { immersiveGrid = false; contactSheet = false }
    }

    private func closeCards() {
        showDetails = false
        revealControls()
    }
    private func synchronizeDay(refreshIfNeeded: Bool = false) {
        switch dayClock.check() {
        case .newDay(let date):
            automaticDateChange = true
            selectedID = ""
            if !library.usingLibrary { samples = .sample(today: date) }
            today = date
        case .timeZoneChanged:
            library.refresh(on: today)
        case .unchanged:
            if refreshIfNeeded { library.refreshIfNeeded(on: today) }
        }
    }

    private func toggleControls() {
        guard !overlayOpen, !videoScrubbing else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { controlsVisible.toggle() }
    }
    private func revealControls() {
        if !controlsVisible {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { controlsVisible = true }
        }
        controlsIdleTask?.cancel()
        guard !overlayOpen, !immersiveGrid, !rulerScrolling, !videoScrubbing,
              share.payload == nil, !UIAccessibility.isVoiceOverRunning else { return }
        controlsIdleTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard !Task.isCancelled, !overlayOpen, !immersiveGrid, !rulerScrolling,
                  !videoScrubbing, share.payload == nil else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { controlsVisible = false }
        }
    }

}

/// Relative wheel: deliberate drags browse photos; quick sweeps compress busy years.
private struct PhotoWheel: UIViewRepresentable {
    let memories: [Memory]
    let selectedIndex: Int
    let isActive: Bool
    var vertical = false
    let onSelect: (Int) -> Void
    let onTracking: (Bool) -> Void
    func makeUIView(context: Context) -> PhotoWheelView { PhotoWheelView() }
    func updateUIView(_ view: PhotoWheelView, context: Context) {
        view.onSelect = onSelect
        view.onTracking = onTracking
        view.configure(years: memories.map(\.year), selected: selectedIndex, active: isActive, vertical: vertical)
    }
}

private final class PhotoWheelView: UIView, UIGestureRecognizerDelegate {
    private let marks = WheelMarks()
    private let detent = UISelectionFeedbackGenerator()
    private let yearDetent = UIImpactFeedbackGenerator(style: .rigid)
    private var motion = PhotoWheelMotion(years: [], selected: 0)
    private var vertical = false
    private var moving = false
    private var lastTime = 0.0
    private var lastHaptic = 0.0
    private var displayLink: CADisplayLink?
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
    var onSelect: ((Int) -> Void)?
    var onTracking: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)
        marks.isUserInteractionEnabled = false
        marks.backgroundColor = .clear
        addSubview(marks)
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityLabel = "Photo wheel"
        accessibilityHint = "Swipe up or down for one photo. Drag slowly for photos or quickly across years."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(years: [Int], selected: Int, active: Bool, vertical: Bool = false) {
        if self.vertical != vertical {
            finish()
            self.vertical = vertical
            setNeedsLayout()
        }
        if years != motion.years {
            finish()
            // An asset refresh invalidates the gesture's old coordinate map.
            pan.isEnabled = false
            motion = PhotoWheelMotion(years: years, selected: selected)
        } else if !moving && selected != motion.selected {
            motion = PhotoWheelMotion(years: years, selected: selected)
        }
        if !active { finish() }
        pan.isEnabled = active && years.count > 1
        redraw()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        marks.transform = .identity
        marks.bounds = CGRect(origin: .zero, size: vertical ? CGSize(width: bounds.height, height: bounds.width) : bounds.size)
        marks.center = CGPoint(x: bounds.midX, y: bounds.midY)
        if vertical { marks.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        redraw()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { finish() }
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Stop a glide on touch-down, before a new pan has crossed its threshold.
        finish()
        super.touchesBegan(touches, with: event)
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let velocity = pan.velocity(in: self)
        return vertical ? abs(velocity.y) > abs(velocity.x) : abs(velocity.x) > abs(velocity.y)
    }
    private func redraw() {
        marks.update(motion, tracking: pan.state == .began || pan.state == .changed)
        accessibilityValue = motion.years.isEmpty ? "No photos" :
            "Photo \(motion.selected + 1) of \(motion.years.count), \(motion.years[motion.selected])"
    }
    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        let now = CACurrentMediaTime()
        switch gesture.state {
        case .began:
            finish()
            moving = true
            onTracking?(true)
            lastTime = now
            detent.prepare(); yearDetent.prepare()
            // Include the movement that recognized the pan, especially on a quick
            // flick. Touch-down itself still leaves the current photo anchored.
            let previous = motion.selected
            motion.drag(distance: -Double(vertical ? gesture.translation(in: self).y : gesture.translation(in: self).x),
                        velocity: -Double(vertical ? gesture.velocity(in: self).y : gesture.velocity(in: self).x), elapsed: 1.0 / 60)
            gesture.setTranslation(.zero, in: self)
            publish(previous: previous)
        case .changed, .ended:
            let previous = motion.selected
            motion.drag(distance: -Double(vertical ? gesture.translation(in: self).y : gesture.translation(in: self).x),
                        velocity: -Double(vertical ? gesture.velocity(in: self).y : gesture.velocity(in: self).x), elapsed: now - lastTime)
            gesture.setTranslation(.zero, in: self)
            lastTime = now
            publish(previous: previous)
            guard gesture.state == .ended else { return }
            let beforeRelease = motion.selected
            motion.end(velocity: -Double(vertical ? gesture.velocity(in: self).y : gesture.velocity(in: self).x),
                       allowsMomentum: !UIAccessibility.isReduceMotionEnabled)
            publish(previous: beforeRelease)
            lastTime = now
            let link = CADisplayLink(target: self, selector: #selector(glide(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            displayLink = link
            link.add(to: .main, forMode: .common)
        case .cancelled, .failed:
            finish()
        default: break
        }
    }
    @objc private func glide(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let previous = motion.selected
        let continuing = motion.tick(elapsed: now - lastTime)
        lastTime = now
        publish(previous: previous)
        if !continuing { finish() }
    }
    private func publish(previous: Int) {
        let next = motion.selected
        if next != previous && motion.years.indices.contains(next) {
            let crossedYear = motion.years[previous] != motion.years[next]
            let now = CACurrentMediaTime()
            // Never queue skipped ticks or buzz continuously while sweeping.
            if crossedYear && now - lastHaptic >= 0.05 {
                yearDetent.impactOccurred(intensity: 0.35); yearDetent.prepare()
                lastHaptic = now
            } else if motion.scale < 0.25 && now - lastHaptic >= 0.05 {
                detent.selectionChanged(); detent.prepare()
                lastHaptic = now
            }
            onSelect?(next)
        }
        redraw()
    }
    private func finish() {
        displayLink?.invalidate()
        displayLink = nil
        motion.stop()
        if moving { moving = false; onTracking?(false) }
        redraw()
    }
    override func accessibilityIncrement() { adjust(1) }
    override func accessibilityDecrement() { adjust(-1) }
    private func adjust(_ delta: Int) {
        finish()
        let previous = motion.selected
        let next = previous + delta
        guard motion.years.indices.contains(next) else { return }
        onTracking?(true)
        motion = PhotoWheelMotion(years: motion.years, selected: next)
        publish(previous: previous)
        onTracking?(false)
    }
}

private final class WheelMarks: UIView {
    private var target = PhotoWheelMotion(years: [], selected: 0)
    private var shownPosition = 0.0
    private var shownScale = 0.0
    private var tracking = false
    private var displayLink: CADisplayLink?
    private var lastFrame = 0.0
    private var motion: PhotoWheelMotion { target.presentation(position: shownPosition, scale: shownScale) }

    func update(_ motion: PhotoWheelMotion, tracking: Bool) {
        let changedLibrary = target.years != motion.years
        target = motion
        self.tracking = tracking
        if changedLibrary || window == nil || UIAccessibility.isReduceMotionEnabled {
            stopAnimation()
            shownPosition = target.position
            shownScale = target.scale
        } else {
            // Finger movement remains direct. Only spacing and the release snap
            // ease into place, without postponing photo selection or haptics.
            if tracking { shownPosition = target.position }
            if displayLink == nil && (abs(shownPosition - target.position) > 0.001 || abs(shownScale - target.scale) > 0.0001) {
                lastFrame = CACurrentMediaTime()
                let link = CADisplayLink(target: self, selector: #selector(animate(_:)))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
                displayLink = link
                link.add(to: .main, forMode: .common)
            }
        }
        setNeedsDisplay()
    }
    @objc private func animate(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let elapsed = max(0, now - lastFrame)
        lastFrame = now
        // Time-based damping is continuous when a new target arrives mid-frame.
        let positionBlend = 1 - exp(-elapsed / 0.045)
        let scaleBlend = 1 - exp(-elapsed / 0.035)
        shownPosition = tracking ? target.position : shownPosition + (target.position - shownPosition) * positionBlend
        shownScale += (target.scale - shownScale) * scaleBlend
        let rendered = motion
        let remaining = abs(rendered.offset - target.presentation(position: target.position, scale: shownScale).offset)
        if UIAccessibility.isReduceMotionEnabled || (remaining < 0.1 && abs(shownScale - target.scale) < 0.0001) {
            shownPosition = target.position
            shownScale = target.scale
            stopAnimation()
        }
        setNeedsDisplay()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopAnimation() }
    }
    private func stopAnimation() {
        displayLink?.invalidate()
        displayLink = nil
    }

    override func draw(_ rect: CGRect) {
        let motion = self.motion
        guard let context = UIGraphicsGetCurrentContext(), !motion.years.isEmpty else { return }
        let center = Double(bounds.midX)
        let first = max(0, Int(floor(motion.index(at: motion.offset - center))))
        let last = min(motion.years.count - 1, Int(ceil(motion.index(at: motion.offset + center))))
        let bottom = bounds.midY + 9
        func tick(_ index: Int, year: Bool, opacity: Double = 1) {
            let x = center + motion.coordinate(at: index) - motion.offset
            guard x >= 0, x <= Double(bounds.width) else { return }
            let distance = abs(x - center) / max(1, center)
            context.setStrokeColor(UIColor.white.withAlphaComponent(max(0.12, 0.8 - distance * 0.65) * opacity).cgColor)
            context.setLineWidth(year ? 2 : 1)
            context.move(to: CGPoint(x: x, y: Double(bottom) - (year ? 18 : 8)))
            context.addLine(to: CGPoint(x: x, y: Double(bottom)))
            context.strokePath()
        }
        for (group, start) in motion.yearStarts.enumerated() {
            let end = group + 1 < motion.yearStarts.count ? motion.yearStarts[group + 1] : motion.years.count
            guard end > first, start <= last else { continue }
            tick(start, year: true)
            if end - start > 1 {
                let spacing = motion.coordinate(at: start + 1) - motion.coordinate(at: start)
                // Fade alternating ticks before thinning them, so scale changes
                // do not suddenly replace the visible set of marks.
                let stride = Int(pow(2, floor(log2(max(1, 4 / spacing)))))
                let fade = min(1, max(0, (spacing * Double(stride) - 2) / 2))
                let opacity = fade * fade * (3 - 2 * fade)
                var index = start + max(1, Int(ceil(Double(first - start) / Double(stride)))) * stride
                while index < end && index <= last {
                    tick(index, year: false, opacity: (index - start) % (stride * 2) == 0 ? 1 : opacity)
                    index += stride
                }
            }
        }
        context.setStrokeColor(UIColor.systemYellow.cgColor)
        context.setLineWidth(3)
        context.move(to: CGPoint(x: center, y: Double(bounds.midY - 11)))
        context.addLine(to: CGPoint(x: center, y: Double(bounds.midY + 11)))
        context.strokePath()
    }
}


private struct MediaPreparationView: View {
    let state: MediaPreparationState
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    var body: some View {
        let value = state.snapshot
        if state.notice.isVisible(value) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: value.isReady ? "checkmark.circle" : value.transfers > 0 ? "icloud.and.arrow.down" : "arrow.down.circle")
                        .foregroundStyle(.secondary)
                    Text(value.suspended ? "Downloads paused" : value.isReady ? "Ready to browse" : "\(value.transfers > 0 ? "Downloading" : "Preparing") \(value.ready) of \(value.total)")
                        .font(.caption.weight(.medium).monospacedDigit())
                    Spacer(minLength: 4)
                    if value.failures > 0 {
                        Button("Retry \(value.failures)") { state.retry?() }
                            .font(.caption.weight(.semibold))
                            .accessibilityLabel("Retry unavailable memories")
                    }
                    Text(ByteCountFormatter.string(fromByteCount: Int64(value.cacheBytes), countStyle: .file))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityLabel("\(ByteCountFormatter.string(fromByteCount: Int64(value.cacheBytes), countStyle: .file)) cached on this device")
                }
                if value.ready < value.total {
                    ProgressView(value: value.fraction)
                        .tint(.white.opacity(0.8))
                        .accessibilityLabel("Preparing today's memories")
                        .accessibilityValue("\(value.ready) of \(value.total) ready")
                }
                Text("\(value.previews) previews ready · \(value.cached) of \(value.total) saved in cache")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .cameraGlass(20)
            .contentShape(RoundedRectangle(cornerRadius: 20))
            .onTapGesture { state.dismissReady() }
            .gesture(DragGesture(minimumDistance: 16).onEnded { gesture in
                if max(abs(gesture.translation.width), abs(gesture.translation.height)) >= 24 {
                    state.dismissReady()
                }
            }, including: value.isReady ? .all : .none)
            .accessibilityHint(value.isReady ? "Tap or swipe to dismiss" : "")
            .accessibilityAction(.escape) { state.dismissReady() }
            .task(id: value.isReady ? value.collectionID : nil) {
                guard value.isReady else { return }
                do { try await Task.sleep(for: .seconds(voiceOver ? 8 : 3)) } catch { return }
                guard !Task.isCancelled, state.snapshot.collectionID == value.collectionID else { return }
                state.dismissReady()
            }
        }
    }
}


/// The system moves controls away from media at a fold, without replacing the pager.
private struct FoldAwareMediaArrangement<Media: View, Controls: View>: View {
    @ViewBuilder var media: () -> Media
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        if #available(iOS 27.1, *) {
            ArrangementView {
                controls().overlayArrangementEdge(.bottom)
            } secondary: {
                media()
            }
            .arrangementViewStyle(.overlay)
        } else {
            ZStack(alignment: .bottom) {
                media()
                controls()
            }
        }
    }
}

private func unobscuredGridRegion(in geometry: GeometryProxy, bounds: CGRect) -> CGRect {
    if #available(iOS 27.1, *) {
        // Frames already include system margins. Physical coordinates match position().
        let obstacles = geometry.reservedRegions(kind: .occlusion, layoutDirectionBehavior: .fixed)
            .filter(\.isActive).map(\.frame)
        return MemoryBrowserLayout.unobscuredRegion(bounds: bounds, obstacles: obstacles)
    }
    return bounds
}


@available(iOS 27.1, *)
private struct NativeAxisControl<Content: View>: View {
    @Environment(\.toolbarVerticalEdge) private var edge
    let length: CGFloat
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .frame(width: length, height: 44)
            .rotationEffect(.degrees(edge == nil ? 0 : 90))
            .frame(width: edge == nil ? length : 44, height: edge == nil ? 44 : length)
    }
}

@available(iOS 27.1, *)
private struct NativeVideoActions: View {
    @ObservedObject var state: VideoControlState
    @Environment(\.toolbarVerticalEdge) private var edge
    var body: some View {
        let layout = edge == nil ? AnyLayout(HStackLayout()) : AnyLayout(VStackLayout())
        layout {
            Button { state.togglePlayback() } label: {
                Label(state.playing ? "Pause" : "Play", systemImage: state.playing ? "pause.fill" : "play.fill")
            }
            Button { state.toggleSound() } label: {
                Label(state.muted ? "Unmute" : "Mute", systemImage: state.muted ? "speaker.slash" : "speaker.wave.2")
            }
            NativeAxisControl(length: 90) {
                Slider(value: Binding(get: { state.position }, set: { state.seek(to: $0) }), in: 0...max(1, state.duration)) { editing in
                    if editing { state.beginSeek() } else { state.endSeek() }
                }.accessibilityLabel("Video position")
            }
        }.labelStyle(.iconOnly).disabled(!state.ready)
    }
}

private struct NativePreparationIndicator: View {
    let state: MediaPreparationState
    var body: some View {
        Button { if state.snapshot.failures > 0 { state.retry?() } } label: {
            ZStack {
                Circle().stroke(.secondary.opacity(0.3), lineWidth: 2)
                Circle().trim(from: 0, to: state.snapshot.fraction)
                    .stroke(.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if state.snapshot.failures > 0 { Image(systemName: "exclamationmark").font(.caption2) }
            }.frame(width: 18, height: 18).frame(width: 44, height: 44)
        }
        .accessibilityLabel(state.snapshot.failures > 0 ? "Retry unavailable memories" : "Preparing memories")
        .accessibilityValue("\(state.snapshot.ready) of \(state.snapshot.total) ready")
    }
}


@available(iOS 27.1, *)
private struct NativePhotoWheel: View {
    @Environment(\.toolbarVerticalEdge) private var edge
    let memories: [Memory]
    let selectedIndex: Int
    let isActive: Bool
    let onSelect: (Int) -> Void
    let onTracking: (Bool) -> Void
    let onFrame: (CGRect?) -> Void
    var body: some View {
        let layout = edge == nil ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 8))
        layout {
            if memories.indices.contains(selectedIndex) {
                Text(String(memories[selectedIndex].year))
                    .font(.caption.bold().monospacedDigit()).fixedSize()
            }
            MemoryTimelineSlider(memories: memories, selectedIndex: selectedIndex,
                                 isActive: isActive, vertical: edge != nil,
                                 onSelect: onSelect, onTracking: onTracking)
        }
            .fixedSize()
            .padding(.vertical, edge == nil ? 0 : 12)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                if edge != nil && frame.width > 0 && frame.height > 0 { onFrame(frame) }
                else if edge == nil { onFrame(nil) }
            }
    }
}


/// One stable media subtree across compact, expanded and partially folded layouts.
private struct MemoryContextArrangement<Media: View, Context: View>: View {
    let showContext: Bool
    @ViewBuilder var media: () -> Media
    @ViewBuilder var context: () -> Context
    var body: some View {
        GeometryReader { geometry in
            let panes = MemoryContextPanes(size: geometry.size, showsContext: showContext, division: division(in: geometry))
            ZStack(alignment: .topLeading) {
                media().frame(width: panes.media.width, height: panes.media.height)
                    .position(x: panes.media.midX, y: panes.media.midY)
                if showContext {
                    context().frame(width: panes.context.width, height: panes.context.height)
                        .position(x: panes.context.midX, y: panes.context.midY)
                }
            }
        }
    }
    private func division(in geometry: GeometryProxy) -> CGRect? {
        if #available(iOS 27.1, *) {
            return geometry.reservedRegions(kind: .division, layoutDirectionBehavior: .fixed).first?.frame
        }
        return nil
    }
}


struct MemoryTimelineSlider: View {
    let memories: [Memory]
    let selectedIndex: Int
    let isActive: Bool
    let vertical: Bool
    let onSelect: (Int) -> Void
    let onTracking: (Bool) -> Void
    var body: some View {
        Slider(value: Binding(get: { Double(selectedIndex) }, set: { value in
            let next = min(max(Int(value.rounded()), 0), memories.count - 1)
            guard memories.indices.contains(next), next != selectedIndex else { return }
            if memories[next].year != memories[selectedIndex].year {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            } else { UISelectionFeedbackGenerator().selectionChanged() }
            onSelect(next)
        }), in: 0...Double(max(1, memories.count - 1)), step: 1, onEditingChanged: onTracking)
            .labelsHidden()
            .accessibilityLabel("Browse memories")
            .accessibilityValue(memories.indices.contains(selectedIndex) ? memories[selectedIndex].date.formatted(date: .abbreviated, time: .shortened) : "No memories")
            .disabled(!isActive || memories.count < 2)
            .frame(width: 160, height: 44)
            .rotationEffect(.degrees(vertical ? 90 : 0))
            .frame(width: vertical ? 44 : 160, height: vertical ? 160 : 44)
    }
}

"""Build an isolated, synthetic simulator fixture; never opens the user's Photos library."""
from pathlib import Path
import shutil, tempfile, re
src = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='lightyears-adaptive-qa-'))
for name in ['MemoryJourney', 'MemoryJourney.xcodeproj']:
    shutil.copytree(src / name, root / name)
# Expose internals only in the throwaway fixture to exercise real UIKit controllers.
for name in ['MediaPager.swift', 'MemoryYearGrid.swift', 'MomentDetails.swift']:
    p = root / 'MemoryJourney' / name
    p.write_text(re.sub(r'\bprivate(?:\(set\))?\s+', '', p.read_text()))
p = root / 'MemoryJourney/TodayView.swift'
s = p.read_text().replace('library.usingLibrary ? library.collection : samples', 'samples')
s = s.replace('if !library.usingLibrary || !library.allowed {', 'if false {')
s = s.replace('MemoryCollection.sample()', 'MemoryCollection.qaSamples()')
s = s.replace('@State private var immersiveGrid = false', '@State private var immersiveGrid = ProcessInfo.processInfo.arguments.contains("--grid")')
s = s.replace('library.refresh(on: date); selectedID = ""', 'selectedID = ""')
s = s.replace('library.refresh(on: today)', '()').replace('library.refreshIfNeeded(on: today)', '()')
s = s.replace('samples = .sample(today: date)', 'samples = .qaSamples()')
p.write_text(s)
p = root / 'MemoryJourney/MemoryJourneyApp.swift'
s = p.read_text().replace('WindowGroup { TodayView() }', 'WindowGroup { TodayView().task { await runAdaptiveNativeChecks() } }')
s += r'''
import MapKit

extension MemoryCollection {
    static func qaSamples() -> MemoryCollection {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        return MemoryCollection(memories: (0..<48).map { index in
            let date = calendar.date(byAdding: .year, value: -(index / 8 + 1), to: start)!.addingTimeInterval(Double(index % 8) * 600)
            return Memory(id: "sample-\(index)", date: date, title: "Sample artwork", connection: "Sample", scene: index % 4)
        })
    }
}

@MainActor
final class NavigationTestTap: UITapGestureRecognizer {
    var testPoint = CGPoint.zero
    override var state: UIGestureRecognizer.State { get { .ended } set {} }
    override func location(in view: UIView?) -> CGPoint { testPoint }
}

@MainActor
func runAdaptiveNativeChecks() async {
    var results: [String] = []
    func check(_ passed: Bool, _ label: String) { results.append("\(passed ? "PASS" : "FAIL"): \(label)") }
    func pause(_ milliseconds: Int = 80) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
    let memories = MemoryCollection.qaSamples().onThisDay(Date())
    let pager = MemoryPagerController()
    let controls = VideoControlState()
    pager.videoControls = controls
    pager.loadViewIfNeeded()
    pager.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
    pager.update(memories, selectedID: memories[0].id, revision: 0, controlsVisible: true, active: true, foreground: true, reduceMotion: true)
    pager.view.setNeedsLayout(); pager.view.layoutIfNeeded()
    await pause()
    if let cell = pager.pages.visibleCells.first as? MediaPageCell {
        cell.restore(MediaViewport(scale: 3, center: CGPoint(x: 0.5, y: 0.5)))
        cell.layoutIfNeeded()
        let start = cell.viewport
        check(abs(start.scale - 3) < 0.01, "Native pinch state can be restored at 3x")
        var stable = true
        for i in 0..<24 {
            pager.view.frame.size = i.isMultiple(of: 2) ? CGSize(width: 780, height: 620) : CGSize(width: 390, height: 700)
            pager.view.setNeedsLayout(); pager.view.layoutIfNeeded()
            await pause(20)
            guard let current = pager.pages.visibleCells.first as? MediaPageCell else { stable = false; continue }
            stable = stable && current.memory?.id == memories[0].id && abs(current.viewport.scale - start.scale) < 0.01
                && abs(current.viewport.center.x - start.center.x) < 0.02 && abs(current.viewport.center.y - start.center.y) < 0.02
        }
        check(stable, "24 native pager resizes retain asset, zoom and focal point")
        check(!pager.pages.isScrollEnabled, "Zoomed media retains pan ownership after resize")
        cell.resetZoom()
        check(pager.pages.isScrollEnabled, "Resetting zoom restores paging")
        check(cell.zoom.contentSize.width >= cell.zoom.bounds.width - 1 && cell.zoom.contentSize.height >= cell.zoom.bounds.height - 1, "Initial media fills the pane")
        check(abs(cell.surface.frame.width / cell.surface.frame.height - 430.0 / 930.0) < 0.001, "Fill preserves the original media aspect ratio")
        _ = cell.accessibleFit()
        check(abs(cell.zoom.zoomScale - 1) < 0.01 && cell.zoom.userHasZoomed, "Fit reveals the whole image and records user intent")
        pager.view.frame.size = CGSize(width: 780, height: 620)
        pager.view.setNeedsLayout(); pager.view.layoutIfNeeded()
        await pause()
        check(abs(cell.zoom.zoomScale - 1) < 0.01, "User-selected fit survives unfolding")
        pager.collectionView(pager.pages, didEndDisplaying: cell, forItemAt: IndexPath(item: 0, section: 0))
        check(cell.isActive, "Late end-display callback keeps the visible selected photo tappable")
        let sharpFormat = UIGraphicsImageRendererFormat(); sharpFormat.scale = 1
        let sharp = UIGraphicsImageRenderer(size: CGSize(width: 1400, height: 3028), format: sharpFormat).image { context in UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1400, height: 3028)) }
        pager.pipeline.storeFullImage(sharp, for: memories[0].id)
        pager.pipeline.onUpdate?(memories[0].id)
        check(cell.surface.imageView.image === sharp, "Full-quality delivery replaces the preview after unfolding")
    } else { check(false, "Native pager supplies visible media") }

    // Simulate rapid taps before SwiftUI acknowledges them, while only previews are available.
    var delivered: [String] = []
    pager.onSelect = { delivered.append($0) }
    for index in 1...6 {
        guard let cell = pager.pages.visibleCells.compactMap({ $0 as? MediaPageCell }).first(where: { $0.memory?.id == memories[index - 1].id }) else {
            check(false, "Rapid navigation supplies the selected cell"); break
        }
        cell.pauseForScroll() // A late display/scroll callback must not disable navigation.
        cell.onAdvance?()
        pager.update(memories, selectedID: memories[0].id, revision: 0, controlsVisible: index.isMultiple(of: 2), active: true, foreground: true, reduceMotion: true)
    }
    check(delivered == Array(memories[1...6]).map(\.id), "Six rapid preview-only taps advance exactly once without replaying old photos")
    pager.update(memories, selectedID: memories[3].id, revision: 0, controlsVisible: true, active: true, foreground: true, reduceMotion: true)
    check(pager.selectedIndex == 6, "Delayed intermediate selection acknowledgement cannot rewind navigation")
    pager.update(memories, selectedID: memories[6].id, revision: 0, controlsVisible: true, active: true, foreground: true, reduceMotion: true)
    check(pager.selectedIndex == 6 && pager.pendingSelections.isEmpty, "Latest selection acknowledgement settles the navigation queue")
    pager.update(memories, selectedID: memories[2].id, revision: 0, controlsVisible: true, active: true, foreground: true, reduceMotion: true)
    check(pager.selectedIndex == 2, "Explicit year-wheel selection still replaces the current photo")
    pager.pages.layoutIfNeeded()
    let selectedCell = pager.pages.visibleCells.compactMap { $0 as? MediaPageCell }.first { $0.memory?.id == memories[2].id }
    selectedCell?.onPrevious?()
    check(pager.selectedIndex == 1, "Backward tap remains available after wheel navigation")

    let navigationTap = NavigationTestTap()
    navigationTap.testPoint = CGPoint(x: pager.view.bounds.width * 0.8, y: pager.view.bounds.height * 0.5)
    let tapStart = pager.selectedIndex
    var tapSequence = true
    for offset in 1...20 {
        for case let cell as MediaPageCell in pager.pages.visibleCells { cell.pauseForScroll() }
        pager.handleNavigationTap(navigationTap)
        tapSequence = tapSequence && pager.selectedIndex == tapStart + offset
        pager.update(memories, selectedID: memories[pager.selectedIndex].id, revision: 0, controlsVisible: offset.isMultiple(of: 2), active: true, foreground: true, reduceMotion: true)
    }
    check(tapSequence, "Twenty pager tap events advance through inactive/loading cells without stalling")
    navigationTap.testPoint.x = pager.view.bounds.width * 0.2
    for _ in 0..<20 { pager.handleNavigationTap(navigationTap) }
    check(pager.selectedIndex == tapStart, "Twenty backward pager tap events return to the same photo")
    check(pager.navigationTap.view === pager.view, "Navigation recognizer belongs to the persistent pager, not a reusable cell")
    check(pager.gestureRecognizer(pager.navigationTap, shouldRecognizeSimultaneouslyWith: UIPanGestureRecognizer()), "Reveal gesture cannot exclusively suppress navigation taps")

    pager.update(memories, selectedID: memories[0].id, revision: 0, controlsVisible: true, active: true, foreground: true, reduceMotion: true)
    navigationTap.testPoint.x = pager.view.bounds.width * 0.8
    var yearsRemainReachable = true
    for index in 1...min(32, memories.count - 1) {
        // Reproduce lagging viewport callbacks plus PhotoKit refreshes before selection acknowledgement.
        pager.pages.setContentOffset(.zero, animated: false)
        pager.scrollViewDidEndScrollingAnimation(pager.pages)
        pager.handleNavigationTap(navigationTap)
        pager.update(memories, selectedID: memories[0].id, revision: index, controlsVisible: true, active: true, foreground: true, reduceMotion: true)
        yearsRemainReachable = yearsRemainReachable && pager.selectedIndex == index
    }
    check(yearsRemainReachable, "32 forward taps cross four year boundaries despite stale offsets and library refreshes")
    check(memories[pager.selectedIndex].year < memories[0].year, "Tap sequence reaches earlier years instead of repeating the first year")

    pager.update(memories, selectedID: memories[pager.selectedIndex].id, revision: 40, controlsVisible: true, active: true, foreground: true, reduceMotion: true)
    pager.view.frame.size = CGSize(width: 475.6666666667, height: 657.3333333333)
    pager.view.setNeedsLayout(); pager.view.layoutIfNeeded()
    var fractionalPages = true
    for index in memories.indices {
        pager.update(memories, selectedID: memories[index].id, revision: 40, controlsVisible: true, active: true, foreground: true, reduceMotion: true)
        pager.pages.layoutIfNeeded()
        let attributes = pager.pages.layoutAttributesForItem(at: IndexPath(item: index, section: 0))
        fractionalPages = fractionalPages && abs((attributes?.frame.minX ?? -1) - CGFloat(index) * pager.pages.bounds.width) < 0.01
            && abs(pager.pages.contentOffset.x - CGFloat(index) * pager.pages.bounds.width) < 0.01
            && pager.pages.visibleCells.compactMap { ($0 as? MediaPageCell)?.memory?.id }.contains(memories[index].id)
    }
    check(fractionalPages, "Every fractional-width page keeps the expected frame, offset and visible asset")
    check(pager.pages.visibleCells.count <= 2, "Pager never lays out dozens of cells in a viewport")

    let testMap = MKMapView(frame: CGRect(x: 0, y: 0, width: 500, height: 700))
    let points = [MemoryMapPoint(memory: memories[0], latitude: 51.5, longitude: -0.12), MemoryMapPoint(memory: memories[1], latitude: 37.77, longitude: -122.42)]
    let overviewMap = StableMemoryMap(points: points, selectedID: memories[0].id, overview: true, focusRevision: 0, bottomOcclusion: 220, trailingOcclusion: 24, reduceMotion: true, onSelect: { _ in })
    let mapCoordinator = overviewMap.makeCoordinator()
    overviewMap.apply(testMap, coordinator: mapCoordinator)
    let overviewWidth = testMap.visibleMapRect.width
    let closeMap = StableMemoryMap(points: [points[0]], selectedID: memories[0].id, overview: false, focusRevision: 1, bottomOcclusion: 220, trailingOcclusion: 24, reduceMotion: true, onSelect: { _ in })
    closeMap.apply(testMap, coordinator: mapCoordinator)
    check(testMap.visibleMapRect.width < overviewWidth / 10, "Selected location restores close-up after a wide all-locations overview")
    testMap.setRegion(MKCoordinateRegion(center: points[1].coordinate, latitudinalMeters: 10000, longitudinalMeters: 10000), animated: false)
    let recentered = StableMemoryMap(points: [points[0]], selectedID: memories[0].id, overview: false, focusRevision: 2, bottomOcclusion: 220, trailingOcclusion: 24, reduceMotion: true, onSelect: { _ in })
    recentered.apply(testMap, coordinator: mapCoordinator)
    check(testMap.visibleMapRect.contains(MKMapPoint(points[0].coordinate)) && !testMap.visibleMapRect.contains(MKMapPoint(points[1].coordinate)), "Explicit selected-location focus overrides manual map panning")
    let animatedOverview = StableMemoryMap(points: points, selectedID: memories[0].id, overview: true, focusRevision: 3, bottomOcclusion: 220, trailingOcclusion: 24, reduceMotion: false, onSelect: { _ in })
    animatedOverview.apply(testMap, coordinator: mapCoordinator)
    let interruptedReturn = StableMemoryMap(points: [points[0]], selectedID: memories[0].id, overview: false, focusRevision: 4, bottomOcclusion: 220, trailingOcclusion: 24, reduceMotion: false, onSelect: { _ in })
    interruptedReturn.apply(testMap, coordinator: mapCoordinator)
    check(testMap.visibleMapRect.width < overviewWidth / 10 && testMap.visibleMapRect.contains(MKMapPoint(points[0].coordinate)), "Selected location interrupts an unfinished animated overview and restores the close-up")
    if let cell = pager.pages.visibleCells.first as? MediaPageCell {
        cell.layoutIfNeeded()
        check(abs(cell.spinner.center.x - cell.bounds.midX) < 0.01 && abs(cell.spinner.center.y - cell.bounds.midY) < 0.01, "Loading indicator is centered in the media pane")
        check(!cell.spinner.isAnimating, "Visible preview does not show a loading spinner")
    }

    let state = MemoryGridState()
    let grid = MemoryYearGridController(state: state)
    grid.loadViewIfNeeded(); grid.view.frame = CGRect(x: 0, y: 0, width: 340, height: 600)
    grid.configure(memories, selectedID: memories[0].id)
    grid.view.setNeedsLayout(); grid.view.layoutIfNeeded()
    await pause()
    grid.grid.setContentOffset(CGPoint(x: 0, y: 900), animated: false)
    grid.saveAnchor()
    let anchor = state.anchorID
    check(anchor != nil && anchor != memories[0].id, "Grid records an asset anchor after scrolling")
    grid.view.frame.size = CGSize(width: 900, height: 650)
    grid.view.setNeedsLayout(); grid.view.layoutIfNeeded()
    check(state.anchorID == anchor, "Grid keeps its asset anchor when columns reflow")
    check(grid.grid.visibleCells.count < memories.count, "Grid virtualizes offscreen memories")
    grid.thumbnails.stop()
    let reopened = MemoryYearGridController(state: state)
    reopened.loadViewIfNeeded(); reopened.view.frame = CGRect(x: 0, y: 0, width: 340, height: 600)
    reopened.configure(memories, selectedID: memories[0].id)
    reopened.view.setNeedsLayout(); reopened.view.layoutIfNeeded()
    check(state.anchorID == anchor && reopened.grid.contentOffset.y > 0, "Closing and reopening restores grid scroll position")
    grid.setActive(false); reopened.setActive(false)
    check(grid.thumbnails.requests.isEmpty && reopened.thumbnails.requests.isEmpty, "Inactive grids cancel thumbnail work")

    do {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { await pause(10) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            memset(CVPixelBufferGetBaseAddress(buffer!), Int32(frame * 7), CVPixelBufferGetDataSize(buffer!))
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(frame), timescale: 10))
        }
        input.markAsFinished(); await writer.finishWriting()
        let movie = Memory(id: "synthetic-video", date: Date(), title: "Synthetic clip", connection: "", scene: 0, isVideo: true)
        pager.update([movie], selectedID: movie.id, revision: 1, controlsVisible: true, active: true, foreground: true, reduceMotion: true)
        let player = AVPlayer(url: url)
        pager.pipeline.players[movie.id] = player
        pager.refreshVisible()
        await pause(800)
        check(player.currentItem?.status == .readyToPlay, "Synthetic video is ready for playback checks")
        check(!pager.pipeline.muted && !player.isMuted, "Video defaults to unmuted playback")
        check(AVAudioSession.sharedInstance().category == .ambient && AVAudioSession.sharedInstance().mode == .default,
              "Video uses the system Silent-mode-respecting ambient audio session")
        pager.update([movie], selectedID: movie.id, revision: 1, controlsVisible: true, active: true, foreground: true, reduceMotion: true, scrubbing: true)
        await pause(80)
        check(player.rate == 0, "Timeline scrubbing pauses the selected video without changing playback intent")
        pager.update([movie], selectedID: movie.id, revision: 1, controlsVisible: true, active: true, foreground: true, reduceMotion: true, scrubbing: false)
        await pause(150)
        check(pager.pipeline.players[movie.id] === player && player.rate > 0, "Releasing the timeline resumes the same selected video")
        pager.scrollViewWillBeginDragging(pager.pages)
        pager.scrollViewDidEndDragging(pager.pages, willDecelerate: false)
        await pause(100)
        check(player.rate > 0, "A swipe ending without deceleration resumes selected video immediately")
        pager.pipeline.toggleSound()
        let before = player.currentTime().seconds
        for i in 0..<8 {
            pager.view.frame.size = i.isMultiple(of: 2) ? CGSize(width: 800, height: 600) : CGSize(width: 390, height: 700)
            pager.view.setNeedsLayout(); pager.view.layoutIfNeeded()
            await pause(30)
        }
        check(pager.pipeline.players[movie.id] === player && player.currentTime().seconds >= before && player.isMuted,
              "Resize preserves player identity, advancing time and mute choice")
        check(pager.pipeline.muted, "Manual mute remains selected across resizing")
        pager.pipeline.toggleSound()
        check(!player.isMuted && AVAudioSession.sharedInstance().category == .ambient,
              "Manual unmute retains Silent-mode-respecting audio policy")
        pager.pipeline.togglePlayback(movie.id)
        let pausedAt = player.currentTime().seconds
        pager.view.frame.size = CGSize(width: 700, height: 650); pager.view.setNeedsLayout(); pager.view.layoutIfNeeded()
        await pause(150)
        check(abs(player.currentTime().seconds - pausedAt) < 0.1 && !pager.pipeline.wantsPlayback(movie.id), "Paused intent survives resizing")
        pager.pipeline.togglePlayback(movie.id)
        pager.update([movie], selectedID: movie.id, revision: 1, controlsVisible: true, active: false, foreground: true, reduceMotion: true)
        await pause(100)
        let interruptedAt = player.currentTime().seconds
        await pause(120)
        check(player.rate == 0 && abs(player.currentTime().seconds - interruptedAt) < 0.1, "Immersive grid pauses hidden video")
        pager.update([movie], selectedID: movie.id, revision: 1, controlsVisible: true, active: true, foreground: true, reduceMotion: true)
        await pause(150)
        check(player.currentTime().seconds > interruptedAt && pager.pipeline.players[movie.id] === player, "Returning resumes the same player")
        controls.beginSeek(); controls.seek(to: 1.5)
        pager.view.frame.size = CGSize(width: 800, height: 600); pager.view.setNeedsLayout(); pager.view.layoutIfNeeded()
        await pause(100)
        check(controls.seeking && abs(controls.position - 1.5) < 0.01, "Resizing during a scrub retains the pending seek")
        controls.endSeek(); await pause(120)
        check(!controls.seeking && player.currentTime().seconds >= 1.5, "Scrub completion resumes playback after resizing")
        controls.beginSeek(); controls.seek(to: 2.85); controls.endSeek()
        await pause(650)
        check(player.currentTime().seconds < 2 && player.rate > 0, "Selected video still loops after resize and seeking")
        pager.pipeline.toggleSound()
        let secondMovie = Memory(id: "second-video", date: Date(), title: "Second clip", connection: "", scene: 0, isVideo: true)
        pager.update([movie, secondMovie], selectedID: secondMovie.id, revision: 2, controlsVisible: true, active: true, foreground: true, reduceMotion: true)
        pager.pipeline.nearbyVideos.insert(secondMovie.id)
        pager.pipeline.makePlayer(AVURLAsset(url: url), id: secondMovie.id)
        let nextPlayer = pager.pipeline.players[secondMovie.id]!
        pager.view.setNeedsLayout(); pager.view.layoutIfNeeded()
        pager.refreshVisible()
        check(pager.pipeline.muted && nextPlayer.isMuted, "Manual mute survives navigation and player replacement")
        pager.pipeline.toggleSound()
        check(!nextPlayer.isMuted && !pager.pipeline.muted, "Manual unmute applies to the newly selected video")
        pager.pipeline.shutdown()
        try? FileManager.default.removeItem(at: url)
    } catch { check(false, "Synthetic video fixture: \(error)") }
    let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("adaptive-results.txt")
    try? results.joined(separator: "\n").write(to: destination, atomically: true, encoding: .utf8)
}
'''
p.write_text(s)
print(root)

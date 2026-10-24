from pathlib import Path
import shutil,subprocess,tempfile
src=Path(__file__).resolve().parents[1]
root=Path(tempfile.mkdtemp(prefix='lightyears-quality-qa-'))
probe=r'''
    static func runQualityRegression() async -> String {
        let pipeline = DayMediaPipeline()
        let a = Memory(id: "qa-a", date: Date(), title: "", connection: "", scene: 0, assetID: "qa-a")
        let b = Memory(id: "qa-b", date: Date(), title: "", connection: "", scene: 0, assetID: "qa-b")
        pipeline.memories = [a, b]
        pipeline.nearbyPhotos = [a.id, b.id]
        func picture(_ side: CGFloat) -> UIImage {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { c in
                UIColor.systemBlue.setFill(); c.fill(CGRect(x: 0, y: 0, width: side, height: side))
                UIColor.white.setStroke(); c.cgContext.setLineWidth(1)
                for x in stride(from: CGFloat(0), to: side, by: 8) { c.cgContext.move(to: CGPoint(x: x, y: 0)); c.cgContext.addLine(to: CGPoint(x: x, y: side)) }
                c.cgContext.strokePath()
            }
        }
        let sharp = picture(1200), preview = picture(40)
        var results: [String] = []
        func check(_ value: Bool, _ name: String) { results.append("\(value ? "PASS" : "FAIL"): \(name)") }
        pipeline.previews.setObject(preview, forKey: a.id as NSString)
        pipeline.fullImages.setObject(sharp, forKey: a.id as NSString)
        check(pipeline.image(for: a) === sharp, "initial full-quality image")
        pipeline.fullImages.removeAllObjects()
        check(pipeline.image(for: a) === sharp, "selected image survives NSCache eviction and late preview refresh")
        pipeline.prioritize(1)
        check(pipeline.image(for: b) == nil, "selection does not reuse another photo")
        pipeline.previews.setObject(preview, forKey: b.id as NSString)
        check(pipeline.image(for: b) === preview, "preview shown while final delivery waits")
        try? await Task.sleep(for: .milliseconds(250))
        pipeline.fullImages.setObject(sharp, forKey: b.id as NSString)
        check(pipeline.image(for: b) === sharp, "delayed final delivery upgrades the preview")
        pipeline.memoryWarning()
        check(pipeline.image(for: b) === sharp, "selected image survives memory-pressure cache clearing")
        var rapidPassed = true
        for index in 0..<100 {
            let selected = index % 2 == 0 ? a : b
            pipeline.prioritize(index % 2)
            pipeline.previews.setObject(preview, forKey: selected.id as NSString)
            pipeline.fullImages.setObject(sharp, forKey: selected.id as NSString)
            _ = pipeline.image(for: selected)
            pipeline.fullImages.removeAllObjects()
            rapidPassed = rapidPassed && pipeline.image(for: selected) === sharp
        }
        check(rapidPassed, "100 rapid selection/eviction/late-refresh cycles stay sharp")
        let report = results.joined(separator: "\n")
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("quality-results.txt")
        try? report.write(to: path, atomically: true, encoding: .utf8)
        return report
    }
'''
for variant in ['before','after']:
 dest=root/variant;dest.mkdir(exist_ok=True)
 shutil.copytree(src/'MemoryJourney',dest/'MemoryJourney',dirs_exist_ok=True)
 shutil.copytree(src/'MemoryJourney.xcodeproj',dest/'MemoryJourney.xcodeproj',dirs_exist_ok=True)
 p=dest/'MemoryJourney/MediaPager.swift'
 s=p.read_text() if variant=='after' else subprocess.check_output(['git','show','863bbb9:MemoryJourney/MediaPager.swift'],cwd=src).decode()
 s=s.replace('    private static func cost(_ image: UIImage) -> Int {',probe+'\n    private static func cost(_ image: UIImage) -> Int {')
 p.write_text(s)
 p=dest/'MemoryJourney/MemoryJourneyApp.swift';s=p.read_text().replace('WindowGroup { TodayView() }','WindowGroup { QualityReportView() }');s+='''\nstruct QualityReportView: View {
 @State private var report = "Running synthetic image quality checks…"
 var body: some View { ScrollView { Text(report).padding() }.task { report = await DayMediaPipeline.runQualityRegression() } }
}\n''';p.write_text(s)

print(root)

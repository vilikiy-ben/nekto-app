#if DEBUG
import AppKit
import QuartzCore

/// Замер прокрутки редактора без рук: `-NektoScrollBench <файл отчёта>`.
///
/// Через 1 с после открытия документа редактор прокручивается кадр за кадром по экранным кадрам (`CADisplayLink`)
/// со скоростью быстрого свайпа (1800 pt/с) до конца документа и обратно до середины, где и останавливается —
/// снимок окна после замера показывает, всё ли нарисовано. Каждый кадр: сдвиг и `displayIfNeeded` —
/// раскладка и рисование, которые иначе пришлись бы на тот же кадр. В отчёт — сколько стоил кадр
/// (среднее, p95, худший), сколько кадров не уложились в 8 и 16 мс и сколько экранных кадров пропущено.
@MainActor
final class ScrollBench: NSObject {
    private static var running: ScrollBench?

    static func startIfRequested(on scroll: NSScrollView) {
        guard running == nil, let path = UserDefaults.standard.string(forKey: Brand.key("ScrollBench")) else { return }
        let bench = ScrollBench(scroll: scroll, report: URL(fileURLWithPath: path))
        running = bench
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { bench.start() }
    }

    private weak var scroll: NSScrollView?
    private let report: URL
    private var link: CADisplayLink?
    private var costs: [Double] = []
    private var intervals: [Double] = []
    private var last: CFTimeInterval = 0
    private var direction: CGFloat = 1
    private let speed: CGFloat = 1800

    private init(scroll: NSScrollView, report: URL) {
        self.scroll = scroll
        self.report = report
    }

    private func start() {
        guard let scroll else { return }
        let link = scroll.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let scroll, let doc = scroll.documentView else { return finish() }
        let now = link.timestamp
        let frame = link.targetTimestamp - link.timestamp
        if last > 0 { intervals.append((now - last) / max(frame, 0.001)) }
        last = now
        let clip = scroll.contentView
        let maxY = max(0, doc.frame.height - clip.bounds.height)
        var y = clip.bounds.origin.y + direction * speed * CGFloat(frame)
        if direction > 0, y >= maxY { y = maxY; direction = -1 }
        if direction < 0, y <= maxY / 2 { y = maxY / 2; direction = 0 }
        let t0 = CACurrentMediaTime()
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(clip)
        scroll.displayIfNeeded()
        costs.append((CACurrentMediaTime() - t0) * 1000)
        if direction == 0 { finish() }
    }

    private func finish() {
        link?.invalidate()
        link = nil
        let sorted = costs.sorted()
        func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        let mean = costs.isEmpty ? 0 : costs.reduce(0, +) / Double(costs.count)
        let height = scroll?.documentView?.frame.height ?? 0
        let lines = [
            "кадров: \(costs.count), высота документа: \(Int(height)) pt",
            String(format: "стоимость кадра, мс: среднее %.1f, p50 %.1f, p95 %.1f, худший %.1f", mean, pct(0.5), pct(0.95), sorted.last ?? 0),
            "дольше 8 мс: \(costs.filter { $0 > 8 }.count), дольше 16 мс: \(costs.filter { $0 > 16 }.count)",
            "пропущено экранных кадров: \(intervals.reduce(0) { $0 + max(0, Int(($1 - 1).rounded())) })",
        ]
        try? (lines.joined(separator: "\n") + "\n").write(to: report, atomically: true, encoding: .utf8)
        Self.running = nil
    }
}
#endif

import AppKit
import SwiftUI
import WebKit

/// Что показать на панели рисунка: сцена и её состояние (у монолита — доля готовности).
struct SceneSpec: Equatable {
    var id: String
    var progress: Double?

    static let door = SceneSpec(id: "b-door")
    static let drop = SceneSpec(id: "b-drop")
    static let folder = SceneSpec(id: "b-folder")
    /// До установки — пунктирный силуэт (`progress` 0).
    static let monolithReady = SceneSpec(id: "b-monolith", progress: 0)

    /// Во время установки: слоёв столько, сколько десятков процентов готово (`Installer.overall`).
    /// Доля округляется до десятых, как в самой сцене (`Math.round(progress * 10)`), поэтому страница получает
    /// новое состояние только когда ложится слой, и меняет его растворением. Не меньше 0,01 — иначе сцена покажет
    /// «до установки»; не больше 0,9 — десятый слой ложится уже на шаге «Готово».
    static func monolith(installed overall: Double) -> SceneSpec {
        let tenths = min(max((overall * 10).rounded() / 10, 0.01), 0.9)
        return SceneSpec(id: "b-monolith", progress: tenths)
    }
}

/// Сцена онбординга — JS-сцены пером (`App/Onboarding/`) на `<canvas>` в `WKWebView`.
///
/// - Страница `Onboarding/app/scene.html` лежит в бандле (копирует `scripts/embed-onboarding.sh` из `App/Onboarding/`).
///   Отдаёт её `SceneFiles` по своей схеме `nekto-scene://scene/…`, а не `loadFileURL`: страница — ES-модули, а модули
///   с file:// WebKit не грузит (у file:// нет источника, импорт считается запросом к чужому, проверено в WKWebView).
///   Схема отдаёт только файлы из папки `Onboarding` бандла. Сети нет: политика CSP страницы разрешает лишь скрипты
///   той же схемы, а переходы на любую другую схему отменяются здесь.
/// - Тема — по окну приложения (`colorScheme` окружения: настройка «Оформление», а не тема системы), как у `AppIconArt`.
/// - «Уменьшить движение» — сцена стоит на кадре 0.
/// - Окно не на экране (свёрнуто, закрыто другим окном, приложение скрыто) — кадры не рисуются вовсе.
/// - До первого кадра вид прозрачен (`drawsBackground` выключен, страница без фона): белой вспышки нет.
///   Не `alphaValue = 0`: невидимому виду WebKit не даёт кадров (`requestAnimationFrame` стоит), и первый кадр
///   приходил через секунды. Смену сцен растворяет сама страница.
/// - Вид не принимает ни щелчков, ни фокуса: панель тянет окно, как фон. Для VoiceOver его нет.
struct SceneView: NSViewRepresentable {
    let spec: SceneSpec
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> SceneHost { SceneHost() }

    func updateNSView(_ host: SceneHost, context: Context) {
        host.show(spec, dark: colorScheme == .dark, still: reduceMotion || DebugScenario.reduceMotion)
    }

    static func dismantleNSView(_ host: SceneHost, coordinator: ()) { host.tearDown() }
}

/// Контейнер веб-вида: скругление панели, перетаскивание окна, пауза вне экрана, обмен со страницей.
@MainActor
final class SceneHost: NSView, WKNavigationDelegate {
    /// Потолок частоты кадров. Движения медленные (циклы 6–10 с), на 60 кадрах они так же плавны, а работы вдвое меньше,
    /// чем на 120 Гц экрана.
    static let frameRate = 60

    private var webView: WKWebView?
    private let root = Bundle.main.resourceURL?.appendingPathComponent("Onboarding", isDirectory: true)
    private static let page = URL(string: "\(SceneFiles.scheme)://scene/app/scene.html")!
    private var loaded = false
    private var config: [String: Any] = [:]
    private var sent = ""
    private var observers: [NSObjectProtocol] = []

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Radius.card
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        setAccessibilityElement(false)
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func load() {
        guard let root else { return }
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("app/scene.html").path) else { return }
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(SceneFiles(root: root), forURLScheme: SceneFiles.scheme)
        // Ничего не пишется на диск: ни кеша, ни хранилищ сайта.
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(SceneMessages(host: self), name: "scene")
        let web = PassiveWebView(frame: bounds, configuration: configuration)
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")   // прозрачный фон до первого кадра
        web.underPageBackgroundColor = .clear
        web.navigationDelegate = self
        web.setAccessibilityElement(false)
        addSubview(web)
        webView = web
        web.load(URLRequest(url: Self.page))
        if DebugDefaults.flag("SceneLog") { logStats() }
    }

    /// `-NektoSceneLog YES`: раз в 2 с — сколько кадров нарисовала страница, видна ли она и что на ней.
    /// По разнице кадров видно, что сцена идёт на экране и стоит, когда окно закрыто другими.
    private func logStats() {
        Task { @MainActor [weak self] in
            while let web = self?.webView {
                let js = "JSON.stringify(Object.assign(nekto.stats(), { visibility: document.visibilityState }))"
                let stats = (try? await web.evaluateJavaScript(js)) as? String ?? "—"
                let visible = self?.window?.occlusionState.contains(.visible) == true
                NSLog("Сцена: окно %@, страница %@", visible ? "на экране" : "закрыто", stats)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func show(_ spec: SceneSpec, dark: Bool, still: Bool) {
        config["scene"] = spec.id
        config["state"] = spec.progress.map { ["progress": $0] } ?? NSNull()
        config["theme"] = dark ? "dark" : "light"
        config["still"] = still
        config["fps"] = DebugDefaults.integer("SceneFPS") ?? Self.frameRate
        push()
    }

    func tearDown() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        guard let web = webView else { return }
        web.configuration.userContentController.removeScriptMessageHandler(forName: "scene")
        web.navigationDelegate = nil
        web.stopLoading()
        web.removeFromSuperview()
        webView = nil
    }

    // MARK: Страница

    fileprivate func receive(_ body: Any) {
        guard let type = (body as? [String: Any])?["type"] as? String else { return }
        switch type {
        case "loaded":
            loaded = true
            sent = ""
            push()
        default: break   // `shown` — первый кадр на экране; страница проявляется сама
        }
    }

    private func push() {
        config["playing"] = onScreen
        guard loaded, let web = webView,
              let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8), json != sent else { return }
        sent = json
        web.evaluateJavaScript("window.nekto && nekto.set(\(json))", completionHandler: nil)
    }

    // MARK: Вне экрана — без кадров

    private var onScreen: Bool {
        guard let window else { return false }
        return window.occlusionState.contains(.visible) && !window.isMiniaturized
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        if let window {
            let center = NotificationCenter.default
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.push() }
                })
            }
        }
        push()
    }

    // MARK: Мышь и фокус

    /// Щелчки до веб-вида не доходят: ни выделения, ни контекстного меню «Перезагрузить». Панель тянет окно.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override var mouseDownCanMoveWindow: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }

    // MARK: WKNavigationDelegate

    /// Страница может открыть только себя: никаких переходов на другие схемы и адреса.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.scheme == SceneFiles.scheme ? .allow : .cancel
    }

    /// Процесс страницы упал (память, система) — грузим заново, сцена вернётся с текущим состоянием.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded = false
        webView.load(URLRequest(url: Self.page))
    }
}

/// Файлы сцен для веб-вида по схеме `nekto-scene://scene/<путь>` — только из папки `Onboarding` бандла.
/// Путь, выходящий за папку (`..`), и всё, чего там нет, — ошибка «файла нет».
@MainActor
private final class SceneFiles: NSObject, WKURLSchemeHandler {
    static let scheme = "nekto-scene"
    private let root: URL
    init(root: URL) { self.root = root.standardizedFileURL }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        let file = root.appendingPathComponent(String(url.path.drop { $0 == "/" })).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        let type = switch file.pathExtension {
        case "js", "mjs": "text/javascript"
        case "html": "text/html"
        default: "application/octet-stream"
        }
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": "\(type); charset=utf-8", "Content-Length": "\(data.count)"])!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Веб-вид только показывает: не становится первым ответчиком и не участвует в обходе Tab.
private final class PassiveWebView: WKWebView {
    override var acceptsFirstResponder: Bool { false }
    override var canBecomeKeyView: Bool { false }
}

/// Посредник сообщений страницы: `WKUserContentController` держит обработчик сильной ссылкой,
/// а хозяин вида должен освободиться вместе с онбордингом.
@MainActor
private final class SceneMessages: NSObject, WKScriptMessageHandler {
    weak var host: SceneHost?
    init(host: SceneHost) { self.host = host }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        host?.receive(message.body)
    }
}

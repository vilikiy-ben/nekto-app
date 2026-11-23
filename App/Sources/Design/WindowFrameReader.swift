import AppKit
import SwiftUI

extension View {
    /// Сообщает рамку этого вида в координатах окна (начало — левый край окна, x вправо).
    /// Нужна там, где систему не попросить поставить вид куда надо, но можно узнать, куда она его поставила, —
    /// например, элемент панели инструментов.
    func onWindowFrameChange(_ action: @escaping (CGRect) -> Void) -> some View {
        background(WindowFrameReader(action: action))
    }
}

private struct WindowFrameReader: NSViewRepresentable {
    let action: (CGRect) -> Void

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.report = action
        return view
    }

    func updateNSView(_ view: ReportingView, context: Context) {
        view.report = action
        view.reportIfChanged()
    }

    /// Прозрачный, щелчки проходят насквозь; сообщает рамку после каждой раскладки и только когда она изменилась.
    /// Элемент может сдвинуться, не меняя размера (панель инструментов переставила элементы) — тогда `layout()`
    /// не вызывается, поэтому следим и за рамками предков, и за размером окна.
    final class ReportingView: NSView {
        var report: ((CGRect) -> Void)?
        private var last: CGRect?
        private var observers: [NSObjectProtocol] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            reportIfChanged()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            guard let window else { return }
            let center = NotificationCenter.default
            var ancestor = superview
            while let view = ancestor {
                view.postsFrameChangedNotifications = true
                observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reportIfChanged() }
                })
                ancestor = view.superview
            }
            observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportIfChanged() }
            })
            reportIfChanged()
        }
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            reportIfChanged()
        }

        func reportIfChanged() {
            guard let window else { return }
            let frame = convert(bounds, to: nil)   // окно: начало слева снизу
            let rect = CGRect(x: frame.minX, y: window.frame.height - frame.maxY, width: frame.width, height: frame.height)
            guard rect != last else { return }
            last = rect
            // Не посреди обновления представлений.
            DispatchQueue.main.async { [report] in report?(rect) }
        }
    }
}

extension View {
    /// Сообщает, где окно рисует кнопки «закрыть / свернуть / развернуть»: их общую рамку в координатах окна
    /// (начало — левый верхний угол). В полноэкранном режиме кнопок на месте нет — тогда `.zero`.
    /// Нужна видам, которые заходят под полосу заголовка (`.hiddenTitleBar`) и должны её обойти.
    func onWindowControlsChange(_ action: @escaping (CGRect) -> Void) -> some View {
        background(WindowControlsReader(action: action))
    }
}

private struct WindowControlsReader: NSViewRepresentable {
    let action: (CGRect) -> Void

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.report = action
        return view
    }

    func updateNSView(_ view: ReportingView, context: Context) {
        view.report = action
        view.reportIfChanged()
    }

    /// Пересчитывает рамку при смене окна, его размера и полноэкранного режима.
    final class ReportingView: NSView {
        var report: ((CGRect) -> Void)?
        private var last: CGRect?
        private var observers: [NSObjectProtocol] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            guard let window else { return }
            let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reportIfChanged() }
                })
            }
            reportIfChanged()
        }

        override func layout() {
            super.layout()
            reportIfChanged()
        }

        func reportIfChanged() {
            guard let window else { return }
            var rect = CGRect.zero
            if !window.styleMask.contains(.fullScreen) {
                let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
                for type in buttons {
                    guard let button = window.standardWindowButton(type), !button.isHidden, let host = button.superview else { continue }
                    let f = host.convert(button.frame, to: nil)   // окно: начало слева снизу
                    let r = CGRect(x: f.minX, y: window.frame.height - f.maxY, width: f.width, height: f.height)
                    rect = rect == .zero ? r : rect.union(r)
                }
            }
            guard rect != last else { return }
            last = rect
            DispatchQueue.main.async { [report] in report?(rect) }
        }
    }
}

/// Окно, в котором стоит вид. Слабая ссылка: окно живёт своей жизнью, вид его только находит.
@MainActor
final class HostWindow {
    weak var window: NSWindow?
}

extension View {
    /// Запоминает окно этого вида в `host` — чтобы лист (`NSAlert.beginSheetModal`) встал именно на него,
    /// а не на то, что сейчас ключевое: им бывает «О программе» или окно поповера.
    func hostWindow(_ host: HostWindow) -> some View {
        background(HostWindowReader(host: host))
    }
}

private struct HostWindowReader: NSViewRepresentable {
    let host: HostWindow

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.host = host
        return view
    }

    func updateNSView(_ view: ReportingView, context: Context) { view.host = host }

    final class ReportingView: NSView {
        var host: HostWindow? { didSet { host?.window = window } }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            host?.window = window
        }
    }
}

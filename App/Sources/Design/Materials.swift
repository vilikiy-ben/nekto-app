import AppKit
import SwiftUI

/// Матовое стекло боковой панели: сквозь неё размыто видно то, что лежит позади окна, как в Finder.
///
/// По документации AppKit (`NSVisualEffectView`): материал `.sidebar` — «для фона боковой панели окна»,
/// `blendingMode = .behindWindow` смешивает и размывает содержимое позади окна (рабочий стол, другие окна),
/// `state = .followsWindowActiveState` — в неактивном окне стекло гаснет, как у системных панелей.
/// «Уменьшить прозрачность» и тёмную тему система учитывает сама.
///
/// Почему не Liquid Glass: в macOS 26 стеклянная «плавающая» боковая панель есть только у системной
/// разделённой панели (`NavigationSplitView` / `NSSplitViewController`). Совет WWDC25 убрать материал
/// `.sidebar` относится к ней: там он закрывает стекло. Боковая панель Nekto своя, ей нужен этот материал.
struct SidebarGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

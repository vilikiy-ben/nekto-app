import SwiftUI
import UniformTypeIdentifiers

/// Каркас рабочего окна: история слева, лента или главный экран по центру, «Скрыто» справа.
///
/// Верхняя полоса — системная панель инструментов без фона: «светофор» стоит по её центру,
/// а кнопки панелей и стрелки ‹ › — её элементы (так клики гарантированно доходят до них).
/// На macOS 26+ система даёт кнопкам стеклянный круг, на macOS 15 — рисуем свой.
struct ShellView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("SidebarWidth") private var sidebarWidth: Double = Metrics.sidebarDefault
    @State private var dropTargeted = false
    @State private var host = HostWindow()

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            if model.showSidebar {
                Sidebar()
                    .frame(width: sidebarWidth)
                    .overlay(alignment: .trailing) { ResizeHandle(width: $sidebarWidth, range: 210...380) }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Rectangle().fill(Ink.line).frame(width: 1).transition(.opacity)
            }
            main
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                .background(Ink.canvas)
            if model.showInspector, model.inspectorAvailable, let p = model.current, let job = model.readerJob {
                Rectangle().fill(Ink.line).frame(width: 1)
                InspectorView(processing: p, job: job)
                    .frame(width: Metrics.inspectorDefault)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            model.layoutWidth = width
            model.fitPanels()
            if NSApp.windows.allSatisfy({ !$0.inLiveResize }) { model.titleEpoch += 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification)) { _ in model.titleEpoch += 1 }
        .onChange(of: sidebarWidth, initial: true) { _, w in model.sidebarWidth = w }
        .onChange(of: model.place) { model.fitPanels() }
        .animation(.snappy(duration: 0.25), value: model.showSidebar)
        .animation(.snappy(duration: 0.25), value: model.showInspector)
        .ignoresSafeArea()
        .toolbar { toolbar }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onDrop(of: [.fileURL, .plainText, .utf8PlainText], isTargeted: $dropTargeted) { handleDrop($0) }
        .overlay { if dropTargeted { DropVeil().allowsHitTesting(false) } }
        .onPasteCommand(of: [.fileURL, .plainText, .utf8PlainText]) { _ in model.pasteFromClipboard() }
        .hostWindow(host)
        .onChange(of: model.confirmDelete?.id) { _, id in
            guard id != nil, let p = model.confirmDelete else { return }
            model.confirmDelete = nil
            DeleteConfirmation.present(for: p, in: host.window ?? NSApp.keyWindow) { model.delete(p, includingFiles: $0) }
        }
    }

    @ViewBuilder private var main: some View {
        ZStack(alignment: .top) {
            switch model.place {
            case .home:
                HomeView(dropTargeted: dropTargeted)
            case .settings:
                SettingsView()
            case .processing:
                if let p = model.current { FeedView(processing: p).id(p.id) }
            case .reader:
                if let p = model.current, let job = model.readerJob { ReaderView(job: job, processing: p) }
            }
            TitleFade()
                .allowsHitTesting(false)
                .zIndex(2)
        }
    }

    // MARK: Панель инструментов

    /// Все элементы без системной подложки: значки панелей плоские, как в референсе.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem(placement: .navigation) { LeadingControls(sidebarWidth: sidebarWidth) }.sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .principal) { Breadcrumbs().id(model.titleEpoch) }.sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .automatic) { InspectorToggle() }.sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { LeadingControls(sidebarWidth: sidebarWidth) }
            ToolbarItem(placement: .principal) { Breadcrumbs().id(model.titleEpoch) }
            ToolbarItem(placement: .automatic) { InspectorToggle() }
        }
    }

    // MARK: Перетаскивание

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.composer.attach([url]); model.composer.focusRequest += 1 } }
                }
            } else if p.canLoadObject(ofClass: String.self) {
                handled = true
                _ = p.loadObject(ofClass: String.self) { text, _ in
                    if let text { Task { @MainActor in model.composer.insert(text); model.composer.focusRequest += 1 } }
                }
            }
        }
        return handled
    }

}

/// Подложка верхней полосы: лента уходит под неё и растворяется, а не наезжает на заголовок.
private struct TitleFade: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.current != nil || model.place == .settings {
            VStack(spacing: 0) {
                Ink.canvas.frame(height: Metrics.topBar - 6)
                LinearGradient(colors: [Ink.canvas, Ink.canvas.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 22)
            }
        }
    }
}

/// Название обработки и, в редакторе, документа — по центру своей области (лента, редактор, настройки).
/// Название обработки в редакторе ведёт обратно в ленту.
///
/// Система ставит центральный элемент панели инструментов по центру окна, а читается заголовок над своей
/// областью. Если элемент шире, чем место между кнопками, система сдвигает его и вытесняет кнопки (так однажды
/// пропадал значок «Скрыто», а заголовок уезжал на 100 pt). Поэтому ширина элемента задаётся явно — всё место
/// между кнопками слева и справа (их края меряются, `onWindowFrameChange`): встать он может только туда.
/// Где он встал, тоже меряется, и внутри него текст ставится так, чтобы его центр совпал с центром области.
/// Не помещается полный путь — остаётся имя документа.
private struct Breadcrumbs: View {
    @Environment(AppModel.self) private var model
    @State private var hover = false
    /// Где система поставила элемент, в координатах окна.
    @State private var placed: CGRect = .zero

    var body: some View {
        let window = model.layoutWidth
        // Кнопки слева разъезжаются вместе с боковой панелью (анимация): берём больший из измеренного и целевого
        // края — элемент сужается сразу и расширяется только по ходу анимации, на кнопки не заходит ни в один кадр.
        let leading = max(model.toolbarLeading ?? Metrics.sidebarDefault, model.showSidebar ? model.sidebarWidth : 0) + Space.l
        // Правый край — значок «Скрыто», где он есть. Последнюю мерку помним: если значок на миг вытеснило,
        // сброс мерки расширил бы заголовок ещё больше, и значок бы уже не вернулся.
        // Мерка не может быть правее окна: после сужения окна она могла остаться от прежней ширины.
        let trailing = (model.inspectorAvailable ? min(model.toolbarTrailing ?? window - 48, window - 48) : window - Space.s) - Space.l
        // Где элемент встал на самом деле, известно точнее оценки по кнопкам слева: от этого места и считаем.
        let start = placed.width > 0 ? max(leading, placed.minX) : leading
        let width = max(0, trailing - start)
        let origin = placed.width > 0 ? placed.minX : leading
        let center = min(max(areaCenter - origin, 0), width)   // центр области внутри элемента
        let room = 2 * min(center, width - center)
        ZStack(alignment: Alignment(horizontal: .titleCenter, vertical: .center)) {
            Color.clear.frame(width: width, height: 1)
                .alignmentGuide(.titleCenter) { _ in center }
            title
                .frame(maxWidth: max(0, min(520, room)))
                .alignmentGuide(.titleCenter) { $0[HorizontalAlignment.center] }
        }
        // Нижней границы ширины нет: окно сузилось — система сжимает элемент, а не убирает его в «»» панели.
        // Убранный туда элемент вне окна, его место больше не меряется, и заголовок с «Скрыто» не возвращались
        // (так было, когда окно при запуске на миг открывалось во всю ширину экрана, а потом сужалось).
        .frame(minWidth: 0, idealWidth: width, maxWidth: width)
        .onWindowFrameChange { placed = $0 }
    }

    @ViewBuilder private var title: some View {
        Group {
            if model.place == .settings {
                Text("Настройки").font(Typo.callout.weight(.semibold)).foregroundStyle(Ink.text)
            } else if let p = model.current {
                if let job = model.readerJob {
                    // Полный путь, если он помещается по центру редактора; иначе только документ — назад ведут ‹ и Esc.
                    // Обрезать название многоточием хуже, чем убрать его целиком.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Space.xs) {
                            Button { model.closeReader() } label: {
                                Text(p.title).font(Typo.callout.weight(.medium))
                                    .foregroundStyle(hover ? Ink.text : Ink.text2)
                                    .padding(.horizontal, Space.xs + 2).frame(height: Size.compact - 4)
                                    .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(hover ? Ink.selected : .clear))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { hover = $0 }
                            // Подложка при наведении выходит за текст влево: по центру стоит сам текст, а не подложка.
                            .padding(.leading, -(Space.xs + 2))
                            .accessibilityHint("Вернуться к обработке")
                            Glyph(kind: .chevronRight, size: 10, weight: 1.8).foregroundStyle(Ink.text3)
                            documentTitle(job)
                        }
                        documentTitle(job)
                    }
                } else {
                    Text(p.title).font(Typo.callout.weight(.semibold)).foregroundStyle(Ink.text)
                }
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
    }

    private func documentTitle(_ job: Job) -> some View {
        Text(job.name).font(Typo.callout.weight(.semibold)).foregroundStyle(Ink.text)
    }

    /// Центр средней области в координатах окна: между боковой панелью и «Скрыто».
    private var areaCenter: CGFloat {
        let left = model.showSidebar ? model.sidebarWidth + 1 : 0
        let right = model.showInspector && model.inspectorAvailable ? Metrics.inspectorDefault + 1 : 0
        return left + (model.layoutWidth - left - right) / 2
    }
}

extension HorizontalAlignment {
    /// Центр заголовка окна: по нему текст встаёт над центром своей области.
    private enum TitleCenter: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[HorizontalAlignment.center] }
    }
    fileprivate static let titleCenter = HorizontalAlignment(TitleCenter.self)
}

/// Переключатель боковой панели и стрелки ‹ ›. Стрелки стоят у правого края боковой панели.
/// Переключатель боковой панели и стрелки ‹ ›. Стрелки стоят у правого края боковой панели.
///
/// Заголовок сюда не кладётся: элемент панели инструментов, который меняет ширину вместе с заголовком,
/// macOS то центрирует в прежнем размере, то целиком уводит в меню «»» — и пропадают кнопки.
/// Заголовок — отдельный элемент по центру (`principal`), его ширину система ограничивает сама.
private struct LeadingControls: View {
    @Environment(AppModel.self) private var model
    let sidebarWidth: Double

    var body: some View {
        HStack(spacing: 0) {
            PanelToggle(glyph: .sidebarLeft, name: model.showSidebar ? "Скрыть боковую панель" : "Показать боковую панель") {
                model.toggleSidebar()
            }
            Color.clear.frame(width: model.showSidebar ? max(Space.s, sidebarWidth - 196) : Space.s, height: 1)
            NavArrows()
        }
        .animation(.snappy(duration: 0.25), value: model.showSidebar)
        .onWindowFrameChange { model.toolbarLeading = $0.maxX }
    }
}

private struct InspectorToggle: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if model.inspectorAvailable {
            PanelToggle(glyph: .sidebarRight, name: model.showInspector ? "Скрыть панель «Скрыто»" : "Показать панель «Скрыто»") {
                model.toggleInspector()
            }
            .onWindowFrameChange { model.toolbarTrailing = $0.minX }
        }
    }
}

/// Плоский значок панели: без круга, при наведении мягкая подложка.
/// Название — `iconName`: значок без подписи, а сочетание клавиш показано в меню «Вид».
private struct PanelToggle: View {
    let glyph: GlyphKind
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Glyph(kind: glyph, size: 19, weight: 1.45) }
            .buttonStyle(IconButtonStyle(size: 30, tint: Ink.text2))
            .iconName(name)
    }
}

private struct NavArrows: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 2) {
            Button(action: model.goBack) { Glyph(kind: .chevronLeft, size: 16, weight: 1.6) }
                .buttonStyle(IconButtonStyle(size: 28, tint: Ink.text2))
                .disabled(!model.canGoBack)
                .iconName("Назад")
            Button(action: model.goForward) { Glyph(kind: .chevronRight, size: 16, weight: 1.6) }
                .buttonStyle(IconButtonStyle(size: 28, tint: Ink.text2))
                .disabled(!model.canGoForward)
                .iconName("Вперёд")
        }
    }
}

/// Захват края боковой панели: тянется, курсор — двунаправленная стрелка.
private struct ResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var start: Double?

    var body: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .offset(x: 4)
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { g in
                        if start == nil { start = width }
                        width = min(max((start ?? width) + g.translation.width, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in start = nil }
            )
    }
}

/// Покрывало при перетаскивании файла в окно.
private struct DropVeil: View {
    var body: some View {
        ZStack {
            Ink.accent.opacity(0.06)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Ink.accent.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(14)
        }
        .ignoresSafeArea()
    }
}

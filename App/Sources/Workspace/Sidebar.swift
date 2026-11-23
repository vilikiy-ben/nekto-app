import AppKit
import SwiftUI

/// Боковая панель: история обработок по рабочим папкам, как список чатов по проектам.
///
/// Сверху «Новая обработка», ниже папки. Каждую можно свернуть; «+» у заголовка добавляет
/// ещё одну папку. Внизу состояние модели и настройки.
struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: Metrics.topBar)  // под «светофор» и кнопки панели
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    SidebarRow(shortcut: "⌘N", action: model.newProcessing) {
                        Glyph(kind: .compose, size: 18, weight: 1.55).foregroundStyle(Ink.text)
                        Text("Новая обработка").foregroundStyle(Ink.text)
                        Spacer(minLength: 4)
                    }

                    SectionHeader()
                        .padding(.top, Space.l)

                    ForEach(model.folders.list, id: \.self) { root in
                        FolderSection(root: root)
                    }
                }
                .padding(.horizontal, Space.s + 2)
                .padding(.bottom, Space.l)
            }
            .scrollIndicators(.never)
            EngineStatus()
            SettingsRow()
                .padding(.horizontal, Space.s + 2)
                .padding(.bottom, Space.s + 2)
        }
        .background(SidebarGlass().ignoresSafeArea())
    }
}

/// Строка боковой панели: скруглённая подложка при наведении и выборе.
///
/// Сочетание клавиш проявляется в самой строке при наведении, а не всплывающей подсказкой:
/// подсказка повторяла бы подпись строки (HIG: не повторять название элемента).
private struct SidebarRow<Content: View>: View {
    var selected = false
    var shortcut: String? = nil
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s + 2) {
                content()
                if let shortcut {
                    Text(shortcut).font(Typo.caption).foregroundStyle(Ink.text3)
                        .opacity(hover ? 1 : 0)
                        .accessibilityHidden(true)
                }
            }
                .font(Typo.body)
                .padding(.horizontal, Space.s + 2)
                .frame(height: Size.row + 2)
                .background(RowBackground(selected: selected, hover: hover))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// «Папки» и «+» справа: добавить ещё одну рабочую папку.
private struct SectionHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.xs) {
            Text("Папки").font(Typo.caption.weight(.semibold)).foregroundStyle(Ink.text2)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: model.chooseFolder) { Glyph(kind: .plus, size: 15, weight: 1.6) }
                .buttonStyle(IconButtonStyle(size: 26, tint: Ink.text2))
                .accessibilityLabel("Добавить папку")
        }
        .padding(.leading, Space.s + 2).padding(.trailing, Space.xs)
        .frame(height: Size.compact)
    }
}

/// Строка с действиями — папка или обработка. Одна на обе, поэтому у них одинаковые наведение, кнопки и меню.
///
/// - Подсветка строки — выбор или наведение на любую её часть, включая кнопки, и пока открыто её меню.
///   Наведение считается на всей строке сразу (`onHover` у общего контейнера), а не у каждой части отдельно:
///   иначе курсор на «…» гасил строку под ней.
/// - Справа при наведении проявляются кнопки: необязательная своя (`extra`) и «…». Они лежат поверх строки;
///   сколько места им нужно, строка узнаёт из `SidebarItemControls` и решает сама — растворить под ними
///   название или держать место всегда.
/// - Правый щелчок и «Действия» VoiceOver — те же пункты, что у «…» (`RowAction`).
private struct SidebarItem<Content: View>: View {
    var selected = false
    var extra: RowExtraButton? = nil
    /// Для VoiceOver — у самой строки, а не у контейнера: иначе подпись досталась бы и «…».
    let label: String
    var value = ""
    var hint = ""
    let moreLabel: String
    let actions: [RowAction]
    let action: () -> Void
    @ViewBuilder let content: (SidebarItemControls) -> Content
    @State private var hover = false
    @State private var menuOpen = false
    @State private var moreHover = false

    private var controlsVisible: Bool { hover || menuOpen || moreHover }

    var body: some View {
        let controls = SidebarItemControls(visible: controlsVisible, width: controlsWidth)
        ZStack(alignment: .trailing) {
            Button(action: action) {
                content(controls)
                    .frame(maxWidth: .infinity, minHeight: Size.row, maxHeight: Size.row, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityHint(hint)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .rowAccessibilityActions(actions)

            HStack(spacing: Space.xs) {
                if let extra {
                    Button(action: extra.action) { Glyph(kind: extra.glyph, size: 15, weight: 1.5) }
                        .buttonStyle(IconButtonStyle(size: RowMoreButton.size))
                        .opacity(controlsVisible ? 1 : 0)
                        .allowsHitTesting(controlsVisible)
                        .accessibilityHidden(true)   // то же действие есть в «Действиях» строки
                }
                RowMoreButton(label: moreLabel, visible: controlsVisible, actions: { actions },
                              isOpen: $menuOpen, isHovered: $moreHover)
            }
            .padding(.trailing, Self.inset)
        }
        .background(RowBackground(selected: selected, hover: controlsVisible))
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: controlsVisible)
        .rowContextMenu(actions)
    }

    /// Кнопки отстоят от края строки на столько же, на сколько от её верха и низа: (32 − 24) / 2.
    static var inset: CGFloat { (Size.row - RowMoreButton.size) / 2 }

    private var controlsWidth: CGFloat {
        let buttons = RowMoreButton.size + (extra == nil ? 0 : RowMoreButton.size + Space.xs)
        return buttons + Self.inset + Space.xs
    }
}

/// Сколько места справа занимают кнопки строки и видны ли они сейчас.
private struct SidebarItemControls {
    let visible: Bool
    let width: CGFloat
}

/// Своя кнопка строки рядом с «…» (у папки — «Новая обработка здесь»).
private struct RowExtraButton {
    let glyph: GlyphKind
    let action: () -> Void
}

/// Папка и её обработки. Щелчок по папке сворачивает и разворачивает список.
private struct FolderSection: View {
    @Environment(AppModel.self) private var model
    let root: URL

    private var collapsed: Bool { model.folders.isCollapsed(root) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            header
            if !collapsed {
                let items = model.history(root)
                if items.isEmpty {
                    Text("Пока пусто")
                        .font(Typo.callout).foregroundStyle(Ink.text3)
                        .padding(.leading, HistoryRow.indent).frame(height: Size.row)
                }
                ForEach(items) { HistoryRow(processing: $0) }
            }
        }
        .padding(.bottom, Space.s)
    }

    /// Строка папки: сама строка сворачивает и разворачивает историю (работает с клавиатуры и VoiceOver).
    /// Место под кнопки держится всегда: название папки не обрезается заново при каждом наведении.
    private var header: some View {
        SidebarItem(extra: RowExtraButton(glyph: .compose) { model.newProcessing(in: root) },
                    label: model.folders.displayName(root), value: collapsed ? "свёрнута" : "развёрнута",
                    hint: "Свернуть или развернуть историю папки",
                    moreLabel: "Действия с папкой", actions: actions,
                    action: { withAnimation(.snappy(duration: 0.2)) { model.folders.toggleCollapsed(root) } }) { controls in
            HStack(spacing: Space.s + 2) {
                Glyph(kind: collapsed ? .folder : .folderOpen, size: 18, weight: 1.55).foregroundStyle(Ink.text2)
                Text(root.lastPathComponent)
                    .font(Typo.body.weight(.medium))
                    .foregroundStyle(Ink.text2)
                    .lineLimit(1)
                    .layoutPriority(1)
                // Две папки с одним именем различаются папкой уровнем выше — прямо в строке, а не подсказкой.
                if let parent = model.folders.distinction(root) {
                    Text(parent).font(Typo.callout).foregroundStyle(Ink.text3).lineLimit(1)
                }
                Glyph(kind: .chevronDown, size: 11, weight: 1.8)
                    .foregroundStyle(Ink.text3)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .opacity(controls.visible ? 1 : 0)
                Spacer(minLength: 0)
            }
            .padding(.leading, Space.s + 2).padding(.trailing, controls.width)
        }
    }

    /// Опасное действие — отдельной группой в конце и красным, как «Удалить…» у обработки. Здесь оно убирает папку
    /// из списка (файлы и история на диске остаются, папку можно добавить снова), но для человека это то же
    /// «убрать навсегда из этого списка».
    private var actions: [RowAction] {
        [
            RowAction(title: "Новая обработка здесь") { model.newProcessing(in: root) },
            RowAction(title: "Показать в Finder") { model.revealFolder(root) },
            RowAction(title: "Убрать из списка", destructive: true, separatorBefore: true) { model.removeFolder(root) },
        ]
    }
}

/// Строка истории. Длинное название растворяется у края, как в референсе, без многоточия.
private struct HistoryRow: View {
    @Environment(AppModel.self) private var model
    let processing: Processing
    @State private var draft = ""
    @FocusState private var editing: Bool

    private var selected: Bool { model.place.processingID == processing.id }
    /// Текст строки истории стоит ровно под названием папки: отступ + значок + промежуток.
    static let indent: CGFloat = Space.s + 2 + 18 + Space.s + 2

    var body: some View {
        Group {
            if model.renaming == processing.id {
                TextField("Название", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Typo.body)
                    .focused($editing)
                    .onSubmit { model.rename(processing, to: draft) }
                    .onExitCommand { model.renaming = nil }
                    .onAppear { draft = processing.title; editing = true }
                    .onChange(of: editing) { _, focused in if !focused { model.rename(processing, to: draft) } }
                    .padding(.leading, Self.indent).padding(.trailing, Space.s + 2).frame(height: Size.row)
                    .background(RowBackground(selected: true, hover: false))
            } else {
                SidebarItem(selected: selected, label: processing.title,
                            value: processing.isBusy ? "идёт обработка" : processing.hasFailure ? "есть ошибки" : "",
                            moreLabel: "Действия с обработкой", actions: actions,
                            action: { model.open(processing) }) { controls in
                    HStack(spacing: Space.s) {
                        // При наведении название растворяется раньше — под кнопкой, а не обрезается заново.
                        FadingText(text: processing.title, color: selected ? Ink.text : Ink.text.opacity(0.86),
                                   reserve: controls.visible ? controls.width - Space.s - 2 : 0)
                        status.opacity(controls.visible ? 0 : 1)
                    }
                    .font(Typo.body)
                    .padding(.leading, Self.indent).padding(.trailing, Space.s + 2)
                }
            }
        }
    }

    private var actions: [RowAction] {
        [
            RowAction(title: "Переименовать") { model.renaming = processing.id },
            RowAction(title: "Показать в Finder") { model.revealOutput(of: processing) },
            RowAction(title: "Удалить…", destructive: true, separatorBefore: true) { model.confirmDelete = processing },
        ]
    }

    @ViewBuilder private var status: some View {
        if processing.isBusy {
            RingProgress(value: 0, size: 12, indeterminate: true)
        } else if processing.hasFailure {
            // Значок состояния без подписи — имя системной подсказкой; для VoiceOver то же в значении строки.
            Glyph(kind: .warning, size: 14, weight: 1.5).foregroundStyle(Ink.danger)
                .systemToolTip("Не все документы обработались")
        }
    }
}

/// Текст в одну строку, который у правого края растворяется.
///
/// Целиком название видно в заголовке окна, когда обработка открыта, и в поле «Переименовать»;
/// подсказки на строках списка нет: при движении по списку они вспыхивали одна за другой.
struct FadingText: View {
    let text: String
    var color: Color = Ink.text
    /// Место справа под кнопку поверх текста (например, «…» при наведении): текст растворяется до него.
    var reserve: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0

    var body: some View {
        Text(text)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .clipped()
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    if cut {
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 28)
                    }
                    Color.clear.frame(width: reserve)
                }
            }
    }

    private var cut: Bool { textWidth > boxWidth - reserve + 0.5 }
}

/// Настройки внизу панели, как профиль в чат-приложениях. Открываются в том же окне.
private struct SettingsRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selected = model.place == .settings
        SidebarRow(selected: selected, shortcut: "⌘,", action: model.openSettings) {
            Glyph(kind: .gear, size: 18, weight: 1.5).foregroundStyle(selected ? Ink.text : Ink.text2)
            Text("Настройки").foregroundStyle(selected ? Ink.text : Ink.text2)
            Spacer(minLength: 4)
        }
    }
}

/// Пока модель не готова, внизу панели видно, что с ней.
private struct EngineStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.engine {
        case .warming:
            HStack(spacing: Space.s) {
                RingProgress(value: 0, size: 12, indeterminate: true)
                Text("Загружаю модель…").font(Typo.caption).foregroundStyle(Ink.text2)
            }
            .padding(.horizontal, Space.l + Space.xs).padding(.vertical, Space.s + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let message):
            VStack(alignment: .leading, spacing: Space.s) {
                Text(RU.t(message)).font(Typo.caption).foregroundStyle(Ink.danger)
                Button("Запустить снова") { model.warmEngine() }
                    .buttonStyle(ActionButtonStyle())
            }
            .padding(.horizontal, Space.l + Space.xs).padding(.vertical, Space.s + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            EmptyView()
        }
    }
}

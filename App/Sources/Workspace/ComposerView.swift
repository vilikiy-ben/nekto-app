import SwiftUI
import UniformTypeIdentifiers

/// Строка ввода: «+» (выбрать файлы), поле для текста, режимы, папка и кнопка отправки.
/// На главном экране стоит посередине окна, в открытой обработке — внизу ленты.
///
/// С файлами строка не подменяется другой карточкой, а вырастает вверх: файлы появляются над ней,
/// нижний ряд остаётся тем же — на тех же местах и тех же размеров. Вместо поля (текст и файлы
/// не уходят вместе) — сводка по файлам, кружок отправки раскрывается в «Обезличить ↑».
///
/// Скругления концентричны: подложка 26, ряд на отступе 10 — кружки 36 (18 + 10 ≈ 26 с учётом
/// вертикального отступа 9), плитки файлов на отступе 10 — радиус 16 (16 + 10 = 26).
struct ComposerView: View {
    enum Placement { case center, bottom }

    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    var placement: Placement

    private var composer: Composer { model.composer }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if composer.hasFiles {
                AttachmentsArea(files: composer.attachments) { remove([$0]) }
                    .padding(.horizontal, Inset.side).padding(.top, Inset.side)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            row
        }
        .background(pill)
        .background(alignment: .topLeading) { escapeKey }
        .animation(.snappy(duration: 0.24), value: composer.hasFiles)
        .animation(.snappy(duration: 0.2), value: composer.attachments.count)
    }

    /// Нижний ряд — один и тот же с текстом и с файлами.
    private var row: some View {
        @Bindable var composer = model.composer
        return HStack(alignment: .bottom, spacing: Space.s) {
            PlusButton { model.openFiles() }
            if composer.hasFiles {
                FilesSummary(count: composer.attachments.count) { remove(composer.attachments) }
                    .frame(maxWidth: .infinity, minHeight: Size.control, alignment: .leading)
            } else {
                ComposerField(text: $composer.text, placeholder: placeholder, focusRequest: composer.focusRequest,
                              onSubmit: submit, onPasteFiles: { composer.attach($0) })
                    .padding(.vertical, 2)
            }
            chips
            if placement == .center { FolderPicker() }
            SendButton(enabled: composer.canSend, title: composer.hasFiles ? "Обезличить" : nil, action: submit)
        }
        .padding(.horizontal, Inset.side).padding(.vertical, Inset.row)
    }

    /// Esc убирает файлы — и это можно отменить (⌘Z): при «Папке целиком» одно случайное нажатие
    /// стирало весь выбор. Невидимая кнопка держит сочетание, пока файлы есть.
    @ViewBuilder private var escapeKey: some View {
        if composer.hasFiles {
            Button("Убрать файлы") { remove(composer.attachments) }
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0).opacity(0)
                .accessibilityHidden(true)
        }
    }

    /// Убрать файлы с возможностью вернуть их через «Правка → Отменить».
    private func remove(_ urls: [URL]) {
        let composer = model.composer
        let removed = urls
        withAnimation(.snappy(duration: 0.2)) {
            if removed.count == composer.attachments.count { composer.clearAttachments() } else { removed.forEach(composer.detach) }
        }
        undoManager?.registerUndo(withTarget: composer) { target in
            MainActor.assumeIsolated { withAnimation(.snappy(duration: 0.2)) { target.attach(removed) } }
        }
        undoManager?.setActionName(removed.count == 1 ? "Убрать файл" : "Убрать файлы")
    }

    private var placeholder: String {
        model.current?.mapping.isEmpty == false ? "Ответ нейросети или ещё один текст" : "Вставьте текст или перетащите документ"
    }

    /// Капсулы режимов — только на главном экране: с чем начнётся новая обработка, видно до отправки.
    /// У открытой обработки режимы — её решения, их место — флажки групп в «Скрыто» рядом с текстом. Капсула
    /// в ленте повторяла бы флажок и появлялась бы от щелчка в редакторе — как будто строка ввода что-то включила.
    @ViewBuilder private var chips: some View {
        let modes = model.current == nil ? composer.modes : []
        if !modes.isEmpty {
            HStack(spacing: Space.xs + 2) {
                ForEach(modes.sorted { $0.rawValue < $1.rawValue }) { mode in
                    ModeChip(title: mode.chip, action: mode.rehide, glyph: mode.glyph, compact: modes.count > 1) {
                        model.toggleDraftMode(mode)
                    }
                }
            }
            .padding(.bottom, Space.xs)
        }
    }

    private func submit() { model.send() }

    /// Подложка строки ввода.
    private var pill: some View {
        RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
            .fill(Ink.raised)
            .shadow(color: .black.opacity(0.07), radius: 14, y: 4)
            .overlay(RoundedRectangle(cornerRadius: Radius.field, style: .continuous).strokeBorder(Ink.line, lineWidth: 0.75))
    }

    /// Отступы, на которых скругления сходятся с подложкой (`Radius.field`).
    enum Inset {
        static let side: CGFloat = Space.s + 2   // 10: плитка 16 + 10 = 26
        static let row: CGFloat = Space.s + 1    // 9: кружок 18 + 9 ≈ 26
    }
}

extension ComposerView {
    /// Высота нижнего ряда: по нему главный экран ставит строку посередине окна (`AnchoredColumn.anchorRow`).
    static let rowHeight: CGFloat = Size.control + ComposerView.Inset.row * 2
}

// MARK: - Файлы

/// Плитки файлов над строкой. Один файл — плитка по размеру содержимого; несколько — сетка.
private struct AttachmentsArea: View {
    let files: [URL]
    let remove: (URL) -> Void

    var body: some View {
        if files.count == 1, let url = files.first {
            AttachmentTile(url: url, fill: false) { remove(url) }
                .frame(maxWidth: 380, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Space.s)], alignment: .leading, spacing: Space.s) {
                ForEach(files, id: \.self) { url in
                    AttachmentTile(url: url, fill: true) { remove(url) }
                }
            }
        }
    }
}

/// Сводка в ряду вместо поля, когда файлов несколько: «5 файлов» и «Убрать все».
/// С одним файлом её нет: число «1» ничего не сообщает, а убрать файл можно крестиком на плитке.
private struct FilesSummary: View {
    let count: Int
    let removeAll: () -> Void

    /// Контейнер есть всегда, даже пустой: он занимает место поля, и строка не сжимается по содержимому.
    var body: some View {
        HStack(spacing: Space.s) {
            if count > 1 {
                Text("\(count) \(Plural.ru(count, "файл", "файла", "файлов"))")
                    .font(Typo.callout).monospacedDigit().foregroundStyle(Ink.text2)
                    .contentTransition(.numericText())
                Button("Убрать все", action: removeAll)
                    .buttonStyle(QuietButtonStyle())
            }
        }
        .padding(.leading, count > 1 ? Space.xs : 0)
    }
}

/// Прикреплённый файл: значок, имя, размер; крестик при наведении.
/// Фон спокойный, с рамкой: прежняя заливка `Ink.selected` — цвет выбранной строки — делала плитку «выбранной».
/// Сама плитка при наведении не подсвечивается: щелчок по ней ничего не делает, подсветка обещала бы действие.
/// Наведение только показывает крестик.
/// Тип файла не повторяется подписью: его уже говорят цветной значок и расширение в имени.
private struct AttachmentTile: View {
    let url: URL
    /// В сетке плитка тянется на ширину колонки, одна — по содержимому.
    let fill: Bool
    let remove: () -> Void
    @State private var hover = false

    private let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)

    var body: some View {
        HStack(spacing: Space.s + 2) {
            FileIcon(kind: kind, size: 32)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(url.lastPathComponent).font(Typo.callout.weight(.medium)).foregroundStyle(Ink.text)
                    .lineLimit(1).truncationMode(.middle)
                if let detail {
                    Text(detail).font(Typo.small).monospacedDigit().foregroundStyle(Ink.text3)
                }
            }
            if fill { Spacer(minLength: Space.xs) }
            RemoveButton(name: url.lastPathComponent, action: remove)
                .opacity(hover ? 1 : 0)
        }
        .padding(.leading, Space.s + 2).padding(.trailing, Space.s).padding(.vertical, Space.s + 1)
        .frame(maxWidth: fill ? .infinity : nil, alignment: .leading)
        .background(shape.fill(Ink.hover))
        .overlay(shape.strokeBorder(Ink.line, lineWidth: 1))
        .contentShape(shape)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .accessibilityElement(children: .contain)
    }

    private var isFolder: Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    private var kind: FileKind { isFolder ? .folder : FileKind(url: url) }

    private var detail: String? {
        if isFolder { return "Папка" }
        return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        }
    }
}

/// Крестик на плитке: свой отклик на наведение и нажатие, а не только появление вместе с плиткой.
private struct RemoveButton: View {
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Glyph(kind: .close, size: 11, weight: 1.9).frame(width: 24, height: 24)
        }
        .buttonStyle(CircleFillStyle(rest: Ink.selected, tint: Ink.text2))
        .accessibilityLabel("Убрать \(name)")
    }
}

// MARK: - Кнопки строки

/// Тихая кнопка-капсула с подписью: подложка при наведении, приглушение при нажатии. «Убрать все».
private struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { QuietButtonBody(configuration: configuration) }
}

private struct QuietButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hover = false
    var body: some View {
        configuration.label
            .font(Typo.callout.weight(.medium))
            .foregroundStyle(hover ? Ink.text : Ink.text2)
            .padding(.horizontal, Space.s + 2).frame(height: Size.compact)
            .background(Capsule().fill(hover ? Ink.selected : .clear))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hover = $0 }
    }
}

/// Круглая кнопка строки: «+», крестик. Отклик — заливкой круга, а не прозрачностью: на приподнятой подложке
/// разница в 3 % белого не видна (сверено по снимкам экрана), поэтому ступени — 13 % при наведении и 20 % при нажатии.
private struct CircleFillStyle: ButtonStyle {
    var rest: Color
    var tint: Color = Ink.text
    func makeBody(configuration: Configuration) -> some View {
        CircleFillBody(configuration: configuration, rest: rest, tint: tint)
    }
}

private struct CircleFillBody: View {
    let configuration: ButtonStyleConfiguration
    let rest: Color
    let tint: Color
    @State private var hover = false

    var body: some View {
        configuration.label
            .foregroundStyle(hover || configuration.isPressed ? Ink.text : tint)
            .background(Circle().fill(configuration.isPressed ? Ink.text.opacity(0.2) : (hover ? Ink.text.opacity(0.13) : rest)))
            .contentShape(Circle())
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.1), value: hover)
    }
}

/// Нажатое приглушается — как у остальных кнопок приложения.
private struct PressDimStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Куда попадёт новая обработка. Стоит в строке ввода там, где у чат-приложений выбор модели.
private struct FolderPicker: View {
    @Environment(AppModel.self) private var model
    @State private var hover = false

    var body: some View {
        Menu {
            ForEach(model.folders.list, id: \.self) { url in
                Toggle(model.folders.displayName(url), isOn: Binding(get: { model.workFolder == url }, set: { if $0 { model.folders.setCurrent(url) } }))
            }
            Divider()
            Button("Добавить папку…") { model.chooseFolder() }
        } label: {
            HStack(spacing: Space.xs + 1) {
                Glyph(kind: .folder, size: 15, weight: 1.5)
                Text(model.workFolder.map(model.folders.displayName) ?? "Папка").font(Typo.callout).lineLimit(1)
                Glyph(kind: .chevronDown, size: 10, weight: 1.8)
            }
            .foregroundStyle(hover ? Ink.text : Ink.text2)
            // Та же высота, что у «+» и кнопки отправки: ряд из элементов одной высоты.
            .padding(.horizontal, Space.s + 2).frame(height: Size.control)
            .background(Capsule().fill(hover ? Ink.selected : .clear))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hover = $0 }
        .accessibilityLabel("Папка для новой обработки: \(model.workFolder?.lastPathComponent ?? "не выбрана")")
    }
}

private struct PlusButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Glyph(kind: .plus, size: 20, weight: 1.7).frame(width: Size.control, height: Size.control)
        }
        .buttonStyle(CircleFillStyle(rest: Ink.hover))
        .accessibilityLabel("Добавить файлы")
    }
}

/// Отправка. С текстом — кружок со стрелкой; с файлами — тот же кружок раскрывается в «Обезличить ↑»:
/// та же высота и то же место, поэтому скругление сходится с подложкой. Return с файлами отправляет:
/// на Mac синяя кнопка по умолчанию и есть «нажать Return», значок клавиши не нужен.
private struct SendButton: View {
    let enabled: Bool
    var title: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let button = Button(action: action) {
            HStack(spacing: Space.s) {
                if let title {
                    Text(title).font(Typo.body.weight(.semibold))
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
                Glyph(kind: .arrowUp, size: 18, weight: 2.1)
            }
            .foregroundStyle(enabled ? Color.white : Ink.text3)
            .padding(.leading, title == nil ? 0 : Space.l)
            .padding(.trailing, title == nil ? 0 : Space.s + 1)
            .frame(minWidth: Size.control, minHeight: Size.control, maxHeight: Size.control)
            .background(Capsule().fill(enabled ? Ink.accent : Ink.selected))
            .overlay(Capsule().fill(.white.opacity(enabled && hover ? 0.14 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressDimStyle())
        .disabled(!enabled)
        .onHover { hover = $0 }
        .accessibilityLabel(title ?? "Обезличить")
        .animation(.easeOut(duration: 0.15), value: enabled)
        .animation(.easeOut(duration: 0.12), value: hover)
        .animation(.snappy(duration: 0.24), value: title)

        // В поле Return обрабатывает само поле; с файлами поля нет — Return у кнопки.
        if title != nil { button.keyboardShortcut(.defaultAction) } else { button }
    }
}

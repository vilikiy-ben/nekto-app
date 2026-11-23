import SwiftUI
import UniformTypeIdentifiers

/// Новая обработка: вопрос, строка ввода и под ней подсказки, что можно дать приложению.
/// Строка ввода — ровно посередине окна, как у чат-приложений; вопрос над ней, подсказки под ней
/// (`AnchoredColumn`). Раньше посередине стояла вся группа, и шесть подсказок снизу поднимали строку выше центра.
///
/// Пока пользователь печатает, подсказки гаснут, но место за собой оставляют: строка ввода
/// не прыгает под пальцами. С файлами подсказок нет совсем — их место занимает карточка файлов.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    var dropTargeted: Bool

    var body: some View {
        let composer = model.composer
        let showHints = composer.trimmedText.isEmpty
        AnchoredColumn(above: Space.xl + Space.xs, below: Space.l, top: Metrics.topBar + Space.l, bottom: Space.l,
                       anchorRow: ComposerView.rowHeight) {
            Text(dropTargeted ? "Отпустите, и файл добавится" : "Что спрячем от нейросети?")
                .font(Typo.display.weight(.regular))
                .foregroundStyle(Ink.text)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.15), value: dropTargeted)
                .accessibilityAddTraits(.isHeader)
            ComposerView(placement: .center)
                .column()
            if !composer.hasFiles {
                ActionList(items: items)
                    .padding(.horizontal, Space.xs + 2)
                    .column()
                    .opacity(showHints ? 1 : 0)
                    .offset(y: showHints ? 0 : -6)
                    .allowsHitTesting(showHints)
                    .accessibilityHidden(!showHints)
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.22), value: showHints)
        .animation(.snappy(duration: 0.22), value: composer.hasFiles)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var items: [ActionList.Item] {
        var items: [ActionList.Item] = [
            .init(id: "files", icon: .glyph(.paperclip), title: "Файлы и фото", detail: "Можно сразу несколько", shortcut: "⌘O") {
                model.openFiles()
            },
            .init(id: "folder", icon: .file(.folder), title: "Папка целиком", detail: "Все документы из папки") {
                model.openFiles(directories: true)
            },
        ]
        items[items.count - 1].dividerAfter = true
        let formats: [(String, FileKind, String, String, [String])] = [
            ("docs", .document, "Документы", "DOCX, DOC, RTF, ODT", ["docx", "doc", "rtf", "odt"]),
            ("pdf", .pdf, "PDF и сканы", "Текст со сканов распознаётся прямо на Mac", ["pdf", "png", "jpg", "jpeg", "heic", "tiff"]),
            ("sheets", .sheet, "Таблицы", "XLSX, CSV, TSV", ["xlsx", "xlsm", "csv", "tsv"]),
            ("slides", .slides, "Презентации", "PPTX", ["pptx"]),
        ]
        for (id, kind, title, detail, exts) in formats {
            items.append(.init(id: id, icon: .file(kind), title: title, detail: detail) {
                model.openFiles(types: exts.compactMap { UTType(filenameExtension: $0) })
            })
        }
        return items
    }
}

/// Подсказки под строкой ввода, как у чат-приложений: без подложки, значок, название, пояснение серым.
struct ActionList: View {
    enum Icon { case glyph(GlyphKind), file(FileKind) }

    struct Item: Identifiable {
        let id: String
        let icon: Icon
        let title: String
        let detail: String
        var shortcut: String? = nil
        var checked: Bool? = nil
        var dividerAfter = false
        let action: () -> Void
    }

    let items: [Item]
    @State private var highlight: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                Row(item: item, highlighted: highlight == item.id, action: item.action)
                    .onHover { inside in
                        if inside { highlight = item.id } else if highlight == item.id { highlight = nil }
                    }
                if item.dividerAfter {
                    Rectangle().fill(Ink.line).frame(height: 1).padding(.leading, 44).padding(.vertical, Space.xs + 2)
                }
            }
        }
    }

    private struct Row: View {
        let item: Item
        let highlighted: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: Space.m) {
                    Group {
                        switch item.icon {
                        case .glyph(let g): Glyph(kind: g, size: 20, weight: 1.55).foregroundStyle(Ink.text2)
                        case .file(let f): FileIcon(kind: f, size: 21)
                        }
                    }
                    .frame(width: 22, height: 22)
                    Text(item.title).font(Typo.body).foregroundStyle(highlighted ? Ink.text : Ink.text2)
                    Text(item.detail).font(Typo.body).foregroundStyle(Ink.text3).lineLimit(1)
                    Spacer(minLength: Space.s)
                    if item.checked == true {
                        Glyph(kind: .check, size: 16, weight: 2).foregroundStyle(Ink.accent)
                    } else if let shortcut = item.shortcut {
                        Text(shortcut).font(Typo.caption).foregroundStyle(Ink.text3)
                    }
                }
                .padding(.horizontal, Space.m).frame(height: 40)
                .background(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).fill(highlighted ? Ink.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.title)
            .accessibilityHint(item.detail)
        }
    }
}

private extension View {
    /// Ширина колонки главного экрана: та же, что у ленты; строка ввода и подсказки — друг под другом.
    func column() -> some View {
        frame(maxWidth: Metrics.column, alignment: .leading)
            .padding(.horizontal, Space.xxl)
    }
}

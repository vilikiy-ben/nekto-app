import CoreTransferable
import SwiftUI
import TipKit
import UniformTypeIdentifiers

/// Открытая обработка — лента, как переписка: справа то, что дал пользователь,
/// слева то, что вернул Nekto. Строка ввода внизу: добавить документ или вставить ответ нейросети.
struct FeedView: View {
    @Environment(AppModel.self) private var model
    let processing: Processing
    /// Чему научить под результатом — по одной подсказке и по порядку: сначала унести файл в чат,
    /// потом подсмотреть исходные данные. Каждая показывается, пока её не закрыли или не сделали то, чему она учит.
    @State private var lessons = TipGroup(.ordered) {
        DragToChatTip()
        PeekTip()
    }
    @State private var position = ScrollPosition()
    @State private var tracker = FeedScrollTracker()
    /// Лента возвращается на место (2–3 кадра): пока не встала, её не видно — иначе мелькнули бы начало и якорь.
    @State private var settling = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: Space.xxl) {
                        ForEach(processing.items) { job in
                            Exchange(job: job, processing: processing)
                                .id(job.id)
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { tracker.placed(job.id, $0) }
                                .onDisappear { tracker.forget(job.id) }
                        }
                        if teachable, let lesson = lessons.currentTip {
                            TipView(lesson)
                                .tipCornerRadius(Radius.card)
                                .padding(.top, -Space.s)
                                // TipKit дорисовывает подсказку позже, чем лента опускается к концу: догоняем —
                                // если лента у конца, а не там, где человек её оставил перед редактором.
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                    if height > 0, !tracker.holdsPlace { scrollToEnd(proxy, animated: true, after: 0.15) }
                                }
                        }
                    }
                    .frame(maxWidth: Metrics.column)
                    .padding(.horizontal, Space.xxl)
                    .padding(.top, Metrics.topBar + Space.xl)
                    .frame(maxWidth: .infinity)
                    // Место под строкой ввода. Лента открывается здесь, как чат: последние действия видны.
                    Color.clear.frame(height: 140).id(Self.end)
                }
                .scrollPosition($position)
                .opacity(settling ? 0 : 1)
                .scrollIndicators(.automatic)
                .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in tracker.scrolled(geometry) }
                .onAppear { restore(proxy) }
                .onDisappear { model.feedPlaces[processing.id] = tracker.place(order: processing.items.map(\.id)) }
                .onChange(of: processing.items.count) { followEnd(proxy) }
                // Результат пришёл и карточка выросла — опускаемся к нему, пока пользователь ждёт.
                .onChange(of: processing.items.last?.output != nil) { followEnd(proxy) }
                // Подсказка появилась под результатом — она не должна прятаться под строкой ввода. Но не утягивает
                // ленту, которую вернули на место: заново созданная группа подсказок выдаёт свою не сразу,
                // и этот переход выглядит как «появилась новая».
                .onChange(of: teachable ? lessons.currentTip?.id : nil) { if !tracker.holdsPlace { followEnd(proxy) } }
            }
            VStack(spacing: 0) {
                LinearGradient(colors: [Ink.canvas.opacity(0), Ink.canvas], startPoint: .top, endPoint: .bottom)
                    .frame(height: 26)
                    .allowsHitTesting(false)
                ComposerView(placement: .bottom)
                    .frame(maxWidth: Metrics.column)
                    .padding(.horizontal, Space.xxl)
                    .padding(.bottom, Space.l)
                    .frame(maxWidth: .infinity)
                    .background(Ink.canvas)
            }
        }
    }

    private static let end = "feed-end"

    /// Учим только у готового обезличенного документа: у ответа нейросети нет ни файла для чата, ни меток.
    private var teachable: Bool {
        guard let last = processing.items.last else { return false }
        return !last.isReply && last.output?.fileURL != nil && !last.state.isActive
    }

    /// Лента открывается там, где её оставили (`FeedPlace`); впервые или с новыми карточками — с конца, как чат.
    ///
    /// Два шага: сначала карточка-якорь к верхнему краю (ленивый стек раскрывает её и соседей, их рамки
    /// становятся точными), затем досдвиг на то, насколько её верх был за краем.
    private func restore(_ proxy: ScrollViewProxy) {
        guard let saved = model.feedPlaces[processing.id], saved.itemCount == processing.items.count,
              case .item(let job, let overshoot) = saved.spot, processing.items.contains(where: { $0.id == job }) else {
            scrollToEnd(proxy, animated: false)
            return
        }
        tracker.holdsPlace = true
        settling = true
        Task { @MainActor in
            defer { settling = false }
            let start = tracker.offset
            proxy.scrollTo(job, anchor: .top)
            // Прокрутка к якорю применяется на следующей раскладке; досдвиг раньше неё она бы перетёрла.
            // Якорь, который и так у края (первая карточка), прокрутку не сдвинет — его ждать не нужно.
            var frames = 0
            while frames < 12, tracker.offset == start, abs(tracker.top(of: job) ?? .infinity) > 0.5 {
                try? await Task.sleep(for: .milliseconds(16))
                frames += 1
            }
            guard let top = tracker.top(of: job) else { return }
            position.scrollTo(y: max(0, tracker.offset + top + overshoot))
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    /// Новое в ленте (отправили документ, пришёл результат, сменилась подсказка) — к концу, туда, где оно.
    private func followEnd(_ proxy: ScrollViewProxy) {
        tracker.holdsPlace = false
        scrollToEnd(proxy, animated: true)
    }

    /// `after` — подождать, пока ScrollView узнает новую высоту содержимого (подсказка выросла после раскладки).
    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool, after delay: TimeInterval = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if animated { withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(Self.end, anchor: .bottom) } }
            else { proxy.scrollTo(Self.end, anchor: .bottom) }
        }
    }
}

// MARK: - Пара «вход → результат»

private struct Exchange: View {
    let job: Job
    let processing: Processing

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            InputMessage(job: job)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Response(job: job, processing: processing)
        }
    }
}

/// То, что дал пользователь: файл — плиткой, текст — пузырём.
private struct InputMessage: View {
    let job: Job
    @State private var expanded = false

    var body: some View {
        switch job.kind {
        case .file:
            HStack(spacing: Space.m) {
                FileIcon(kind: job.fileKind, size: 32)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(job.name).font(Typo.body.weight(.medium)).foregroundStyle(Ink.text)
                        .lineLimit(1).truncationMode(.middle)
                    Text(detail).font(Typo.caption).foregroundStyle(Ink.text3)
                }
            }
            .padding(.leading, Space.m).padding(.trailing, Space.l).padding(.vertical, Space.m)
            .background(RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous).fill(Ink.bubble))
            .frame(maxWidth: 420, alignment: .trailing)
        case .text, .reply:
            VStack(alignment: .trailing, spacing: Space.s) {
                if job.isReply {
                    HStack(spacing: Space.s) {
                        FileIcon(kind: .reply, size: 15)
                        Text("Ответ нейросети").font(Typo.caption.weight(.medium)).foregroundStyle(Ink.text2)
                    }
                }
                let text = job.inputText ?? ""
                VStack(alignment: .trailing, spacing: Space.xs) {
                    Text(job.isReply ? Self.tinted(text) : AttributedString(text))
                        .font(Typo.body)
                        .foregroundStyle(Ink.text)
                        .lineSpacing(3)
                        .lineLimit(expanded ? nil : 7)
                        .textSelection(.enabled)
                    if text.count > 420 || text.filter(\.isNewline).count > 6 {
                        Button(expanded ? "Свернуть" : "Показать полностью") { withAnimation(.snappy) { expanded.toggle() } }
                            .buttonStyle(.plain).font(Typo.caption.weight(.medium)).foregroundStyle(Ink.text2)
                    }
                }
                .padding(.horizontal, Space.l).padding(.vertical, Space.m)
                .background(RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous).fill(Ink.bubble))
            }
            .frame(maxWidth: 520, alignment: .trailing)
        }
    }

    /// Метки в ответе нейросети — тем же акцентом, что и в документе: видно, что вернётся на место.
    static func tinted(_ text: String) -> AttributedString {
        var s = AttributedString(text)
        for m in text.matches(of: /\[?[A-ZА-ЯЁ]+_\d+\]?/) {
            guard let lo = AttributedString.Index(m.range.lowerBound, within: s),
                  let hi = AttributedString.Index(m.range.upperBound, within: s) else { continue }
            s[lo..<hi].foregroundColor = Ink.accent
            s[lo..<hi].font = Typo.mono(Typo.bodySize - 1, .semibold)
        }
        return s
    }

    private var detail: String {
        let ext = (job.name as NSString).pathExtension.uppercased()
        if job.sourceIsExtractedText { return ext.isEmpty ? "Распознан текст" : "\(ext) · распознан текст" }
        guard let size = job.source.flatMap({ try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }) ?? job.origin.flatMap({ try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }) else { return ext }
        return [ext, ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Ответ Nekto: работа, ошибка или результат.
private struct Response: View {
    @Environment(AppModel.self) private var model
    let job: Job
    let processing: Processing

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            // Первая обработка — работа видна. Обновление после правки — нет: карточка остаётся как есть,
            // а новый текст встаёт в неё точечно. Подпись — только если обновление затянулось.
            if job.state.isActive, job.output == nil {
                ShimmerText(text: workingText)
                    .padding(.vertical, 6)
            }
            if let output = job.output {
                ResultCard(job: job, output: output, processing: processing)
                    // Над карточкой, в промежутке до сообщения: шапку карточки (ссылку «Открыть в редакторе») не закрывает.
                    .overlay(alignment: .topTrailing) {
                        SlowWorkHint(active: job.isRefreshing, text: "Обновляю…")
                            .alignmentGuide(.top) { $0[.bottom] + Space.xs }
                            .padding(.trailing, Space.s)
                    }
            } else if case .failed(let message) = job.state {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Glyph(kind: .warning, size: 16, weight: 1.5).foregroundStyle(Ink.danger).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                    Text(RU.t(message)).font(Typo.body).foregroundStyle(Ink.text)
                    Spacer(minLength: Space.s)
                    Button { model.retry(job) } label: { Label { Text("Повторить") } icon: { Glyph(kind: .restore, size: 14, weight: 1.6) } }
                        .buttonStyle(ActionButtonStyle())
                }
            }
        }
    }

    private var workingText: String {
        switch job.state {
        case .queued: return "В очереди…"
        case .reading(let p): return "Распознаю текст · \(RU.percent(p))"
        case .cleaning(let p):
            if job.isReply { return "Возвращаю данные…" }
            return p < 0.02 ? "Ищу персональные данные…" : "Ищу персональные данные · \(RU.percent(p))"
        default: return ""
        }
    }
}

// MARK: - Карточка результата

private struct ResultCard: View {
    @Environment(AppModel.self) private var model
    let job: Job
    let output: JobOutput
    let processing: Processing

    @State private var naturalHeight: CGFloat = 0
    private let clampHeight: CGFloat = 360
    private let inlineLimit = 6_000

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            summary
            VStack(alignment: .leading, spacing: 0) {
                header
                Rectangle().fill(Ink.line).frame(height: 1)
                sheet(preview.layout)
            }
            .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Ink.raised))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Ink.line, lineWidth: 0.75))
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            ResultActions(job: job, output: output)
        }
    }

    // Сводка над листом — как первая фраза ответа в чате. Все типы, без обрыва: это и есть отчёт.
    @ViewBuilder private var summary: some View {
        if job.isReply {
            let n = output.restored.count
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(n == 0 ? "В ответе нет меток из этой обработки, возвращать нечего."
                            : RU.t("Данные вернулись на место: \(n) \(Plural.ru(n, "замена", "замены", "замен")). Они подсвечены зелёным."))
                    .font(Typo.body).foregroundStyle(Ink.text)
                if !output.unknownTags.isEmpty {
                    Text(RU.t("Не из этой обработки: \(output.unknownTags.prefix(4).joined(separator: ", "))\(output.unknownTags.count > 4 ? "…" : ""). Эти метки остались как есть."))
                        .font(Typo.callout).foregroundStyle(Ink.danger)
                }
            }
        } else {
            // Одна короткая фраза; что именно скрыто и примечания — по «i», чтобы не спорить с текстом документа.
            let total = job.hiddenCount
            HStack(spacing: Space.xs + 2) {
                Text(total == 0 ? "Персональных данных не нашлось, текст можно отправлять как есть."
                                : "Скрыто \(total) \(Plural.ru(total, "значение", "значения", "значений"))")
                    .font(Typo.body).foregroundStyle(Ink.text)
                if total > 0 || !output.notes.isEmpty {
                    SummaryInfo(counts: output.tagCounts, notes: output.notes)
                }
            }
        }
    }

    /// Шапка листа — сам файл результата: его можно утащить в окно чата (курсор-рука).
    /// Справа — голубая ссылка «Открыть в редакторе»: документ целиком и панель «Скрыто» рядом.
    private var header: some View {
        HStack(spacing: Space.s) {
            if let file = output.fileURL {
                FileIcon(kind: job.isReply ? .reply : FileKind(url: file), size: 20)
                Text(file.lastPathComponent).font(Typo.callout.weight(.medium)).foregroundStyle(Ink.text2)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: Space.s)
            EditorLink { model.openInEditor(job) }
        }
        .padding(.horizontal, Space.l).frame(height: 40)
        .contentShape(Rectangle())
        .modifier(DraggableFile(url: output.fileURL))
    }

    private func sheet(_ document: DocumentLayout) -> some View {
        DocumentView(document: document, highlight: job.isReply ? .restored : .placeholders,
                      originals: processing.originals, decisions: job.isReply ? TextDecisions() : processing.textDecisions, inline: true,
                      onHide: job.isReply ? nil : { model.hide($0, as: $1, in: processing) },
                      onUnhide: job.isReply ? nil : { model.setHidden($0, false, in: processing) },
                      onRehide: job.isReply ? nil : { model.setHidden($0, true, in: processing) })
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { naturalHeight = $0 }
            .frame(maxHeight: clampHeight, alignment: .top)
            .clipped()
            .padding(.horizontal, Space.l + 2).padding(.top, Space.m + 2).padding(.bottom, expandable ? 0 : Space.l)
            .overlay(alignment: .bottom) {
                // Длинный текст обрывается мягко; целиком он открывается в редакторе.
                if expandable {
                    LinearGradient(colors: [Ink.raised.opacity(0), Ink.raised], startPoint: .top, endPoint: .bottom)
                        .frame(height: 70)
                        .allowsHitTesting(false)
                }
            }
    }

    /// Начало документа: первые строки таблиц и первые абзацы. Целиком — в редакторе.
    private var preview: (layout: DocumentLayout, cut: Bool) { output.document.prefix(rows: 12, limit: inlineLimit) }

    private var expandable: Bool { naturalHeight > clampHeight + 1 || preview.cut }
}

/// «i» рядом со сводкой: по нажатию — что именно скрыто по типам и примечания движка.
/// Точка на значке — есть примечания (например, удалённые вложения), их стоит прочитать.
private struct SummaryInfo: View {
    let counts: [(tag: String, count: Int)]
    let notes: [String]
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Glyph(kind: .info, size: 16, weight: 1.5)
                .overlay(alignment: .topTrailing) {
                    if !notes.isEmpty {
                        Circle().fill(Ink.accent).frame(width: 6, height: 6).offset(x: 1, y: -1)
                    }
                }
        }
        .buttonStyle(IconButtonStyle(size: 24, tint: Ink.text2))
        .accessibilityLabel("Подробности: что скрыто")
        .popover(isPresented: $shown, arrowEdge: .bottom) { details }
        #if DEBUG
        // Снимок без кликов: `-NektoSummaryInfo YES` открывает панель у результата с примечаниями.
        .task {
            guard UserDefaults.standard.bool(forKey: Brand.key("SummaryInfo")), !notes.isEmpty else { return }
            try? await Task.sleep(for: .seconds(1)); shown = true
        }
        #endif
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !counts.isEmpty {
                Text("Что скрыто").font(Typo.caption.weight(.semibold)).foregroundStyle(Ink.text2)
                    .padding(.bottom, Space.xs + 2)
                    .accessibilityAddTraits(.isHeader)
                ForEach(counts, id: \.tag) { item in
                    HStack(spacing: Space.l) {
                        Text(KindNames.title(item.tag)).font(Typo.callout).foregroundStyle(Ink.text)
                        Spacer(minLength: Space.l)
                        Text("\(item.count)").font(Typo.callout).monospacedDigit().foregroundStyle(Ink.text2)
                    }
                    .frame(height: 24)
                    .accessibilityElement(children: .combine)
                }
            }
            if !notes.isEmpty {
                if !counts.isEmpty { Divider().padding(.vertical, Space.s) }
                Text("Примечания").font(Typo.caption.weight(.semibold)).foregroundStyle(Ink.text2)
                    .padding(.bottom, Space.xs + 2)
                    .accessibilityAddTraits(.isHeader)
                ForEach(notes, id: \.self) { note in
                    Text(RU.t(note.prefix(1).uppercased() + note.dropFirst()))
                        .font(Typo.callout).foregroundStyle(Ink.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, Space.xxs)
                }
            }
        }
        .padding(Space.l)
        .frame(width: 240, alignment: .leading)
    }
}

/// «Открыть в редакторе» в шапке карточки: голубая ссылка, без рамки. Курсор — указатель ссылки,
/// а не рука перетаскивания, как у остальной шапки.
private struct EditorLink: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text("Открыть в редакторе")
                .font(Typo.caption.weight(.medium))
                .foregroundStyle(Ink.accent)
                .opacity(hover ? 0.75 : 1)
                .padding(.vertical, Space.xs)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hover = $0 }
        .pointerStyle(.link)
    }
}

/// Что делать с результатом: отнести в чат (главное) и найти файл.
/// Один и тот же набор под карточкой в ленте и в подвале редактора. Редактор открывается ссылкой в шапке карточки.
struct ResultActions: View {
    @Environment(AppModel.self) private var model
    let job: Job
    let output: JobOutput

    var body: some View {
        HStack(spacing: Space.s) {
            // Подписи кнопок говорят сами за себя, подсказок у них нет: «Скопировать» нажимают
            // в каждой обработке, и объяснение при каждой заминке над ней только мешало.
            CopyButton(title: job.isReply ? "Скопировать ответ" : "Скопировать",
                       hint: job.isReply ? "Ответ с исходными данными на месте меток" : "Текст с метками — для вставки в чат") { model.copy(output) }
            // Единственный значок без подписи в ряду: папка с лупой, как «Показать в Finder» в Safari и Почте.
            Button { model.reveal(output) } label: { Glyph(kind: .reveal, size: 17, weight: 1.5) }
                .buttonStyle(IconButtonStyle(size: Size.compact + 2))
                .iconName("Показать в Finder")
                .disabled(output.fileURL == nil)
        }
        .labelStyle(ActionLabelStyle())
        .fixedSize()
    }
}

/// Значок и подпись в кнопке действия: значок чуть отодвинут, чтобы капсула не казалась тесной.
struct ActionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Space.xs + 2) { configuration.icon; configuration.title }
    }
}

/// Копирование с подтверждением: на полторы секунды «Скопировано» с зелёной галочкой.
struct CopyButton: View {
    let title: String
    /// Что именно копируется — для VoiceOver. Зрячему это видно по карточке над кнопкой.
    let hint: String
    let action: () -> Void
    @State private var copied = false

    var body: some View {
        Button {
            action()
            withAnimation(.easeOut(duration: 0.15)) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation(.easeOut(duration: 0.2)) { copied = false }
            }
        } label: {
            Label {
                Text(copied ? "Скопировано" : title)
            } icon: {
                Glyph(kind: copied ? .check : .copy, size: 15, weight: copied ? 2 : 1.6)
            }
            .contentTransition(.opacity)
        }
        .buttonStyle(ActionButtonStyle(prominent: true, confirmed: copied))
        .accessibilityLabel(copied ? "Скопировано" : title)
        .accessibilityHint(hint)
    }
}

/// Файл результата можно перетащить прямо в окно чата с нейросетью.
///
/// Что его можно тащить, говорит курсор-рука над шапкой. Словами — один раз,
/// подсказкой `DragToChatTip` под последним результатом; после первого перетаскивания она не появляется.
struct DraggableFile: ViewModifier {
    static let hint = "Перетащите файл в окно чата"
    let url: URL?
    func body(content: Content) -> some View {
        if let url {
            content
                .draggable(ResultFile(url: url))
                .pointerStyle(.grabIdle)
                .accessibilityHint(Self.hint)
        } else {
            content
        }
    }
}

/// Перетаскивание наружу: FileRepresentation + ProxyRepresentation(URL), иначе Finder и браузеры не примут.
/// Получатель берёт одно из двух, поэтому «научился переносить файл» отмечается в обоих.
struct ResultFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { file in
            Teaching.learned(DragToChatTip())
            return SentTransferredFile(file.url)
        }
            .suggestedFileName { $0.url.lastPathComponent }
        ProxyRepresentation { (file: ResultFile) -> URL in
            Teaching.learned(DragToChatTip())
            return file.url
        }
    }
}

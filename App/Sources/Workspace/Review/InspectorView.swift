import SwiftUI
import TipKit

/// «Скрыто»: проверка перед отправкой. Модель находит не всё и иногда ошибается, поэтому здесь
/// видно, что уйдёт под метками, и это можно поправить.
///
/// Панель — один список групп по типам данных (`DocumentReview`). У каждой группы флажок «скрывать все»
/// с тремя состояниями и сворачивание; типы с режимом (даты, ссылки, организации) — такие же группы, их флажок
/// и есть режим. Отдельного блока режимов внизу больше нет: он был вторым, оторванным от списка управлением
/// тем же самым.
///
/// Список — по открытому документу: счётчик совпадает с подвалом редактора. Правки действуют
/// на всю обработку (метки у её документов общие); отдельной подписью панель об этом больше не говорит —
/// она стояла над списком в каждой обработке из нескольких файлов и отнимала место у строк.
struct InspectorView: View {
    @Environment(AppModel.self) private var model
    let processing: Processing
    let job: Job
    @State private var query = DebugScenario.reviewFilter ?? ""

    var body: some View {
        // Состав и порядок строк от галочек не зависят (`DocumentReview`): щелчок меняет строку на месте.
        let review = DocumentReview(processing: processing, job: job)
        let filtering = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let groups = review.filtered(query)
        let prefs = model.reviewPrefs

        VStack(alignment: .leading, spacing: 0) {
            ReviewTitle(hidden: review.hiddenCount, total: review.total)
            if review.total > ReviewFilterBar.threshold {
                ReviewFilterBar(query: $query, filtering: filtering,
                                allCollapsed: review.collapsible.allSatisfy(prefs.isCollapsed),
                                onFold: { fold(review) },
                                onSubmit: { spotlightFirst(in: groups) })
                    .padding(.horizontal, Space.s + 2).padding(.bottom, Space.xs)
            }

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    // Не Lazy: у ленивого стека высоты строк оцениваются, и прокрутка к строке промахивается.
                    VStack(alignment: .leading, spacing: 0) {
                        if review.total == 0 {
                            placeholder("В этом документе ничего не скрыто.")
                        } else if filtering && groups.isEmpty {
                            placeholder("Ничего не нашлось.")
                        }
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            // Пока идёт поиск, совпадения видны и в свёрнутых группах.
                            let collapsed = !filtering && !group.entries.isEmpty && prefs.isCollapsed(group.kind)
                            ReviewGroupHeader(group: group, collapsed: collapsed, processing: processing,
                                              collapsibleKinds: review.collapsible,
                                              gapAbove: index == 0 ? Space.xs : gap(after: groups[index - 1], filtering: filtering))
                                .id(ReviewGroupHeader.scrollID(group.kind))
                            if !collapsed {
                                ForEach(group.rows) { entry in
                                    ReviewEntryRow(entry: entry, hidden: processing.isHidden(entry), locked: group.locked,
                                                   processing: processing, job: job)
                                        .id(entry.placeholder)
                                        .transition(.opacity)
                                }
                            }
                        }
                        // Раньше подсказка стояла внизу панели отдельным блоком и меняла высоту списка.
                        // Теперь — в конце списка, пока человек не скрыл что-то сам или не закрыл её.
                        TipView(HideMissedTip())
                            .tipCornerRadius(Radius.tile)
                            .padding(.top, Space.l)
                    }
                    .padding(.horizontal, Space.s + 2).padding(.bottom, Space.l)
                    // Анимируется появление новой строки («Скрыть» из меню) и сворачивание; щелчки по галочкам не двигают.
                    .animation(.snappy(duration: 0.25), value: review.total)
                }
                .background { HoverFollower(proxy: proxy, processing: processing, ids: job.roster) }
            }
        }
        .background(Ink.sidebar)
        .onChange(of: job.id) { query = "" }
    }

    private func placeholder(_ text: String) -> some View {
        Text(RU.t(text)).font(Typo.callout).foregroundStyle(Ink.text2)
            .padding(.horizontal, Space.s + 2).padding(.vertical, Space.s)
    }

    /// Свёрнутые группы стоят плотно, как оглавление; после раскрытой — воздух, чтобы было видно, где кончились её строки.
    private func gap(after previous: DocumentReview.Group, filtering: Bool) -> CGFloat {
        let open = !previous.entries.isEmpty && (filtering || !model.reviewPrefs.isCollapsed(previous.kind))
        return open ? Space.s + 2 : Space.xxs
    }

    /// Хоть одна группа раскрыта — свернуть все; все свёрнуты — раскрыть все.
    private func fold(_ review: DocumentReview) {
        let prefs = model.reviewPrefs
        let collapse = !review.collapsible.allSatisfy(prefs.isCollapsed)
        withAnimation(.snappy(duration: 0.22)) { prefs.setCollapsed(review.collapsible, collapse) }
    }

    /// Return в поле фильтра — показать первое совпадение в тексте.
    private func spotlightFirst(in groups: [DocumentReview.Group]) {
        guard let entry = groups.first?.rows.first else { return }
        model.spotlight(job.spotlightTarget(for: entry))
    }
}

/// Заголовок панели — в верхней полосе, на одной линии со значком панели и заголовком окна,
/// тем же шрифтом, что заголовок окна. Это текст без действий, поэтому ему можно стоять под панелью
/// инструментов (кнопкам там клики не гарантированы). «из N» — только когда что-то открыто: сразу видно,
/// что не всё уйдёт под метками.
private struct ReviewTitle: View {
    let hidden: Int
    let total: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text("Скрыто").font(Typo.callout.weight(.semibold)).foregroundStyle(Ink.text)
            HStack(spacing: 0) {
                Text("\(hidden)").foregroundStyle(Ink.text2)
                    .contentTransition(.numericText())
                if hidden < total {
                    Text(" из \(total)").foregroundStyle(Ink.text3).transition(.opacity)
                }
            }
            .font(Typo.callout).monospacedDigit()
            .animation(.snappy(duration: 0.2), value: hidden)
        }
        .frame(height: Metrics.topBar)
        .padding(.horizontal, Space.l + Space.xs)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Курсор над меткой в тексте — её строка, если ушла из виду, подъезжает; если группа свёрнута — её заголовок.
/// Отдельное представление: метка под курсором меняется при каждом движении мыши по тексту, и от неё зависит
/// только оно, а не вся панель.
private struct HoverFollower: View {
    @Environment(AppModel.self) private var model
    let proxy: ScrollViewProxy
    let processing: Processing
    let ids: Set<String>

    var body: some View {
        Color.clear.onChange(of: model.hoveredTag) { _, tag in
            guard let tag, ids.contains(tag), let kind = processing.byPlaceholder[tag]?.kind else { return }
            let target = model.reviewPrefs.isCollapsed(kind) ? ReviewGroupHeader.scrollID(kind) : tag
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target) }
        }
    }
}

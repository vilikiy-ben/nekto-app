import Foundation

/// Проверка документа: что нашла модель (таблица меток), что решил пользователь (галочки и режимы)
/// и как это выглядит в панели «Скрыто» и в тексте.
///
/// Решение пользователя действует сразу: панель и текст читают `isHidden`, где несохранённое решение
/// (`Processing.desired`) сильнее ответа движка. Движок и файлы догоняют в фоне (`AppModel+Edits`).
/// Поэтому галочка, строка и «пилюля» в тексте меняются в одном кадре, а не после пересчёта.
extension Processing {
    /// Тип открыт режимом целиком: «Скрывать все даты» снят — даты видны, сколько бы галочек ни стояло у отдельных дат;
    /// «Скрывать организации» снят — организации видны.
    func keptByMode(_ kind: String) -> Bool {
        ProcessingMode(rawValue: kind).map { !$0.hides(in: modes) } ?? false
    }

    /// Скрывается ли значение — с учётом ещё не подтверждённого решения и режимов.
    func isHidden(_ entry: MappingEntry) -> Bool {
        if keptByMode(entry.kind) { return false }
        return decision(entry)
    }

    /// Решение по самому значению, без режима: под режимом «не скрываются» оно ждёт и вернётся вместе с типом.
    func decision(_ entry: MappingEntry) -> Bool { desired[entry.placeholder] ?? !entry.allowed }

    /// Все решения разом — для «Отменить» (`AppModel+Undo`).
    var decisionSnapshot: DecisionSnapshot {
        DecisionSnapshot(modes: modes, hidden: Dictionary(mapping.map { ($0.placeholder, decision($0)) }, uniquingKeysWith: { a, _ in a }))
    }

    /// Как раскрасить текст: метки снятых значений серые, а значения, которые снова скрываются, — синие.
    /// В тексте ищутся только те значения, которые там могут стоять открытыми: снятые, видимые по режиму
    /// и ещё ждущие подтверждения.
    var textDecisions: TextDecisions {
        var shown: [String: String] = [:]
        var hidden: [String: Bool] = [:]
        for e in mapping {
            let isHidden = isHidden(e)
            hidden[e.placeholder] = isHidden
            guard e.allowed || desired[e.placeholder] != nil || keptByMode(e.kind) else { continue }
            for form in e.forms { shown[form] = e.placeholder }
        }
        return TextDecisions(shown: shown, hidden: hidden)
    }
}

/// Решения пользователя в обработке на один момент: режимы и «скрывать» у каждого значения.
struct DecisionSnapshot: Equatable {
    let modes: Set<ProcessingMode>
    let hidden: [String: Bool]
}

extension Job {
    /// Что показать в тексте по щелчку на строке: метку или значение. Решает сам текст — решение
    /// могло ещё не дойти до него.
    func spotlightTarget(for entry: MappingEntry) -> String {
        output?.document.text.contains(entry.placeholder) == true ? entry.placeholder : entry.original
    }

    /// Добавляет в список панели значения, которые есть в новом тексте: метки и открыто стоящие значения
    /// (снятые или видимые по режиму). Ничего не убирает.
    func extendRoster() {
        // По виду, а не по тексту для чата: в счёт идут колонтитулы, примечания и свойства файла — они уходят с файлом.
        guard !isReply, let text = output?.document.text, !text.isEmpty, let p = processing else { return }
        let ns = text as NSString
        var found = roster
        for m in DocumentText.tagRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            found.insert(ns.substring(with: m.range))
        }
        for e in p.mapping where !found.contains(e.placeholder) && (e.allowed || p.keptByMode(e.kind)) {
            if e.forms.contains(where: { ns.range(of: $0, options: .caseInsensitive).location != NSNotFound }) {
                found.insert(e.placeholder)
            }
        }
        if found != roster { roster = found }
    }
}

/// Панель «Скрыто» одного документа: группы по типам данных, у каждой — флажок «скрывать все».
///
/// Порядок групп постоянный (`KindOrder`), а не по первой находке: «Даты» в любом документе на одном месте,
/// и глаз находит их, не читая заголовки. Строки внутри группы — в порядке таблицы меток (порядок находок).
/// Ни порядок, ни состав не зависят от галочек: щелчок меняет строку на месте.
///
/// Типы с режимом (даты, ссылки, организации) — тоже группы: флажок группы и есть режим. Поэтому группа
/// такого типа видна и без строк, когда в ней может что-то быть: тип открыт режимом (движок тогда не отдаёт
/// его значений) или его уже переключали в этой обработке. Организации видны всегда: по умолчанию они открыты,
/// и это единственное место, где их можно начать скрывать.
struct DocumentReview {
    /// Флажок группы: все строки скрываются, ни одна или часть (системный «смешанный» флажок, HIG → Toggles).
    enum Check: Equatable { case on, off, mixed }

    struct Group: Identifiable {
        let kind: String
        /// Все значения группы: по ним считаются флажок и число, на них действует флажок группы.
        let entries: [MappingEntry]
        /// Строки, которые видны сейчас: все или только совпавшие с фильтром.
        var rows: [MappingEntry]
        /// Режим, который управляет типом целиком.
        let mode: ProcessingMode?
        /// Тип открыт режимом: строки серые и не нажимаются.
        let locked: Bool
        let hidden: Int
        /// Обработка пересчитывается: пустая группа, может быть, ещё наполнится.
        var searching = false
        var id: String { kind }

        var check: Check {
            if locked { return .off }
            if entries.isEmpty { return .on }
            return hidden == entries.count ? .on : hidden == 0 ? .off : .mixed
        }

        /// Подпись после числа: почему у группы такой флажок.
        var note: String? {
            if locked { return "не скрываются" }
            if entries.isEmpty { return searching ? "ищу…" : "не найдены" }
            return nil
        }
    }

    let groups: [Group]
    let hiddenCount: Int
    let total: Int

    @MainActor
    init(processing p: Processing, job: Job) {
        var buckets: [String: [MappingEntry]] = [:]
        for e in p.mapping where job.roster.contains(e.placeholder) { buckets[e.kind, default: []].append(e) }
        for mode in ProcessingMode.allCases where buckets[mode.engineKind] == nil {
            let visible = p.keptByMode(mode.engineKind) || mode == .hideOrgs || p.touchedModes.contains(mode)
            if visible { buckets[mode.engineKind] = [] }
        }
        var hidden = 0
        var groups: [Group] = []
        for kind in buckets.keys.sorted(by: KindOrder.precedes) {
            let entries = buckets[kind] ?? []
            let locked = p.keptByMode(kind)
            let n = locked ? 0 : entries.filter(p.isHidden).count
            hidden += n
            groups.append(Group(kind: kind, entries: entries, rows: entries, mode: ProcessingMode(rawValue: kind), locked: locked, hidden: n,
                                searching: p.isBusy || !p.edits.isIdle))
        }
        self.groups = groups
        self.hiddenCount = hidden
        self.total = groups.reduce(0) { $0 + $1.entries.count }
    }

    /// Типы, которые можно свернуть: группы со строками.
    var collapsible: [String] { groups.filter { !$0.entries.isEmpty }.map(\.kind) }

    /// Группы, где есть совпадения с фильтром, и в них только совпавшие строки. Тип ищется и по названию:
    /// «тел» оставит все телефоны. Флажок и число группы по-прежнему про всю группу: фильтр меняет вид,
    /// а не то, на что действует флажок.
    func filtered(_ query: String) -> [Group] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return groups }
        return groups.compactMap { group in
            if KindNames.title(group.kind).localizedStandardContains(q), !group.entries.isEmpty { return group }
            var g = group
            g.rows = group.entries.filter { e in
                e.placeholder.localizedStandardContains(q) || e.original.localizedStandardContains(q)
                    || e.variants.contains { $0.localizedStandardContains(q) }
            }
            return g.rows.isEmpty ? nil : g
        }
    }
}

/// Постоянный порядок типов в панели: сначала то, что называет человека, потом номера документов, связь,
/// реквизиты и прочее; в конце — типы с режимом, которые чаще открывают целиком.
enum KindOrder {
    static let order = ["ФИО", "ДР", "ПАСПОРТ", "СНИЛС", "ИНН", "ТЕЛЕФОН", "EMAIL", "АДРЕС", "НИК",
                        "СЧЁТ", "КАРТА", "НОМЕР", "IP", "MAC", "СЕКРЕТ", "ПДН", "ДАТА", "ССЫЛКА", "ОРГ"]
    private static let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })

    /// Неизвестный тип (новая версия движка) — перед типами с режимом, по алфавиту.
    static func precedes(_ a: String, _ b: String) -> Bool {
        let unknown = rank["ПДН", default: 0]
        let ra = rank[a] ?? unknown, rb = rank[b] ?? unknown
        return ra != rb ? ra < rb : a < b
    }
}

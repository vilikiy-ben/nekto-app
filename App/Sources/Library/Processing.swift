import Foundation
import Observation

/// Обработка — одна строка истории, как чат в мессенджере с нейросетью.
///
/// Внутри — документы и тексты, которые пользователь отправил вместе, и ответы нейросети,
/// вставленные обратно. У всех документов обработки общие метки: «[ФИО_1]» в договоре и в письме —
/// один и тот же человек, поэтому ответ нейросети по обоим документам возвращается целиком.
@MainActor
@Observable
final class Processing: Identifiable {
    let id: UUID
    let root: URL
    var title: String
    /// Пользователь переименовал обработку — автоматический заголовок больше не трогаем.
    var customTitle = false
    let createdAt: Date
    var updatedAt: Date
    /// Папка с результатами внутри рабочей папки («2026-11-21 Трудовой договор [ФИО_1]»).
    var folderName: String?
    var modes: Set<ProcessingMode> = []
    /// Режимы, которые переключали в этой обработке, пока приложение открыто: их группы в «Скрыто» остаются
    /// на месте, даже если значений не нашлось (иначе группа пропала бы из-под курсора после пересчёта).
    var touchedModes: Set<ProcessingMode> = []
    var items: [Job] = []
    var mapping: [MappingEntry] = [] {
        didSet { byPlaceholder = Dictionary(mapping.map { ($0.placeholder, $0) }, uniquingKeysWith: { a, _ in a }) }
    }
    @ObservationIgnored private(set) var byPlaceholder: [String: MappingEntry] = [:]
    /// Решения пользователя, которые движок ещё не подтвердил: метка → «скрывать». Панель «Скрыто» и текст
    /// показывают их сразу, движок догоняет в фоне (`AppModel+Edits`). Подтверждённые отсюда убираются.
    var desired: [String: Bool] = [:]
    /// Очередь правок для движка. Интерфейс её не читает.
    @ObservationIgnored var edits = EditQueue()
    /// Состояние сессии движка (`Session.to_state()`): с ним обработку можно продолжить после перезапуска.
    var engineState: JSONValue?
    /// Тексты и предпросмотры прочитаны с диска (история грузится лениво: сначала только заголовки).
    var hydrated = true
    /// Обработку удалили, пока шло задание: на диск её больше не пишем.
    var isDeleted = false

    init(id: UUID = UUID(), root: URL, title: String = "Новая обработка", createdAt: Date = Date()) {
        self.id = id
        self.root = root
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    var dataDir: URL { Store.dataRoot(root).appendingPathComponent(id.uuidString, isDirectory: true) }
    var outputFolder: URL? { folderName.map { root.appendingPathComponent($0, isDirectory: true) } }

    var isBusy: Bool { items.contains { $0.state.isActive } }
    var hasFailure: Bool { items.contains { if case .failed = $0.state { true } else { false } } }
    var originals: [String: String] {
        Dictionary(mapping.map { ($0.placeholder, $0.original) }, uniquingKeysWith: { a, _ in a })
    }


    func nextNumber(for kind: Job.Kind) -> Int {
        items.filter { $0.kind == kind }.map(\.number).max().map { $0 + 1 } ?? 1
    }
}

/// Режимы обработки: тип данных целиком, на все документы обработки. Два вида:
/// даты и ссылки по умолчанию скрыты, и режим их открывает (`keep` движка); организации по умолчанию видны,
/// и режим их скрывает (`hide` движка, `isOptIn`). Значение — тип метки движка.
enum ProcessingMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case keepDates = "ДАТА"
    case keepLinks = "ССЫЛКА"
    case hideOrgs = "ОРГ"

    var id: String { rawValue }
    var engineKind: String { rawValue }

    /// Режим скрывает тип, который без него виден (организации), а не открывает скрытый.
    var isOptIn: Bool { self == .hideOrgs }

    /// Скрыт ли тип при таком наборе режимов.
    func hides(in modes: Set<ProcessingMode>) -> Bool {
        isOptIn ? modes.contains(self) : !modes.contains(self)
    }

    /// Что передать движку в `configure`.
    static func engineConfig(_ modes: Set<ProcessingMode>) -> [String: JSONValue] {
        [
            "keep": .array(modes.filter { !$0.isOptIn }.map { .string($0.engineKind) }),
            "hide": .array(modes.filter(\.isOptIn).map { .string($0.engineKind) }),
        ]
    }

    /// Флажок в панели «Скрыто»: галочка значит «скрывать», как у всех строк панели.
    var hideTitle: String {
        switch self {
        case .keepDates: "Скрывать все даты"
        case .keepLinks: "Скрывать все ссылки"
        case .hideOrgs: "Скрывать организации"
        }
    }
    /// Обратное действие — пункт меню у заголовка группы.
    var revealTitle: String {
        switch self {
        case .keepDates: "Не скрывать даты"
        case .keepLinks: "Не скрывать ссылки"
        case .hideOrgs: "Не скрывать организации"
        }
    }
    /// Имя действия для «Правка → Отменить»: существительное, потому что система ставит перед ним глагол
    /// («Не применять: Показ дат»), и «Не скрывать» дало бы двойное отрицание.
    func undoName(hiding: Bool) -> String {
        let what = switch self { case .keepDates: "дат"; case .keepLinks: "ссылок"; case .hideOrgs: "организаций" }
        return (hiding ? "Скрытие " : "Показ ") + what
    }
    /// Для VoiceOver у включённого флажка: к чему приведёт снятие. Зрячему — без всплывающей подсказки:
    /// «Скрывать все даты» с галочкой говорит само за себя.
    var unhideHint: String {
        switch self {
        case .keepDates: "Даты увидит нейросеть — для сроков и графиков. Даты рождения останутся скрытыми"
        case .keepLinks: "Ссылки увидит нейросеть — если они публичные"
        case .hideOrgs: "Названия компаний снова увидит нейросеть"
        }
    }
    /// Действие капсулы «Даты видны» в строке ввода.
    var rehide: String {
        switch self {
        case .keepDates: "Снова скрывать даты"
        case .keepLinks: "Снова скрывать ссылки"
        case .hideOrgs: "Снова показывать организации"
        }
    }
    var chip: String {
        switch self {
        case .keepDates: "Даты видны"
        case .keepLinks: "Ссылки видны"
        case .hideOrgs: "Организации скрыты"
        }
    }
    var glyph: GlyphKind {
        switch self {
        case .keepDates: .calendar
        case .keepLinks: .link
        case .hideOrgs: .building
        }
    }
}

/// Один документ, текст или ответ нейросети внутри обработки.
@MainActor
@Observable
final class Job: Identifiable {
    enum Kind: String, Codable, Sendable { case file, text, reply }

    enum State {
        case queued
        case reading(Double)
        case cleaning(Double)
        case done
        case failed(String)

        var isActive: Bool {
            switch self { case .queued, .reading, .cleaning: true; default: false }
        }
    }

    let id: UUID
    weak var processing: Processing?
    let kind: Kind
    /// Что видит пользователь: имя исходного файла, «Текст 2», «Ответ нейросети».
    let name: String
    let number: Int
    let createdAt: Date
    /// Копия входа в `.nekto/<обработка>/items/<id>/`: исходный файл, текст или распознанный текст скана.
    var source: URL?
    /// Вход — уже извлечённый текст (PDF, скан, RTF): при пересчёте распознавать заново не нужно.
    var sourceIsExtractedText = false
    /// Файл, который пользователь прикрепил, — до того как копия ляжет в `.nekto` (не сохраняется).
    var origin: URL?
    /// Вставленный текст или ответ нейросети — для пузыря сообщения в ленте.
    var inputText: String?
    var state: State = .queued
    /// Последний готовый результат. Пока документ пересчитывается после правки, показываем его.
    var output: JobOutput? { didSet { extendRoster() } }
    var task: Task<Void, Never>?
    /// Значения этого документа в панели «Скрыто» (метки). Список только растёт, пока приложение открыто:
    /// строка не пропадает из-за того, что её сняли или включили режим, — она остаётся на месте и сереет.
    var roster: Set<String> = []
    /// Правка пришла, пока документ пересчитывался со старыми решениями: пересчитать ещё раз.
    @ObservationIgnored var needsRerun = false
    /// Прочитан из истории недосчитанным (`Store`, `ItemRecord.stale`): после запуска пересчитывается сам.
    @ObservationIgnored var staleOutput = false

    init(id: UUID = UUID(), processing: Processing, kind: Kind, name: String, number: Int, createdAt: Date = Date()) {
        self.id = id
        self.processing = processing
        self.kind = kind
        self.name = name
        self.number = number
        self.createdAt = createdAt
    }

    var isReply: Bool { kind == .reply }

    /// Документ уже показан, а сейчас обновляется после правки: показываем прежний результат, а не работу.
    var isRefreshing: Bool { output != nil && state.isActive }

    var fileKind: FileKind {
        switch kind {
        case .file: FileKind(extension: (name as NSString).pathExtension)
        case .text: .text
        case .reply: .reply
        }
    }

    var hiddenCount: Int { output?.tagCounts.reduce(0) { $0 + $1.count } ?? 0 }
}

struct JobOutput: Sendable {
    var fileURL: URL?
    /// Что уходит в чат по «Скопировать»: текст файла или Markdown документа (у ответа — ответ с данными).
    var text: String
    /// Что видит человек: форма документа. Нет — старая история или текст без формы: строка — абзац.
    var layout: DocumentLayout? = nil
    var replaced: Int
    var notes: [String]
    var tagCounts: [(tag: String, count: Int)]
    /// Для ответа нейросети: где в тексте вернулись исходные данные и какие метки не из этой обработки.
    var restored: [NSRange] = []
    var unknownTags: [String] = []

    var document: DocumentLayout { layout ?? .plain(text) }
}

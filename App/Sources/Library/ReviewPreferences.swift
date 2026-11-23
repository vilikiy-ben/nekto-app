import Foundation
import Observation

/// Что панель «Скрыто» помнит между обработками и запусками.
///
/// - **Свёрнутые группы** — по типу данных, а не по документу: кто свернул «Номера», тому номера не нужны
///   и в следующем договоре.
/// - **Режимы для новых обработок** — последний выбор. Включили «Скрывать организации» один раз — следующая
///   обработка начнётся с ним, и капсула «Организации скрыты» в строке ввода главного экрана видна до отправки
///   (`ComposerView.chips`): решение не прячется, его можно снять до того, как документ уйдёт в работу.
///   В ленте открытой обработки капсул нет: там режим — флажок группы в «Скрыто».
///
/// Отладочные сценарии (`-NektoFolder`, `-NektoOnboarding`) пишут в отдельный набор настроек, чтобы снимки
/// и проверки не меняли настройки человека, а запоминание всё равно проверялось между запусками.
/// `-NektoResetReviewPrefs YES` стирает этот набор перед запуском.
@MainActor
@Observable
final class ReviewPreferences {
    private(set) var collapsedKinds: Set<String>
    private(set) var defaultModes: Set<ProcessingMode>

    @ObservationIgnored private let store: UserDefaults

    private static let collapsedKey = Brand.key("ReviewCollapsedKinds")
    private static let modesKey = Brand.key("DefaultModes")

    init(store: UserDefaults? = nil) {
        let store = store ?? Self.defaultStore()
        self.store = store
        collapsedKinds = Set(store.stringArray(forKey: Self.collapsedKey) ?? [])
        defaultModes = Set((store.stringArray(forKey: Self.modesKey) ?? []).compactMap(ProcessingMode.init(rawValue:)))
    }

    // MARK: Группы

    func isCollapsed(_ kind: String) -> Bool { collapsedKinds.contains(kind) }

    func setCollapsed(_ kinds: some Sequence<String>, _ collapsed: Bool) {
        var next = collapsedKinds
        for kind in kinds { if collapsed { next.insert(kind) } else { next.remove(kind) } }
        guard next != collapsedKinds else { return }
        collapsedKinds = next
        store.set(next.sorted(), forKey: Self.collapsedKey)
    }

    func toggleCollapsed(_ kind: String) { setCollapsed([kind], !isCollapsed(kind)) }

    // MARK: Режимы

    func rememberModes(_ modes: Set<ProcessingMode>) {
        guard modes != defaultModes else { return }
        defaultModes = modes
        store.set(modes.map(\.rawValue).sorted(), forKey: Self.modesKey)
    }

    // MARK: Где хранится

    private static func defaultStore() -> UserDefaults {
        let d = UserDefaults.standard
        let scenario = DebugDefaults.string("Folder") != nil || DebugDefaults.string("Onboarding") != nil
        guard scenario, let suite = UserDefaults(suiteName: Brand.key("Scenario")) else { return d }
        if DebugDefaults.flag("ResetReviewPrefs") {
            for key in [collapsedKey, modesKey] { suite.removeObject(forKey: key) }
        }
        return suite
    }
}

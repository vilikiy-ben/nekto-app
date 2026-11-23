import Foundation

/// Шаги онбординга по порядку экранов.
///
/// Первые три живут внутри фазы `.welcome` (`AppModel.welcomePage`), остальные следуют за фазой:
/// ход установки — `.setup`, выбор папки — `.ready`, пока папок нет (`needsFolder`).
enum OnboardingStep: Int, CaseIterable, Comparable, Identifiable, Sendable {
    case intro      // 1 · «Добро пожаловать в Nekto!»
    case how        // 2 · «Как обезличить документ»
    case install    // 3а · «Нужно скачать LLM-модель»
    case setup      // 3б · «Идёт установка»
    case folder     // 4 · «Куда сохранять документы?»

    var id: Int { rawValue }
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// Номер чёрточки в подвале: у 3а и 3б одна и та же, третья.
    var dash: Int {
        switch self {
        case .intro: 1
        case .how: 2
        case .install, .setup: 3
        case .folder: 4
        }
    }

    /// Имя шага для `-NektoOnboarding` (`DebugScenario`).
    init?(debugName: String) {
        switch debugName {
        case "intro": self = .intro
        case "how": self = .how
        case "install": self = .install
        default: return nil
        }
    }
}

extension AppModel {
    /// Окно показывает онбординг: модели ещё нет или не выбрана ни одна папка.
    var inOnboarding: Bool { phase == .welcome || phase == .setup || needsFolder }

    var onboardingStep: OnboardingStep {
        switch phase {
        case .launching, .welcome: welcomePage
        case .setup: .setup
        case .ready: .folder
        }
    }

    /// «Назад» есть на шагах 2 и 3а: на первом некуда, а начатую установку назад не отмотать.
    var canStepBack: Bool { phase == .welcome && welcomePage > .intro }

    /// Шаг назад: кнопка «Назад», Esc и ⌘[ (меню «Вид → Назад»).
    func stepBack() {
        guard canStepBack, let previous = OnboardingStep(rawValue: welcomePage.rawValue - 1) else { return }
        welcomePage = previous
    }
}

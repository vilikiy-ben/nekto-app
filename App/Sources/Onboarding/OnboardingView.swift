import AppKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.phase == .launching {
                Ink.canvas
            } else if model.inOnboarding {
                // Одна и та же ветка на всех шагах, включая установку и выбор папки: вид и сцена в нём
                // не пересоздаются при смене фазы.
                OnboardingView().transition(.opacity)
            } else {
                ShellView().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: model.inOnboarding)
        .background(Ink.canvas)
        .ignoresSafeArea()
    }
}

/// Первый запуск: знакомство, как это работает, установка, рабочая папка (сцены — `App/Onboarding/`).
///
/// Слева панель со сценой (`SceneView`), справа колонка 420 pt. Заголовок стоит на одной высоте на всех шагах:
/// высота колонки — по самому высокому шагу (все шаги раскладываются невидимо под текущим). Подвал — чёрточки шагов
/// и кнопки — на одном месте. Раскладка по размеру окна — `OnboardingLayout`.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Шаг, с которого пришли: по нему новый шаг въезжает справа (дальше) или слева (назад).
    @State private var previous: OnboardingStep = .intro
    @State private var contentHeight: CGFloat = 0
    /// Где окно рисует кнопки «закрыть / свернуть / развернуть»: панель рисунка уходит под них, если не опустить её.
    @State private var controls: CGRect = .zero
    @State private var folder = FolderChoice()

    private var step: OnboardingStep { model.onboardingStep }

    var body: some View {
        GeometryReader { geo in
            let layout = OnboardingLayout(size: geo.size, content: contentHeight, controls: controls)
            ZStack(alignment: .topLeading) {
                SceneView(spec: scene)
                    .frame(width: layout.panel.width, height: layout.panel.height)
                    .padding(.leading, layout.panel.minX)
                    .padding(.top, layout.panel.minY)
                    .accessibilityHidden(true)

                columns
                    .frame(width: layout.column, alignment: .topLeading)
                    .padding(.leading, layout.columnX)
                    .padding(.top, layout.top)

                footer
                    .frame(width: layout.column, height: OnboardingLayout.button)
                    .padding(.leading, layout.columnX)
                    .padding(.top, layout.footerY)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .background(Ink.canvas)
        .onWindowControlsChange { controls = $0 }
        .onAppear { previous = step }
        .onChange(of: step) { _, new in previous = new }
    }

    private var scene: SceneSpec {
        switch step {
        case .intro: .door
        case .how: .drop
        case .install: .monolithReady
        case .setup: .monolith(installed: model.installer.overall)
        case .folder: .folder
        }
    }

    // MARK: Колонка

    /// Все шаги невидимо — ради высоты самого высокого; поверх — текущий.
    private var columns: some View {
        ZStack(alignment: .topLeading) {
            ForEach(OnboardingStep.allCases) { s in
                StepColumn(step: s, folder: $folder).hidden().disabled(true).accessibilityHidden(true)
            }
            StepColumn(step: step, folder: $folder)
                .id(step)
                .transition(columnTransition)
        }
        .animation(.easeInOut(duration: 0.3), value: step)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
    }

    /// Прежний шаг гаснет на месте, новый проявляется и въезжает на 16 pt со стороны, куда идём.
    /// С «Уменьшить движение» — только растворение.
    private var columnTransition: AnyTransition {
        let fadeIn = AnyTransition.opacity.animation(.easeOut(duration: 0.3).delay(0.1))
        let insertion = reduceMotion || DebugScenario.reduceMotion ? fadeIn
            : fadeIn.combined(with: .offset(x: step >= previous ? Space.l : -Space.l).animation(.easeOut(duration: 0.4).delay(0.1)))
        return .asymmetric(insertion: insertion, removal: .opacity.animation(.easeIn(duration: 0.15)))
    }

    // MARK: Подвал

    private var footer: some View {
        HStack(spacing: 0) {
            StepDashes(current: step.dash)
            Spacer(minLength: Space.l)
            ZStack(alignment: .trailing) {
                buttons
                    .id(ButtonsKey(step: step, failed: model.installer.errorMessage != nil, done: model.installer.isDone))
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: step)
    }

    private struct ButtonsKey: Hashable { let step: OnboardingStep; let failed: Bool; let done: Bool }

    /// Кнопки шага. Цели — конкретные шаги, а не «следующий»: повторное нажатие на гаснущую кнопку ничего не меняет.
    @ViewBuilder private var buttons: some View {
        HStack(spacing: Space.s) {
            if model.canStepBack {
                Button("Назад") { model.stepBack() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            switch step {
            case .intro: primary("Дальше") { model.welcomePage = .how }
            case .how: primary("Дальше") { model.welcomePage = .install }
            case .install: primary("Установить") { if model.phase == .welcome { model.startSetup() } }
            case .setup:
                // Кнопок нет: после установки приложение само переходит к папке. При ошибке — повторить.
                if model.installer.errorMessage != nil, !model.installer.isRunning {
                    primary("Повторить") { model.startSetup() }
                }
            case .folder: primary("Начать работу") { folder.apply(to: model) }
            }
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
    }
}

/// Где что стоит в окне. По умолчанию (1180 × 780) — как в макете, кроме
/// верха панели: она начинается под кнопками окна, слева и снизу отступ 10; колонка 420, заголовок на y = 200,
/// подвал на y = 700.
///
/// - Панель — во всю высоту окна, ширина по пропорции сцены 548 : 760, но так, чтобы справа оставались колонка
///   и поля по 24. Сверху она начинается под кнопками окна (`controls`) с тем же зазором, что над ними:
///   полоса заголовка скрыта, и без этого кнопки лежали бы на рисунке. В полноэкранном режиме кнопок нет — отступ 10. В узком окне панель уже пропорции — сцена вписывается в неё целиком, вокруг та же бумага.
/// - Колонка — по центру правой части; уже 420 только если правая часть меньше колонки с полями.
/// - Заголовок — на той же доле высоты окна, что в макете (200 / 780), но выше, если иначе самый высокий шаг
///   не помещается над подвалом с зазором 24. Высота колонки одна на все шаги, поэтому и заголовок один.
/// - Подвал — 40 pt от нижнего края.
struct OnboardingLayout {
    /// Отступ панели от краёв окна: панель 16 концентрична углу окна 26.
    static let inset: CGFloat = Space.s + Space.xxs
    static let columnWidth: CGFloat = 420
    static let art = CGSize(width: 548, height: 760)
    /// Высота кнопок `PrimaryButtonStyle` / `SecondaryButtonStyle`, она же высота подвала.
    static let button: CGFloat = 40

    let panel: CGRect
    let column: CGFloat
    let columnX: CGFloat
    let top: CGFloat
    let footerY: CGFloat

    init(size: CGSize, content: CGFloat, controls: CGRect = .zero) {
        let inset = Self.inset
        let margin = Space.xl
        let panelTop = controls.isEmpty ? inset : max(inset, controls.maxY + controls.minY)
        let height = max(0, size.height - panelTop - inset)
        let proportional = height * Self.art.width / Self.art.height
        let width = max(0, min(proportional, size.width - inset - Self.columnWidth - 2 * margin))
        panel = CGRect(x: inset, y: panelTop, width: width, height: height)
        let right = panel.maxX
        column = max(0, min(Self.columnWidth, size.width - right - 2 * margin))
        columnX = right + (size.width - right - column) / 2
        footerY = size.height - Space.xxl - Space.s - Self.button
        let ideal = (size.height * 200 / 780).rounded()
        top = max(Space.xxl, min(ideal, footerY - Space.xl - content))
    }
}

/// Колонка шага: заголовок, текст, блок шага.
private struct StepColumn: View {
    @Environment(AppModel.self) private var model
    let step: OnboardingStep
    @Binding var folder: FolderChoice

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: Space.m) {
                Text(RU.t(title))
                    .font(Typo.display.weight(.semibold))
                    .foregroundStyle(Ink.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let text {
                    Text(RU.t(text))
                        .font(Typo.body)
                        .lineSpacing(OnboardingText.leading)
                        .foregroundStyle(Ink.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            block
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var failed: Bool { model.installer.errorMessage != nil }

    private var title: String {
        switch step {
        case .intro: "Добро пожаловать в \(Brand.name)!"
        case .how: "Как обезличить документ"
        case .install: "Нужно скачать LLM-модель"
        // Пока установка стоит с ошибкой, «Идёт установка» было бы неправдой.
        case .setup: failed ? "Установка прервалась" : "Идёт установка"
        case .folder: "Куда сохранять документы?"
        }
    }

    private var text: String? {
        switch step {
        case .intro:
            "\(Brand.name) находит в документах имена, телефоны, адреса, паспортные данные и другие сведения о людях и заменяет их метками вроде [ФИО_1]. Получается копия без личных данных, которую можно отправить, например, в ИИ-чат или подрядчику. \(Brand.name) работает с Word, PDF, Excel, презентациями, письмами и сканами, а документы обрабатывает прямо на этом Mac и никуда не отправляет."
        case .how: nil
        case .install:
            "Модель будет находить личные данные в ваших документах. Она работает на этом Mac, поэтому документы не уйдут в интернет. Модель и всё нужное для её запуска весят около 0,8 ГБ, на диске понадобится около 1,7 ГБ. Скачать их нужно один раз, дальше \(Brand.name) будет работать без интернета."
        case .setup:
            "Время зависит от скорости интернета. Окно можно свернуть, установка продолжится, а после неё останется выбрать папку для готовых документов."
        case .folder:
            "Выберите папку на этом Mac, куда \(Brand.name) будет сохранять обезличенные копии. Позже вы сможете добавить другие папки, например отдельную для каждого проекта."
        }
    }

    @ViewBuilder private var block: some View {
        switch step {
        case .intro: SpecimenCard()
        case .how: HowSteps()
        case .install: InstallCard(installer: model.installer, live: false)
        case .setup:
            VStack(alignment: .leading, spacing: Space.l) {
                InstallCard(installer: model.installer, live: true)
                if let error = model.installer.errorMessage {
                    Text(error)
                        .font(Typo.callout)
                        .foregroundStyle(Ink.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .folder: FolderCard(choice: $folder)
        }
    }
}

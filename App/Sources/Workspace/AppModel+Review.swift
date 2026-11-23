import AppKit
import Foundation

/// Решения в панели «Скрыто», которые затрагивают сразу несколько значений, и «Отменить» для всех решений.
///
/// Флажок группы ведёт себя как системный флажок над списком флажков (HIG → Toggles, «mixed state»):
/// часть скрыта или ничего — щелчок скрывает все; всё скрыто — открывает все. У типов с режимом (даты, ссылки,
/// организации) «открыть все» — это сам режим: он действует и на значения, которых ещё нет (новые документы
/// обработки), а решения по отдельным значениям ждут под ним и возвращаются, когда тип снова скрывают.
///
/// Каждое решение отменяется через ⌘Z: снятая по ошибке галочка — это данные, ушедшие бы в чат, поэтому
/// исправление должно быть в одно нажатие, как в любом редакторе. Имена действий — существительные
/// («Показ всех «ФИО»»): система ставит перед ними свой глагол («Не применять:»).
extension AppModel {

    func toggleGroup(_ group: DocumentReview.Group, in p: Processing) {
        if let mode = group.mode {
            if group.locked { return setType(mode, hidden: true, in: p) }
            if group.entries.isEmpty || group.check == .on { return setType(mode, hidden: false, in: p) }
        } else if group.check == .on {
            return setHidden(group.entries, false, kind: group.kind, in: p)
        }
        setHidden(group.entries, true, kind: group.kind, in: p)
    }

    /// Скрывать или нет каждое из значений — одним решением и одной отменой.
    func setHidden(_ entries: [MappingEntry], _ hidden: Bool, kind: String, in p: Processing) {
        let changing = entries.filter { !p.keptByMode($0.kind) && p.decision($0) != hidden }
        guard !changing.isEmpty else { return }
        let name = KindNames.title(kind)
        registerUndo(in: p, (hidden ? "Скрытие всех «" : "Показ всех «") + name + "»")
        for e in changing { p.desired[e.placeholder] = hidden }
        syncEdits(p)
    }

    /// Тип целиком: у дат и ссылок «скрывать» — это отсутствие режима, у организаций — его наличие.
    private func setType(_ mode: ProcessingMode, hidden: Bool, in p: Processing) {
        setMode(mode, mode.isOptIn ? hidden : !hidden, in: p)
    }

    // MARK: Отменить

    /// Запомнить решения до правки. Отмена сама записывает обратное действие — так работает «Повторить».
    func registerUndo(in p: Processing, _ name: String) {
        guard let undo = Self.undoManager else { return }
        let before = p.decisionSnapshot
        undo.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restore(before, in: p, name: name) }
        }
        undo.setActionName(name)
    }

    private func restore(_ snapshot: DecisionSnapshot, in p: Processing, name: String) {
        guard !p.isDeleted else { return }
        registerUndo(in: p, name)
        if p.modes != snapshot.modes {
            p.touchedModes.formUnion(p.modes.symmetricDifference(snapshot.modes))
            p.modes = snapshot.modes
            p.edits.modesChanged = true
            reviewPrefs.rememberModes(snapshot.modes)
        }
        for e in p.mapping {
            if let hidden = snapshot.hidden[e.placeholder], p.decision(e) != hidden { p.desired[e.placeholder] = hidden }
        }
        syncEdits(p)
    }

    /// Тот же менеджер, что у строки ввода (`@Environment(\.undoManager)`): у окна. Пункт «Правка → Отменить»
    /// идёт по цепочке ответчиков и доходит до окна, где бы ни стоял фокус, кроме поля с собственной историей.
    static var undoManager: UndoManager? {
        (NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain })?.undoManager
    }
}

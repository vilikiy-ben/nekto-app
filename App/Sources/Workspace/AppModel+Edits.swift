import Foundation

/// Правки пользователя для движка: «скрыть» выделенное — по порядку; галочки и режимы — последним решением.
struct EditQueue {
    var forced: [(text: String, kind: String)] = []
    /// Режимы, которые движок уже знает. `nil` — сессия ещё не поднята.
    var engineModes: Set<ProcessingMode>?
    /// Режим сменили, а документы посчитаны со старым. Отдельно от `engineModes`: сессия, поднятая после
    /// перезапуска, сразу получает новые режимы, но документы от этого не пересчитываются.
    var modesChanged = false
    var running = false
    /// Пока шла отправка, пришли новые правки.
    var again = false

    /// Правок, не дошедших до движка, нет.
    var isIdle: Bool { !running && forced.isEmpty }
}

/// Правки в панели «Скрыто», в контекстном меню текста и в строке ввода.
///
/// Решение пользователя записывается сразу (`Processing.desired`, `modes`), и интерфейс его показывает
/// в том же кадре (`Library/Review`). Потом правки по одной уходят движку: несколько быстрых щелчков по одной
/// строке — это одно последнее решение, а не очередь запросов. Затем документы пересчитываются: модель
/// при этом не запускается (движок помнит находки), открытый документ — первым.
extension AppModel {

    /// Не скрывать (ложное срабатывание) или снова скрыть значение с этой меткой.
    func setHidden(_ placeholder: String, _ hidden: Bool, in p: Processing) {
        guard let entry = p.byPlaceholder[placeholder], !p.keptByMode(entry.kind), p.isHidden(entry) != hidden else { return }
        registerUndo(in: p, (hidden ? "Скрытие «" : "Показ «") + entry.original + "»")
        p.desired[placeholder] = hidden
        syncEdits(p)
    }

    /// Скрыть то, что модель пропустила. Новая строка появится в панели, когда документ пересчитается.
    func hide(_ text: String, as kind: String, in p: Processing) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2 else { return }
        Teaching.learned(HideMissedTip())
        p.edits.forced.append((value, kind))
        syncEdits(p)
    }

    /// Капсула режима на главном экране — режим будущей обработки. Последний выбор становится выбором
    /// для новых обработок (`ReviewPreferences`). В открытой обработке режим — флажок группы в «Скрыто» (`setMode`).
    func toggleDraftMode(_ mode: ProcessingMode) {
        if composer.modes.contains(mode) { composer.modes.remove(mode) } else { composer.modes.insert(mode) }
        reviewPrefs.rememberModes(composer.modes)
    }

    func setMode(_ mode: ProcessingMode, _ on: Bool, in p: Processing) {
        guard p.modes.contains(mode) != on else { return }
        registerUndo(in: p, mode.undoName(hiding: mode.hides(in: on ? p.modes.union([mode]) : p.modes.subtracting([mode]))))
        if on { p.modes.insert(mode) } else { p.modes.remove(mode) }
        p.touchedModes.insert(mode)
        p.edits.modesChanged = true
        reviewPrefs.rememberModes(p.modes)
        syncEdits(p)
    }

    // MARK: Отправка движку

    func syncEdits(_ p: Processing) {
        guard !p.edits.running else { p.edits.again = true; return }
        p.edits.running = true
        Task {
            var changed = false
            repeat {
                p.edits.again = false
                do {
                    changed = try await pushEdits(p) || changed
                } catch {
                    // Движок правку не принял: интерфейс возвращается к тому, что он знает.
                    NSLog("\(Brand.name): правка не применилась: \(error.localizedDescription)")
                    p.desired.removeAll()
                    p.edits.forced.removeAll()
                    if let known = p.edits.engineModes { p.modes = known }
                }
            } while p.edits.again
            p.edits.running = false
            if changed {
                // Сначала пометить документы к пересчёту, потом записать: если приложение закроется раньше,
                // чем они пересчитаются, история запомнит, что их результат устарел (`ItemRecord.stale`).
                reprocess(p)
                Store.save(p)
            }
        }
    }

    /// Отправляет движку всё, в чём решения расходятся с его состоянием. `true` — что-то поменялось.
    private func pushEdits(_ p: Processing) async throws -> Bool {
        try await ensureSession(p)
        let session = JSONValue.string(p.id.uuidString)
        var changed = false
        while !p.edits.forced.isEmpty {
            let f = p.edits.forced.removeFirst()
            absorb(try await EngineClient.shared.call("force", ["session": session, "text": .string(f.text), "kind": .string(f.kind)]), into: p)
            changed = true
        }
        if p.edits.engineModes != p.modes {
            let modes = p.modes
            absorb(try await EngineClient.shared.call("configure",
                ["session": session].merging(ProcessingMode.engineConfig(modes)) { a, _ in a }), into: p)
            p.edits.engineModes = modes
        }
        if p.edits.modesChanged {
            p.edits.modesChanged = false
            changed = true
        }
        for (placeholder, hidden) in p.desired {
            // allowed == hidden: движок думает иначе, чем решил пользователь.
            guard let entry = p.byPlaceholder[placeholder], entry.allowed == hidden else { continue }
            absorb(try await EngineClient.shared.call(hidden ? "unallow" : "allow", ["session": session, "placeholder": .string(placeholder)]), into: p)
            changed = true
        }
        // Подтверждённые решения больше не нужны: движок говорит то же самое.
        p.desired = p.desired.filter { placeholder, hidden in p.byPlaceholder[placeholder].map { $0.allowed == hidden } ?? false }
        return changed
    }

    /// Пересчитать документы обработки с новыми решениями. Открытый в редакторе — первым; тот, что считается
    /// прямо сейчас со старыми решениями, будет посчитан ещё раз сразу после.
    private func reprocess(_ p: Processing) {
        let open = readerJob
        let all = p.items.filter { !$0.isReply && ($0.output != nil || $0.source != nil) }
        let jobs = all.filter { $0 === open } + all.filter { $0 !== open }
        var front: [Job] = []
        for job in jobs {
            switch job.state {
            case .reading, .cleaning:
                job.needsRerun = true
            default:
                queue.removeAll { $0 === job }
                job.state = .queued
                front.append(job)
            }
        }
        queue.insert(contentsOf: front, at: 0)
        live[p.id] = p
        pump()
    }
}

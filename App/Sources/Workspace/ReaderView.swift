import SwiftUI

/// Редактор: документ целиком, с метками и правками. Назад — стрелка ‹, название обработки вверху или Esc.
struct ReaderView: View {
    @Environment(AppModel.self) private var model
    let job: Job
    let processing: Processing

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: Metrics.topBar)
            if let output = job.output {
                // Пока документ обновляется после правки, виден прежний текст как есть: решение уже показано
                // цветом «пилюль», а новый текст встанет на место точечно (`DocumentView` раскладывает заново только изменённое).
                let document = output.document
                DocumentView(document: document, highlight: job.isReply ? .restored : .placeholders,
                              originals: processing.originals, decisions: job.isReply ? TextDecisions() : processing.textDecisions,
                              onHide: job.isReply ? nil : { model.hide($0, as: $1, in: processing) },
                              onUnhide: job.isReply ? nil : { model.setHidden($0, false, in: processing) },
                              onRehide: job.isReply ? nil : { model.setHidden($0, true, in: processing) },
                              spotlight: model.spotlightRequest,
                              onHoverTag: job.isReply ? nil : { model.hoveredTag = $0 })
                    // Проза — колонкой для чтения; таблицам нужна вся ширина окна.
                    .frame(maxWidth: document.hasTables ? .infinity : 860)
                    .frame(maxWidth: .infinity)
                Rectangle().fill(Ink.line).frame(height: 1)
                footer(output)
            } else {
                Spacer()
                ShimmerText(text: "Документ ещё обрабатывается…")
                Spacer()
            }
        }
        .onExitCommand { model.closeReader() }
    }

    /// Подвал: файл (тащится в чат), счётчик и те же действия, что под карточкой в ленте.
    private func footer(_ output: JobOutput) -> some View {
        HStack(spacing: Space.m) {
            if let file = output.fileURL {
                HStack(spacing: Space.s) {
                    FileIcon(kind: job.isReply ? .reply : FileKind(url: file), size: 18)
                    Text(file.lastPathComponent).font(Typo.caption.weight(.medium)).foregroundStyle(Ink.text2)
                        .lineLimit(1).truncationMode(.middle)
                    Glyph(kind: .grip, size: 12, weight: 1.6).foregroundStyle(Ink.text3)
                }
                .padding(.horizontal, Space.s + 2).frame(height: Size.compact)
                .frame(minWidth: 120, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Ink.hover))
                .modifier(DraggableFile(url: file))
            }
            // В узком окне первым уступает счётчик (он есть в панели «Скрыто»), подпись кнопки — никогда.
            // Обновление после правки обычно короче мгновения; подпись появляется, только если оно затянулось.
            ViewThatFits(in: .horizontal) {
                SlowWorkHint(active: job.isRefreshing, text: "Обновляю файл…") {
                    let label = count(output)
                    Text(label).contentTransition(.numericText()).animation(.snappy(duration: 0.2), value: label)
                }
                Color.clear.frame(width: 0, height: 0)
            }
            .font(Typo.caption).monospacedDigit().foregroundStyle(Ink.text2)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .layoutPriority(-1)
            ResultActions(job: job, output: output)
                .fixedSize()
        }
        .padding(.horizontal, Space.l).frame(height: 52)
    }

    private func count(_ output: JobOutput) -> String {
        if job.isReply {
            let n = output.restored.count
            return "Возвращено \(n) \(Plural.ru(n, "значение", "значения", "значений"))"
        }
        // То же число, что в шапке панели «Скрыто»: оба считаются из решений, а не из готового текста.
        let n = DocumentReview(processing: processing, job: job).hiddenCount
        return n == 0 ? "Ничего не скрыто" : "Скрыто \(n) \(Plural.ru(n, "значение", "значения", "значений"))"
    }
}

// Папка для сцены «Папка» (`scenes/b/folder.js`): стенки, наклейка со знаком Nekto и лист с загнутым углом.
// Движение у сцены своё, здесь только рисунок.

const CX = 274;
const BACK = 338;    // верх задней стенки
const FRONT = 440;   // верх передней стенки
const FLOOR = 630;   // низ папки

/** Геометрия папки для сцены. */
export const FOLDER = { CX, FRONT };

/** Тень и задняя стенка с язычком. */
export function folderBack(pen) {
  // Тень под папкой.
  pen.blob(CX + 8, FLOOR + 14, 196, 16, { color: 'tint', id: 'shadow', jitter: 1.2 });

  // Задняя стенка с язычком.
  const back = `M ${CX - 170} ${BACK + 24} Q ${CX - 170} ${BACK} ${CX - 146} ${BACK} L ${CX - 70} ${BACK} L ${CX - 52} ${BACK + 20} L ${CX + 150} ${BACK + 20} Q ${CX + 170} ${BACK + 20} ${CX + 170} ${BACK + 40} L ${CX + 170} ${FLOOR - 20} L ${CX - 170} ${FLOOR - 20} Z`;
  pen.fill(back, { color: 'tint', id: 'back-fill', jitter: 0.8 });
  pen.hatch(back, { angle: 60, gap: 10, w: 1.2, id: 'back-hatch', inset: 6, skip: 0.1 });
  pen.line(back, { id: 'back', w: 2.6 });
}

/** Передняя стенка и наклейка со знаком. */
export function folderFront(pen, { fold = true } = {}) {
  // Передняя стенка.
  const front = `M ${CX - 184} ${FRONT} L ${CX + 184} ${FRONT} L ${CX + 172} ${FLOOR} L ${CX - 172} ${FLOOR} Z`;
  pen.with({ x: 7, y: 8 }, () => pen.fill(front, { color: 'tint', id: 'front-tint', jitter: 1 }));
  pen.fill(front, { id: 'front', jitter: 0.7 });
  pen.line(`M ${CX - 176} ${FRONT + 8} L ${CX + 176} ${FRONT + 8}`, { id: 'front-edge', color: 'sheet', w: 1.6, taper: [8, 8] });
  if (fold) pen.line(`M ${CX - 160} ${FLOOR - 16} L ${CX + 160} ${FLOOR - 16}`, { id: 'front-fold', color: 'sheet', w: 1.4, taper: [6, 6] });

  // Наклейка со знаком Nekto: очки-плашка, как на иконке и в первой сцене. Букв нет.
  pen.with({ x: CX, y: FRONT + 96, rotate: -3 }, () => {
    const label = 'M -70 -32 L 70 -32 L 70 32 L -70 32 Z';
    pen.fill(label, { color: 'sheet', id: 'label-fill', jitter: 0.6 });
    pen.line(label, { id: 'label', w: 2 });
    pen.with({ scale: 0.78, y: 2 }, () => {
      pen.fill('M -62 -14 Q -62 -20 -56 -20 L 56 -20 Q 62 -20 62 -14 L 60 2 C 58 14 46 19 30 19 C 16 19 10 13 6 6 Q 0 -2 -6 6 C -10 13 -16 19 -30 19 C -46 19 -58 14 -60 2 Z', { color: 'mark', id: 'label-mark', jitter: 0.5 });
      pen.fill('M -44 14 L -32 -16 L -25 -16 L -37 14 Z', { color: 'glint', id: 'label-glint', jitter: 0, opacity: 0.85 });
    });
  });
}

/** Лист с загнутым углом. Начало координат — центр листа. */
export function sheet(pen, id, { kind = 'lines', bars = false, opacity = 1, shift = 0 } = {}) {
  if (opacity < 0.05) return;
  const w = 98;
  const h = 126;
  const hw = w / 2;
  const hh = h / 2;
  const outline = `M ${-hw} ${-hh} L ${hw - 22} ${-hh} L ${hw} ${-hh + 22} L ${hw} ${hh} L ${-hw} ${hh} Z`;
  pen.fill(outline, { color: 'sheet', id: `${id}-paper`, jitter: 0.4 });
  pen.line(outline, { id: `${id}-edge`, w: 2.4 });
  pen.line(`M ${hw - 22} ${-hh} L ${hw - 22} ${-hh + 22} L ${hw} ${-hh + 22}`, { id: `${id}-fold`, w: 1.8, taper: [3, 3] });

  if (kind === 'grid') {
    const x0 = -hw + 14;
    const x1 = hw - 14;
    for (let r = 0; r < 5; r++) pen.line(`M ${x0} ${-hh + 34 + r * 16} L ${x1} ${-hh + 34 + r * 16}`, { id: `${id}-r${r}`, w: 1.3, taper: [2, 2] });
    [x0 + 26, x0 + 48].forEach((x, k) => pen.line(`M ${x} ${-hh + 34} L ${x} ${-hh + 98}`, { id: `${id}-c${k}`, w: 1.3, taper: [2, 2] }));
    pen.fill(`M ${x0} ${-hh + 34} L ${x1} ${-hh + 34} L ${x1} ${-hh + 50} L ${x0} ${-hh + 50} Z`, { color: 'tint', id: `${id}-head`, jitter: 0.4 });
  } else if (kind === 'pdf') {
    pen.fill(`M ${-hw + 12} ${-hh + 16} L ${-hw + 50} ${-hh + 16} L ${-hw + 50} ${-hh + 34} L ${-hw + 12} ${-hh + 34} Z`, { id: `${id}-badge`, jitter: 0.5 });
    [0, 1, 2, 3].forEach((k) => pen.line(`M ${-hw + 12} ${-hh + 52 + k * 14} L ${hw - 14 - (k % 2) * 16} ${-hh + 52 + k * 14}`, { id: `${id}-l${k}`, w: 1.4, taper: [2, 2] }));
  } else {
    [0, 1, 2, 3, 4].forEach((k) => {
      const y = -hh + 36 + k * 15;
      const x1 = hw - 14 - ((k + shift) % 3) * 12;
      if (bars && (k === 1 || k === 3)) {
        // Обезличенный лист: вместо имени — плашка-метка.
        const split = -hw + 12 + (k === 1 ? 20 : 34);
        pen.line(`M ${-hw + 12} ${y} L ${split - 6} ${y}`, { id: `${id}-l${k}a`, w: 1.4, taper: [2, 2] });
        pen.fill(`M ${split} ${y - 5} L ${split + 34} ${y - 5} L ${split + 34} ${y + 5} L ${split} ${y + 5} Z`, { id: `${id}-bar${k}`, jitter: 0.5 });
      } else {
        pen.line(`M ${-hw + 12} ${y} L ${x1} ${y}`, { id: `${id}-l${k}`, w: 1.4, taper: [2, 2] });
      }
    });
  }
}

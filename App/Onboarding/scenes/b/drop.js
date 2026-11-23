// Сцена 2 · «Окно». Как обезличить документ.
//
// Окно приложения, нарисованное пером. В нём пунктирная зона для файла; курсор несёт документ и отпускает его
// в окно. Внутри появляется текст, и имена в нём по очереди подсвечиваются синими метками. Это и есть шаги,
// о которых говорит экран: перетащить файл, увидеть, что скрыто.
//
// Своё у сцены: движение по диагонали (курсор несёт файл), без кольца и без падения сверху.
// Цикл 9 с. В кадре 0 файл над окном, зона для файла подсвечена. Всё, что появляется и исчезает, проявляется
// или гаснет; курсор всё время где-то стоит или едет, нигде не перескакивает. Доли цикла (от момента, когда
// курсор берёт файл в углу):
//   0–0,34      курсор несёт файл к окну; с 0,15 зона подсвечивается (заливка проявляется, пунктир толще)
//   0,34–0,42   файл уменьшается и гаснет в зоне; с 0,38 зона гаснет, с 0,42 строка за строкой проявляется текст
//   0,52–0,79   имена по очереди закрашиваются синей плашкой слева направо, как маркером (0,8 с на имя)
//   0,60–0,90   курсор возвращается в угол
//   0,86–0,94   документ гаснет; 0,88–0,98 в углу под курсором проявляется следующий файл, 0,90–0,98 — пустая зона

import { cropMarks } from './common.js';
import { ease, loop, lerp } from '../motion.js';

const W = 548;
const H = 760;
const WIN = { x0: 78, y0: 270, x1: 470, y1: 590, bar: 36 };
const ZONE = { x0: 128, y0: WIN.y0 + WIN.bar + 18, x1: 420, y1: WIN.y1 - 22 };
const ROWS = [
  [[46, false], [70, true], [40, false], [52, false]],
  [[90, false], [64, false], [42, false]],
  [[34, false], [56, false], [78, true]],
  [[62, false], [48, true], [36, false], [44, false]],
  [[110, false], [58, false]],
  [[40, false], [64, true], [70, false]],
];
const FROM = [452, 128]; // файл в углу
const TO = [262, 420];   // файл над зоной
const TIP = [22, 30];    // кончик курсора относительно центра файла

export default {
  id: 'b-drop',
  title: 'Окно',
  loop: 9,
  size: [W, H],
  draw(pen, t) {
    const tt = (t + 0.27) % 1;
    const first = tt < 0.5; // первая половина цикла: файл несут и бросают; вторая — документ и возврат

    pen.layer('window', {}, () => {
      pen.blob(290, 626, 214, 11, { color: 'tint', id: 'shadow', jitter: 1 });
      // Окно.
      const frame = `M ${WIN.x0 + 16} ${WIN.y0} L ${WIN.x1 - 16} ${WIN.y0} Q ${WIN.x1} ${WIN.y0} ${WIN.x1} ${WIN.y0 + 16} L ${WIN.x1} ${WIN.y1 - 16} Q ${WIN.x1} ${WIN.y1} ${WIN.x1 - 16} ${WIN.y1} L ${WIN.x0 + 16} ${WIN.y1} Q ${WIN.x0} ${WIN.y1} ${WIN.x0} ${WIN.y1 - 16} L ${WIN.x0} ${WIN.y0 + 16} Q ${WIN.x0} ${WIN.y0} ${WIN.x0 + 16} ${WIN.y0} Z`;
      pen.with({ x: 9, y: 11 }, () => pen.fill(frame, { color: 'tint', id: 'win-tint', jitter: 1 }));
      pen.fill(frame, { color: 'sheet', id: 'win-paper', jitter: 0 });
      pen.line(frame, { id: 'win', w: 2.8 });
      pen.line([[WIN.x0 + 2, WIN.y0 + WIN.bar], [WIN.x1 - 2, WIN.y0 + WIN.bar]], { id: 'win-bar', w: 1.6, taper: [0, 0] });
      [0, 1, 2].forEach((k) => pen.oval(WIN.x0 + 22 + k * 17, WIN.y0 + WIN.bar / 2, 5, 5, { id: `light${k}`, w: 1.6, taper: [0, 0] }));
    });

    // Пустая зона для файла: пунктир и плюс; пока файл над ней — бледная заливка и пунктир толще.
    const zone = first ? 1 - ease(loop(tt, 0.38, 0.46)) : ease(loop(tt, 0.9, 0.98));
    const hover = first ? ease(loop(tt, 0.15, 0.25)) : 0;
    pen.with({ opacity: zone }, () => {
      if (hover > 0) pen.fill(`M ${ZONE.x0} ${ZONE.y0} L ${ZONE.x1} ${ZONE.y0} L ${ZONE.x1} ${ZONE.y1} L ${ZONE.x0} ${ZONE.y1} Z`, { color: 'tint', id: 'zone-fill', jitter: 0.4, opacity: 0.7 * hover });
      dashedRect(pen, ZONE, 1.6 + 0.6 * hover);
      const zx = (ZONE.x0 + ZONE.x1) / 2;
      const zy = (ZONE.y0 + ZONE.y1) / 2;
      pen.line([[zx - 14, zy], [zx + 14, zy]], { id: 'plus-h', w: 2.6, taper: [1, 1] });
      pen.line([[zx, zy - 14], [zx, zy + 14]], { id: 'plus-v', w: 2.6, taper: [1, 1] });
    });

    // Документ в окне: строки проявляются сверху вниз, затем имена по очереди закрашиваются метками.
    if (tt > 0.42 && tt < 0.94) {
      pen.with({ opacity: 1 - ease(loop(tt, 0.86, 0.94)) }, () => {
        let nameIndex = 0;
        ROWS.forEach((words, r) => {
          const y = ZONE.y0 + 24 + r * 36;
          const shown = ease(loop(tt, 0.42 + r * 0.012, 0.49 + r * 0.012));
          let x = ZONE.x0 + 12;
          words.forEach(([w, name], k) => {
            if (shown > 0) pen.line([[x, y], [x + w, y]], { id: `r${r}-${k}`, w: 2.4, taper: [2, 3], drift: 0.4, opacity: shown });
            if (name) {
              // Плашка растёт слева направо поверх слова и закрывает его целиком. Строится полной
              // и сжимается по ширине (`local`), чтобы край не дрожал, пока она растёт.
              const s0 = 0.52 + (nameIndex++) * 0.06;
              const grow = ease(loop(tt, s0, s0 + 0.09));
              if (grow > 0) pen.with({ x: x - 2, y, scale: [grow, 1], local: true }, () => pen.fill(`M 0 -7 L ${w + 4} -7 L ${w + 4} 7 L 0 7 Z`, { id: `r${r}-${k}-label`, jitter: 0.5 }));
            }
            x += w + 12;
          });
        });
      });
    }

    // Файл в руке курсора: от правого верхнего угла к центру зоны; в зоне уменьшается и гаснет.
    // Следующий файл проявляется в углу, когда курсор вернулся.
    const carry = ease(loop(tt, 0, 0.34));
    if (tt < 0.42 || tt > 0.88) {
      const pos = first ? [lerp(FROM[0], TO[0], carry), lerp(FROM[1], TO[1], carry)] : FROM;
      const opacity = first ? 1 - ease(loop(tt, 0.36, 0.42)) : ease(loop(tt, 0.88, 0.98));
      const scale = first ? 1 - ease(loop(tt, 0.34, 0.42)) * 0.6 : 0.9 + 0.1 * ease(loop(tt, 0.88, 0.98));
      const rotate = first ? -6 * (1 - carry) : -6; // в углу файл лежит чуть наискосок, у окна выпрямляется
      // Слой с трансформацией: значок строится один раз и уменьшается целиком — линии не меняют рисунок.
      pen.with({ opacity }, () => pen.layer('file', { transform: { x: pos[0], y: pos[1], rotate, scale } }, () => fileIcon(pen)));
    }

    // Курсор: несёт файл, стоит над окном, возвращается в угол и ждёт следующий файл.
    const back = ease(loop(tt, 0.6, 0.9));
    const hand = first && tt < 0.34
      ? [lerp(FROM[0], TO[0], carry), lerp(FROM[1], TO[1], carry)]
      : [lerp(TO[0], FROM[0], back), lerp(TO[1], FROM[1], back)];
    pen.layer('cursor', { transform: { x: hand[0] + TIP[0], y: hand[1] + TIP[1] } }, () => cursor(pen));

    pen.layer('crop', {}, () => cropMarks(pen, 60, 92, 488, 690));
  },
};

/** Значок документа: лист с загнутым углом и строками. Начало координат — центр. Гаснет группой (`with({ opacity })`). */
function fileIcon(pen) {
  const outline = 'M -32 -40 L 16 -40 L 32 -24 L 32 40 L -32 40 Z';
  pen.with({ x: 4, y: 5 }, () => pen.fill(outline, { color: 'tint', id: 'file-tint', jitter: 0.5 }));
  pen.fill(outline, { color: 'sheet', id: 'file-paper', jitter: 0 });
  pen.line(outline, { id: 'file', w: 2.4 });
  pen.line('M 16 -40 L 16 -24 L 32 -24', { id: 'file-fold', w: 1.6, taper: [2, 2] });
  [-14, -2, 10, 22].forEach((y, k) => pen.line([[-20, y], [k % 2 ? 8 : 18, y]], { id: `file-l${k}`, w: 1.8, taper: [2, 2] }));
}

/** Курсор-стрелка цветом знака с обводкой цветом бумаги: на светлом графит, на тёмном инвертирован. Начало координат — кончик. */
function cursor(pen) {
  const arrow = 'M 0 0 L 0 30 L 8 23 L 14 36 L 20 33 L 14 21 L 24 21 Z';
  pen.fill(arrow, { color: 'paper', id: 'cursor-halo', jitter: 0 });
  pen.with({ scale: 0.86, x: 1.6, y: 2.6 }, () => pen.fill(arrow, { color: 'mark', id: 'cursor', jitter: 0.2 }));
}

/** Пунктирная рамка зоны для файла. */
function dashedRect(pen, z, w) {
  const sides = [
    [[z.x0, z.y0], [z.x1, z.y0]],
    [[z.x1, z.y0], [z.x1, z.y1]],
    [[z.x1, z.y1], [z.x0, z.y1]],
    [[z.x0, z.y1], [z.x0, z.y0]],
  ];
  sides.forEach(([a, b], s) => {
    const len = Math.hypot(b[0] - a[0], b[1] - a[1]);
    const n = Math.floor(len / 16);
    for (let k = 0; k < n; k++) {
      const f0 = k / n;
      const f1 = f0 + 0.55 / n;
      pen.line([[a[0] + (b[0] - a[0]) * f0, a[1] + (b[1] - a[1]) * f0], [a[0] + (b[0] - a[0]) * f1, a[1] + (b[1] - a[1]) * f1]], { id: `zone${s}-${k}`, w, taper: [1, 1], drift: 0.2 });
    }
  });
}

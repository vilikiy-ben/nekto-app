// Сцена 1 · «Дверь». Добро пожаловать.
//
// Первый экран встречает человека: тяжёлая графитовая дверь в проёме открыта к нему, изнутри на пол ложится свет.
// У входа на стене табличка со знаком Nekto (очки-плашка). Прямой смысл экрана — «входите»; дверь массивная, потому что
// за ней ваши документы и они остаются у вас.
//
// Своё у сцены: поворот на петлях (дверь приоткрывается шире и обратно), свет на полу меняет ширину вместе с ней.
// Цикл 10 с, сумма синусов — без шва. В кадре 0 дверь открыта примерно наполовину.
//
// Створка нарисована на своей плоскости — прямоугольник проёма — и ложится на экран через перспективу
// (`with({ warp })`). Дрожь её краёв и филёнок посчитана один раз на плоскости, поэтому при повороте линии
// не «ползут» и углы не мерцают. Всё, что не двигается (стена, коробка, табличка, метки), — слои для кеша плеера.

import { cropMarks } from './common.js';
import { wave } from '../motion.js';

const W = 548;
const H = 760;
const FLOOR = 620;
const OPEN = { x0: 214, x1: 354, y0: 250 }; // проём
const JAMB = 18; // толщина коробки
const DW = OPEN.x1 - OPEN.x0;
const DH = FLOOR - OPEN.y0;

/** Прямоугольник на плоскости створки: x — от петли (0…DW), y — как на экране (OPEN.y0…FLOOR). */
const rect = (x0, y0, x1, y1) => `M ${x0} ${y0} L ${x1} ${y0} L ${x1} ${y1} L ${x0} ${y1} Z`;

export default {
  id: 'b-door',
  title: 'Дверь',
  loop: 10,
  size: [W, H],
  draw(pen, t) {
    const angle = 64 + wave(t, 1) * 9 + wave(t, 2, 0.2) * 3; // градусы открытия
    const a = (angle * Math.PI) / 180;

    // Пол.
    pen.layer('floor', {}, () => pen.line([[40, FLOOR], [508, FLOOR]], { id: 'floor', w: 2.4, taper: [8, 8] }));

    // Свет из проёма ложится на пол трапецией к зрителю; ширина зависит от того, насколько открыта дверь.
    const spread = 0.55 + 0.45 * Math.sin(a);
    const near = FLOOR + 92;
    pen.fill(
      `M ${OPEN.x0} ${FLOOR} L ${OPEN.x1} ${FLOOR} L ${OPEN.x1 + 120 * spread} ${near} L ${OPEN.x0 - 10 + 40 * (1 - spread)} ${near} Z`,
      { color: 'tint', id: 'light-floor', jitter: 0, opacity: 0.75 },
    );

    pen.layer('wall', {}, () => {
      // Стена вокруг проёма — бледная штриховка, как гравюра; коробка — графит.
      const wall = `M ${OPEN.x0 - JAMB - 70} ${OPEN.y0 - JAMB - 60} L ${OPEN.x1 + JAMB + 70} ${OPEN.y0 - JAMB - 60} L ${OPEN.x1 + JAMB + 70} ${FLOOR} L ${OPEN.x0 - JAMB - 70} ${FLOOR} Z`;
      pen.hatch(wall, { angle: 90, gap: 9, w: 1.4, color: 'tint', id: 'wall-hatch', inset: 0 });
      const jamb = `M ${OPEN.x0 - JAMB} ${FLOOR} L ${OPEN.x0 - JAMB} ${OPEN.y0 - JAMB} L ${OPEN.x1 + JAMB} ${OPEN.y0 - JAMB} L ${OPEN.x1 + JAMB} ${FLOOR} L ${OPEN.x1} ${FLOOR} L ${OPEN.x1} ${OPEN.y0} L ${OPEN.x0} ${OPEN.y0} L ${OPEN.x0} ${FLOOR} Z`;
      pen.fill(jamb, { color: 'mass', id: 'jamb', jitter: 0.5 });

      // Проём светится: цвет блика — белый на светлой теме, светло-голубой на тёмной.
      pen.fill(`M ${OPEN.x0} ${OPEN.y0} L ${OPEN.x1} ${OPEN.y0} L ${OPEN.x1} ${FLOOR} L ${OPEN.x0} ${FLOOR} Z`, { color: 'glint', id: 'doorway', jitter: 0 });
      pen.fill(`M ${OPEN.x0} ${OPEN.y0} L ${OPEN.x1} ${OPEN.y0} L ${OPEN.x1} ${OPEN.y0 + 90} L ${OPEN.x0} ${OPEN.y0 + 40} Z`, { color: 'tint', id: 'doorway-depth', jitter: 0, opacity: 0.5 });
    });

    // Створка на петлях слева, открывается к зрителю: в проекции сужается и чуть растёт по высоте у свободного края.
    const hx = OPEN.x0;
    const ex = hx + DW * Math.cos(a);
    const lift = DW * Math.sin(a) * 0.16;
    // Точка (u, v) плоскости створки (доли ширины и высоты) → экран.
    const at = (u, v) => [hx + (ex - hx) * u, OPEN.y0 + DH * v + u * lift * (v * 2.3 - 1)];
    const warp = ([x, y]) => at(x / DW, (y - OPEN.y0) / DH);
    const leaf = rect(0, OPEN.y0, DW, FLOOR);
    pen.with({ warp: (p) => { const q = warp(p); return [q[0] - 6, q[1] + 8]; } }, () => pen.fill(leaf, { color: 'tint', id: 'leaf-shadow', jitter: 0.6, opacity: 0.8 }));
    pen.with({ warp }, () => {
      pen.fill(leaf, { color: 'mass', id: 'leaf', jitter: 0.5 });
      // Торец створки — тонкая светлая грань у свободного края.
      pen.line([[DW, OPEN.y0], [DW, FLOOR]], { id: 'leaf-edge', color: 'ink', w: 2.6, taper: [0, 0], drift: 0.3 });
      // Филёнки.
      const panel = (u0, v0, u1, v1) => rect(u0 * DW, OPEN.y0 + v0 * DH, u1 * DW, OPEN.y0 + v1 * DH);
      pen.line(panel(0.18, 0.08, 0.82, 0.42), { id: 'panel-top', color: 'paper', w: 1.2, opacity: 0.35, drift: 0.2 });
      pen.line(panel(0.18, 0.56, 0.82, 0.92), { id: 'panel-bottom', color: 'paper', w: 1.2, opacity: 0.35, drift: 0.2 });
    });
    // Ручка: круглая, в проекции сплющивается. Строится одна и та же и сжимается целиком (`local`).
    const [kx, ky] = at(0.86, 0.56);
    const rx = 4.5 * Math.max(0.4, Math.cos(a)) + 2;
    pen.with({ x: kx, y: ky, scale: [rx / 4.5, 1], local: true }, () => pen.blob(0, 0, 4.5, 4.5, { color: 'sheet', id: 'knob', jitter: 0.2 }));

    pen.layer('plate', {}, () => {
      // Табличка со знаком Nekto на стене у входа — прямо, без перспективы, чтобы очки читались.
      const plate = { x: OPEN.x1 + JAMB + 22, y: OPEN.y0 + 120, w: 64, h: 40 };
      const pp = `M ${plate.x} ${plate.y} L ${plate.x + plate.w} ${plate.y} L ${plate.x + plate.w} ${plate.y + plate.h} L ${plate.x} ${plate.y + plate.h} Z`;
      pen.with({ x: 3, y: 4 }, () => pen.fill(pp, { color: 'tint', id: 'plate-tint', jitter: 0.3 }));
      pen.fill(pp, { color: 'sheet', id: 'plate', jitter: 0.3 });
      pen.line(pp, { id: 'plate-edge', w: 1.8 });
      pen.with({ x: plate.x + plate.w / 2, y: plate.y + plate.h / 2 + 1, scale: 0.4 }, () => {
        pen.fill('M -62 -14 Q -62 -20 -56 -20 L 56 -20 Q 62 -20 62 -14 L 60 2 C 58 14 46 19 30 19 C 16 19 10 13 6 6 Q 0 -2 -6 6 C -10 13 -16 19 -30 19 C -46 19 -58 14 -60 2 Z', { color: 'mark', id: 'plate-mark', jitter: 0.3 });
      });
      cropMarks(pen, 60, 92, 488, 690);
    });
  },
};

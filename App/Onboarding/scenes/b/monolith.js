// Сцена 3 · «Монолит». Установка.
//
// Модель — монолит из десяти слоёв. До установки от него только пунктирный контур, над ним висит первый слой
// и знак загрузки. Во время установки уложено столько слоёв, сколько процентов готово, следующий слой
// опускается на место. За монолитом поворачивается гильош.
//
// Состояния: ready (0 %), progress (46 %). Цикл 6 с: слой опускается, гильош поворачивается на 1/16 оборота.
//
// Цикл слоя в progress (доли цикла от момента, когда слой наверху): 0–0,08 проявляется над стопкой,
// 0,1–0,85 опускается, 0,92–1 гаснет на месте, и над стопкой проявляется следующий. Уложенных слоёв
// всегда столько, сколько в состоянии: падающий ложится ровно на верхний и не задевает его.
// В кадре 0 слой на полпути: виден и он, и место, куда он ляжет.

import { guilloche, cropMarks } from './common.js';
import { ease, loop, wave } from '../motion.js';

const W = 548;
const H = 760;
const GROUND = 640;
const FRONT = { x0: 182, x1: 338 };
const DEPTH = { dx: 44, dy: -26 };
const LAYERS = 10;
const LAYER_H = 34;
const TOP = GROUND - LAYERS * LAYER_H;
const CENTER = [274, 420];

export default {
  id: 'b-monolith',
  title: 'Монолит',
  loop: 6,
  size: [W, H],
  states: [
    { name: 'ready', value: { progress: 0 } },
    { name: 'progress', value: { progress: 0.46 } },
  ],
  draw(pen, t, state = { progress: 0 }) {
    // Гильош строится один раз и поворачивается целиком: 1/16 оборота за цикл, при 16 лепестках — без шва.
    pen.layer('guilloche', { transform: { rotate: (t / 16) * 360, origin: CENTER } }, () => guilloche(pen, CENTER[0], CENTER[1], { r0: 140, r1: 236 }));

    const filled = Math.round(state.progress * LAYERS);

    pen.layer('base', { key: filled }, () => {
      // Земля и тень.
      pen.blob(290, GROUND + 6, 170, 12, { color: 'tint', id: 'shadow', jitter: 1 });
      pen.line(`M 70 ${GROUND} L 478 ${GROUND}`, { id: 'ground', w: 2.4, taper: [6, 6] });

      // Силуэт будущего монолита вырезан из гильоша бумагой, по краю — пунктир.
      const { dx, dy } = DEPTH;
      pen.fill(`M ${FRONT.x0} ${GROUND} L ${FRONT.x0} ${TOP} L ${FRONT.x0 + dx} ${TOP + dy} L ${FRONT.x1 + dx} ${TOP + dy} L ${FRONT.x1 + dx} ${GROUND + dy} L ${FRONT.x1} ${GROUND} Z`, { color: 'paper', id: 'ghost', jitter: 0 });
      dashedBox(pen, FRONT.x0, TOP, FRONT.x1, GROUND - filled * LAYER_H);

      // Уложенные слои снизу вверх.
      for (let i = 0; i < filled; i++) layer(pen, GROUND - (i + 1) * LAYER_H, `layer${i}`);
    });

    // Следующий слой опускается на место; до установки он висит над контуром.
    const target = GROUND - (filled + 1) * LAYER_H;
    if (state.progress > 0) {
      const tt = (t + 0.45) % 1;
      const fall = ease(loop(tt, 0.1, 0.85));
      const opacity = ease(loop(tt, 0, 0.08)) * (1 - ease(loop(tt, 0.92, 1)));
      const y = target - 150 * (1 - fall);
      // Слой жёсткий: плеер строит его один раз и только опускает.
      pen.with({ opacity }, () => pen.layer('falling', { transform: { y } }, () => layer(pen, 0, 'falling')));
    } else {
      const bob = wave(t, 1) * 4;
      pen.layer('falling', { transform: { y: TOP - 92 + bob } }, () => layer(pen, 0, 'falling'));
      // Знак загрузки над слоем.
      pen.arrow(`M 274 ${TOP - 200 + bob} L 274 ${TOP - 128 + bob}`, { id: 'download', w: 3, head: 16 });
    }

    pen.layer('crop', {}, () => cropMarks(pen, 60, 92, 488, 690));
  },
};

/** Один слой монолита: синий фасад, грань справа в штриховку, верх бледный. */
function layer(pen, y, id) {
  const { x0, x1 } = FRONT;
  const { dx, dy } = DEPTH;
  const front = `M ${x0} ${y} L ${x1} ${y} L ${x1} ${y + LAYER_H} L ${x0} ${y + LAYER_H} Z`;
  const side = `M ${x1} ${y} L ${x1 + dx} ${y + dy} L ${x1 + dx} ${y + LAYER_H + dy} L ${x1} ${y + LAYER_H} Z`;
  const top = `M ${x0} ${y} L ${x0 + dx} ${y + dy} L ${x1 + dx} ${y + dy} L ${x1} ${y} Z`;
  pen.fill(top, { color: 'tint', id: `${id}-top`, jitter: 0.5 });
  pen.fill(side, { color: 'sheet', id: `${id}-side-paper`, jitter: 0 });
  pen.hatch(side, { angle: 60, gap: 5, w: 1.1, id: `${id}-side-hatch`, inset: 1 });
  pen.fill(front, { id: `${id}-front`, jitter: 0.5 });
  pen.line(`M ${x0 + 8} ${y + LAYER_H - 6} L ${x1 - 8} ${y + LAYER_H - 6}`, { id: `${id}-groove`, color: 'paper', w: 1, taper: [4, 4], opacity: 0.4 });
  pen.line(`M ${x0} ${y} L ${x0 + dx} ${y + dy} L ${x1 + dx} ${y + dy} L ${x1 + dx} ${y + LAYER_H + dy} L ${x1} ${y + LAYER_H}`, { id: `${id}-edge`, w: 1.8, taper: [2, 2] });
}

/** Пунктирный контур объёма от верха `y0` до `y1`. */
function dashedBox(pen, x0, y0, x1, y1) {
  if (y1 - y0 < 4) return;
  const { dx, dy } = DEPTH;
  const segs = [
    [[x0, y0], [x0, y1]],
    [[x1, y0], [x1, y1]],
    [[x1 + dx, y0 + dy], [x1 + dx, y1 + dy]],
    [[x0, y0], [x1, y0]],
    [[x0, y0], [x0 + dx, y0 + dy]],
    [[x0 + dx, y0 + dy], [x1 + dx, y0 + dy]],
    [[x1, y0], [x1 + dx, y0 + dy]],
  ];
  segs.forEach(([a, b], s) => {
    const len = Math.hypot(b[0] - a[0], b[1] - a[1]);
    const n = Math.max(1, Math.floor(len / 14));
    for (let k = 0; k < n; k++) {
      const f0 = k / n;
      const f1 = f0 + 0.55 / n;
      pen.line([[a[0] + (b[0] - a[0]) * f0, a[1] + (b[1] - a[1]) * f0], [a[0] + (b[0] - a[0]) * f1, a[1] + (b[1] - a[1]) * f1]], { id: `dash${s}-${k}`, w: 1.8, taper: [1, 1], drift: 0.2 });
    }
  });
}

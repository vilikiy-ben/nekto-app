// Сцена 4 · «Папка». Рабочая папка.
//
// Синяя папка с наклейкой-знаком, документы внутри и лист, который опускается в папку. Как у остальных сцен —
// метки обреза по углам. Стенки и лист берутся из `scenes/folder.js`, движение у сцены своё.
//
// Цикл 10 с: лист опускается по пунктиру и уходит в папку, документы внутри по очереди приподнимаются.
// Лист (доли цикла от момента, когда он наверху): 0–0,08 проявляется, 0–0,84 опускается и целиком уходит
// за переднюю стенку, 0,80–0,86 гаснет уже невидимым за ней; до 0,72 выпрямляется. Пунктир над листом
// проявляется, выходя из-за верхнего края, и тает, когда лист подходит к папке. Документы трогаются
// и садятся с нулевой скоростью (`rise`), а не с изломом, как у `max(0, sin)`.
// В кадре 0 лист на трети пути — так же, как в макете.

import { folderBack, folderFront, sheet, FOLDER } from '../folder.js';
import { cropMarks } from './common.js';
import { ease, loop, wave, rise } from '../motion.js';

const { CX, FRONT } = FOLDER;
const SHEET_TOP = 90;   // лист наверху
const SHEET_STOP = 420; // где лист останавливался в первой версии (кадр 0 считается по той же кривой)
const SHEET_SINK = 92;  // насколько он уходит ниже, чтобы целиком скрыться за передней стенкой

export default {
  id: 'b-folder',
  title: 'Папка',
  loop: 10,
  size: [548, 760],
  draw(pen, t) {
    pen.layer('folder-back', {}, () => folderBack(pen));

    const tt = (t + 0.3) % 1;
    const settle = ease(loop(tt, 0, 0.72));
    // Прежний спуск до SHEET_STOP плюс досадка вниз; досадка начинается в кадре 0 с нулевой скоростью,
    // поэтому кадр 0 не меняется, а лист не останавливается над стенкой, а уходит за неё.
    const sy = SHEET_TOP + settle * (SHEET_STOP - SHEET_TOP) + ease(loop(tt, 0.3, 0.84)) * SHEET_SINK;
    const shown = ease(loop(tt, 0, 0.08)) * (1 - ease(loop(tt, 0.8, 0.86)));
    if (shown > 0) {
      // Пунктир пути над листом: выходит из-за верхнего края и тает у папки.
      const trail = 1 - ease(loop(sy, 270, 330));
      for (let k = 0; k < 4 && trail > 0; k++) {
        const y = sy - 86 - k * 22;
        const o = trail * ease((y - 24) / 32);
        if (o > 0) pen.line(`M ${CX + 18 + k * 2} ${y} L ${CX + 19 + k * 2} ${y - 10}`, { id: `trail${k}`, w: 2, taper: [2, 2], opacity: o });
      }
      // Лист жёсткий: плеер строит его один раз и только двигает; гаснет он целиком (прозрачность группы).
      pen.with({ opacity: shown }, () => pen.layer('falling', { transform: { x: CX + 14, y: sy, rotate: 8 - settle * 8 } }, () => sheet(pen, 'falling', { bars: true })));
    }

    // Документы в папке — одного вида, строки разной длины.
    const docs = [
      { x: CX - 92, rot: -13, ph: 0 },
      { x: CX + 96, rot: 11, ph: 0.33 },
      { x: CX, rot: -2, ph: 0.66 },
    ];
    docs.forEach((d, i) => {
      const lift = rise(wave(t, 1, d.ph)) * 12;
      pen.layer(`doc${i}`, { transform: { x: d.x, y: FRONT - 34 - lift, rotate: d.rot } }, () => sheet(pen, `doc${i}`, { kind: 'lines', shift: i }));
    });

    pen.layer('folder-front', {}, () => {
      folderFront(pen, { fold: false });
      cropMarks(pen, 60, 92, 488, 690);
    });
  },
};

// Штриховка: параллельные линии внутри замкнутой фигуры. Руками штрихуют неровно —
// линии не доходят до края на разную длину и чуть гуляют по наклону.

import { rng } from './rng.js';

/**
 * @param poly   замкнутый многоугольник (мировые координаты)
 * @param angle  наклон штрихов в градусах
 * @param gap    шаг между штрихами, px
 * @param inset  насколько штрихи не доходят до края, px
 * @returns массив отрезков [[x1, y1], [x2, y2]]
 */
export function hatchLines(poly, { angle = -35, gap = 6, inset = 2, seed = 1, skip = 0 } = {}) {
  const r = rng(seed);
  const a = (angle * Math.PI) / 180;
  const c = Math.cos(a);
  const s = Math.sin(a);
  // Поворачиваем фигуру так, чтобы штрихи стали горизонтальными.
  const rot = poly.map(([x, y]) => [x * c + y * s, -x * s + y * c]);
  const ys = rot.map((p) => p[1]);
  const minY = Math.min(...ys);
  const maxY = Math.max(...ys);
  const segs = [];
  for (let y = minY + gap * (0.5 + r() * 0.4); y < maxY; y += gap * (0.85 + r() * 0.3)) {
    const xs = [];
    for (let k = 0; k < rot.length; k++) {
      const p = rot[k];
      const q = rot[(k + 1) % rot.length];
      if ((p[1] <= y && q[1] > y) || (q[1] <= y && p[1] > y)) {
        xs.push(p[0] + ((y - p[1]) / (q[1] - p[1])) * (q[0] - p[0]));
      }
    }
    xs.sort((m, n) => m - n);
    for (let k = 0; k + 1 < xs.length; k += 2) {
      if (skip && r() < skip) continue;
      const x1 = xs[k] + inset + r() * inset * 1.5;
      const x2 = xs[k + 1] - inset - r() * inset * 1.5;
      if (x2 - x1 < 3) continue;
      const tilt = (r() - 0.5) * 1.4;
      const back = (p) => [p[0] * c - p[1] * s, p[0] * s + p[1] * c];
      segs.push([back([x1, y - tilt]), back([x2, y + tilt])]);
    }
  }
  return segs;
}

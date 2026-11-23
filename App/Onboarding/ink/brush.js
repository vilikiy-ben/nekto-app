// Перо. Линия становится залитым контуром переменной толщины: перо садится на бумагу тонко,
// в середине штриха давит сильнее и уходит на хвост. Путь чуть уводит в сторону — рука не линейка.

import { resample, arcLengths } from './geom.js';
import { wobble, hash } from './rng.js';

/**
 * Контур штриха вдоль ломаной.
 * @param pts     точки центральной линии
 * @param w       толщина пера в середине штриха, px
 * @param seed    ключ дрожи; один и тот же seed — тот же штрих в каждом кадре
 * @param drift   на сколько px рука уводит линию (крупный изгиб)
 * @param taper   [начало, конец] — длина сужения в px; 0 — тупой конец
 * @param pressure насколько толщина «дышит» вдоль штриха, 0…1
 * @param warp    необязательное отображение точки [x, y] → [x', y']: штрих построен на плоскости предмета
 *                (дрожь, сужение, нажим — от её длины пути), а на экран ложится через `warp`. Толщина
 *                откладывается уже на экране, поэтому перспектива не делает линию тоньше.
 */
export function strokeOutline(pts, { w = 3, seed = 1, drift = 1.2, taper = [10, 16], pressure = 0.22, step = 1.6, warp = null } = {}) {
  const line = resample(pts, step);
  const s = arcLengths(line);
  const L = s[s.length - 1];
  if (L < 0.5) return null;

  const closed = pts.closed && L > 20;
  const [tIn, tOut] = closed ? [Math.min(taper[0], 8), Math.min(taper[1], 10)] : taper;
  const left = [];
  const right = [];
  const n = line.length;

  for (let k = 0; k < n; k++) {
    const p = line[k];
    const a = line[Math.max(0, k - 1)];
    const b = line[Math.min(n - 1, k + 1)];
    let tx = b[0] - a[0];
    let ty = b[1] - a[1];
    const tl = Math.hypot(tx, ty) || 1;
    tx /= tl;
    ty /= tl;
    let nx = -ty;
    let ny = tx;

    const u = s[k];
    // Увод руки: шум от длины пути, затухает к концам, чтобы штрихи сходились там, где их соединили.
    const ends = Math.min(1, u / 14, (L - u) / 14);
    // Длинная линия уходит дальше: рука держит направление хуже на 300 px, чем на 30.
    const reach = Math.min(2.6, 0.55 + L / 160);
    const off = (wobble(u / 70, seed) * reach + wobble(u / 9 + 41, seed ^ 0x77) * 0.18) * drift * (0.35 + 0.65 * ends);
    let cx = p[0] + nx * off;
    let cy = p[1] + ny * off;
    if (warp) {
      // Центр штриха — через отображение, нормаль — по отображённым соседям.
      [cx, cy] = warp([cx, cy]);
      const A = warp(a);
      const B = warp(b);
      const wl = Math.hypot(B[0] - A[0], B[1] - A[1]) || 1;
      nx = -(B[1] - A[1]) / wl;
      ny = (B[0] - A[0]) / wl;
    }

    const head = tIn > 0 ? Math.min(1, u / tIn) : 1;
    const tail = tOut > 0 ? Math.min(1, (L - u) / tOut) : 1;
    const ease = (x) => Math.sin((x * Math.PI) / 2);
    const taperK = 0.28 + 0.72 * Math.min(ease(head), ease(tail));
    const press = 1 + pressure * wobble(u / 38 + 3.7, seed ^ 0xa5a5);
    const half = (w / 2) * taperK * press;

    left.push([cx + nx * half, cy + ny * half]);
    right.push([cx - nx * half, cy - ny * half]);
  }

  // Круглые концы: перо круглое, срез штриха не должен быть прямым.
  const capPts = (center, dirFrom, r, from) => {
    const out = [];
    for (let k = 1; k < 6; k++) {
      // Обход по часовой: от левого края через кончик к правому, наружу от штриха.
      const a = from - (k / 6) * Math.PI;
      out.push([center[0] + Math.cos(a) * r, center[1] + Math.sin(a) * r]);
    }
    return out;
  };
  const endCap = (i, j) => {
    const c = [(left[i][0] + right[i][0]) / 2, (left[i][1] + right[i][1]) / 2];
    const r = Math.hypot(left[i][0] - right[i][0], left[i][1] - right[i][1]) / 2;
    const a = Math.atan2(left[i][1] - c[1], left[i][0] - c[0]);
    return capPts(c, j, r, a);
  };

  const outline = [
    ...left,
    ...endCap(n - 1).map((p) => p),
    ...right.reverse(),
  ];
  // Капля на старте: начало штриха — с другой стороны.
  const startC = [(outline[outline.length - 1][0] + outline[0][0]) / 2, (outline[outline.length - 1][1] + outline[0][1]) / 2];
  const r0 = Math.hypot(outline[0][0] - outline[outline.length - 1][0], outline[0][1] - outline[outline.length - 1][1]) / 2;
  const a0 = Math.atan2(outline[outline.length - 1][1] - startC[1], outline[outline.length - 1][0] - startC[0]);
  outline.push(...capPts(startC, 0, r0, a0));
  outline.closed = true;
  return outline;
}

/**
 * Машинная линия постоянной толщины по замкнутому контуру (гильош): без дрожи, без сужений и без концов.
 * Возвращает [внешнее кольцо, внутреннее в обратном обходе] — залитое вместе, это полоса с отверстием.
 * У штриха пером на замкнутом контуре есть начало (круглые концы внахлёст); у вращающегося кольца оно
 * ездило бы по кругу и на шве цикла прыгало бы назад. У полосы начала нет.
 */
export function ringOutline(pts, w) {
  const n = pts.length;
  const outer = [];
  const inner = [];
  for (let k = 0; k < n; k++) {
    const a = pts[(k - 1 + n) % n];
    const b = pts[(k + 1) % n];
    const l = Math.hypot(b[0] - a[0], b[1] - a[1]) || 1;
    const nx = -(b[1] - a[1]) / l;
    const ny = (b[0] - a[0]) / l;
    const p = pts[k];
    outer.push([p[0] + nx * w / 2, p[1] + ny * w / 2]);
    inner.push([p[0] - nx * w / 2, p[1] - ny * w / 2]);
  }
  outer.closed = true;
  inner.reverse();
  inner.closed = true;
  return [outer, inner];
}

/** Заливка «от руки»: края чуть плывут, как у пятна туши, а не у векторной фигуры. */
export function jitterPoly(pts, { seed = 1, amount = 0.9, step = 2 } = {}) {
  const ring = resample([...pts, pts[0]], step);
  ring.pop();
  const s = arcLengths(ring);
  const n = ring.length;
  const out = ring.map((p, k) => {
    const a = ring[(k - 1 + n) % n];
    const b = ring[(k + 1) % n];
    let nx = -(b[1] - a[1]);
    let ny = b[0] - a[0];
    const l = Math.hypot(nx, ny) || 1;
    nx /= l;
    ny /= l;
    const off = wobble(s[k] / 30, seed) * amount;
    return [p[0] + nx * off, p[1] + ny * off];
  });
  out.closed = true;
  return out;
}

/** Прореживание Рамера — Дугласа — Пекера: убирает точки, которые отходят от прямой меньше `eps`. */
export function simplify(pts, eps = 0.18) {
  if (pts.length < 4) return pts;
  // Кольцо (первая точка = последней): режем по самой дальней точке, иначе опорный отрезок вырождается.
  const first = pts[0];
  const last = pts[pts.length - 1];
  if (Math.hypot(first[0] - last[0], first[1] - last[1]) < 1e-6) {
    let far = 1;
    let best = -1;
    pts.forEach((p, k) => {
      const d = Math.hypot(p[0] - first[0], p[1] - first[1]);
      if (d > best) { best = d; far = k; }
    });
    const a = simplify(pts.slice(0, far + 1), eps);
    const b = simplify(pts.slice(far), eps);
    const out = [...a, ...b.slice(1, -1)];
    out.closed = true;
    return out;
  }
  const keep = new Uint8Array(pts.length);
  keep[0] = keep[pts.length - 1] = 1;
  const stack = [[0, pts.length - 1]];
  while (stack.length) {
    const [a, b] = stack.pop();
    const [ax, ay] = pts[a];
    const [bx, by] = pts[b];
    const dx = bx - ax;
    const dy = by - ay;
    const len = Math.hypot(dx, dy) || 1;
    let worst = 0;
    let at = -1;
    for (let k = a + 1; k < b; k++) {
      const d = Math.abs(dy * pts[k][0] - dx * pts[k][1] + bx * ay - by * ax) / len;
      if (d > worst) { worst = d; at = k; }
    }
    if (worst > eps && at > 0) {
      keep[at] = 1;
      stack.push([a, at], [at, b]);
    }
  }
  const out = pts.filter((_, k) => keep[k]);
  out.closed = pts.closed;
  return out;
}

/**
 * Замкнутый многоугольник → путь SVG. Точки идут через 1,6 px, поэтому ломаная после прореживания
 * выглядит гладкой, а углы листов и плашек остаются углами.
 */
export function polyToPath(raw, decimals = 1) {
  const pts = simplify(raw);
  if (pts.length < 3) return '';
  const f = (v) => +v.toFixed(decimals);
  let d = `M${f(pts[0][0])} ${f(pts[0][1])}`;
  for (let k = 1; k < pts.length; k++) d += `L${f(pts[k][0])} ${f(pts[k][1])}`;
  return d + 'Z';
}

export { hash };

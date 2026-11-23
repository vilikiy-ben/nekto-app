// Геометрия: разбор SVG-пути в ломаные, окружности «от руки», трансформации.
// Сцены описывают рисунок обычными командами пути (M, C, Q, L…), а перо превращает их в штрихи.

const TAU = Math.PI * 2;

/** Разбирает строку пути SVG в подпути — массивы точек [x, y]. Дуги (A) не поддерживаются: для них есть `ellipse`. */
export function pathToPolylines(d, step = 1.5) {
  const tokens = d.match(/[MmLlHhVvCcSsQqTtZz]|-?(?:\d*\.\d+|\d+)(?:e[-+]?\d+)?/g) ?? [];
  const out = [];
  let i = 0;
  let cmd = '';
  let cur = [0, 0];
  let start = [0, 0];
  let lastCtrl = null;
  let poly = null;
  const num = () => parseFloat(tokens[i++]);
  const isCmd = (t) => /^[A-Za-z]$/.test(t);
  const push = (p) => poly.push(p);

  while (i < tokens.length) {
    if (isCmd(tokens[i])) cmd = tokens[i++];
    const rel = cmd === cmd.toLowerCase();
    const C = cmd.toUpperCase();
    const ox = rel ? cur[0] : 0;
    const oy = rel ? cur[1] : 0;
    switch (C) {
      case 'M': {
        cur = [num() + ox, num() + oy];
        start = cur;
        poly = [cur];
        out.push(poly);
        cmd = rel ? 'l' : 'L';
        lastCtrl = null;
        break;
      }
      case 'L': cur = [num() + ox, num() + oy]; push(cur); lastCtrl = null; break;
      case 'H': cur = [num() + ox, cur[1]]; push(cur); lastCtrl = null; break;
      case 'V': cur = [cur[0], num() + oy]; push(cur); lastCtrl = null; break;
      case 'C': case 'S': {
        let c1;
        if (C === 'C') c1 = [num() + ox, num() + oy];
        else c1 = lastCtrl ? [2 * cur[0] - lastCtrl[0], 2 * cur[1] - lastCtrl[1]] : cur;
        const c2 = [num() + ox, num() + oy];
        const p = [num() + ox, num() + oy];
        sampleCubic(cur, c1, c2, p, step).forEach(push);
        lastCtrl = c2;
        cur = p;
        break;
      }
      case 'Q': case 'T': {
        let c;
        if (C === 'Q') c = [num() + ox, num() + oy];
        else c = lastCtrl ? [2 * cur[0] - lastCtrl[0], 2 * cur[1] - lastCtrl[1]] : cur;
        const p = [num() + ox, num() + oy];
        const c1 = [cur[0] + (2 / 3) * (c[0] - cur[0]), cur[1] + (2 / 3) * (c[1] - cur[1])];
        const c2 = [p[0] + (2 / 3) * (c[0] - p[0]), p[1] + (2 / 3) * (c[1] - p[1])];
        sampleCubic(cur, c1, c2, p, step).forEach(push);
        lastCtrl = c;
        cur = p;
        break;
      }
      case 'Z': {
        push(start);
        poly.closed = true;
        cur = start;
        lastCtrl = null;
        break;
      }
      default:
        throw new Error(`Неизвестная команда пути: ${cmd}`);
    }
  }
  return out.filter((p) => p.length > 1);
}

function sampleCubic(p0, p1, p2, p3, step) {
  const approx = dist(p0, p1) + dist(p1, p2) + dist(p2, p3);
  const n = Math.max(2, Math.ceil(approx / step));
  const pts = [];
  for (let k = 1; k <= n; k++) {
    const t = k / n;
    const u = 1 - t;
    pts.push([
      u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0],
      u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1],
    ]);
  }
  return pts;
}

export function dist(a, b) {
  return Math.hypot(b[0] - a[0], b[1] - a[1]);
}

/** Длины от начала до каждой точки ломаной. */
export function arcLengths(pts) {
  const s = [0];
  for (let k = 1; k < pts.length; k++) s.push(s[k - 1] + dist(pts[k - 1], pts[k]));
  return s;
}

/** Ровный шаг вдоль ломаной: перо получает точки через одинаковые промежутки. */
export function resample(pts, step) {
  const s = arcLengths(pts);
  const L = s[s.length - 1];
  if (L === 0) return [pts[0], pts[0]];
  const n = Math.max(2, Math.round(L / step));
  const out = [];
  let j = 0;
  for (let k = 0; k <= n; k++) {
    const target = (k / n) * L;
    while (j < s.length - 2 && s[j + 1] < target) j++;
    const seg = s[j + 1] - s[j] || 1;
    const f = (target - s[j]) / seg;
    out.push([pts[j][0] + (pts[j + 1][0] - pts[j][0]) * f, pts[j][1] + (pts[j + 1][1] - pts[j][1]) * f]);
  }
  return out;
}

/**
 * Овал, как его обводит рука: начинается в `start`, проходит `sweep` и заходит на себя на `overshoot`,
 * так что начало и конец не сходятся в точку.
 */
export function ellipse(cx, cy, rx, ry, { start = -2.2, sweep = TAU, overshoot = 0.18, rot = 0, step = 1.5 } = {}) {
  const total = sweep + overshoot;
  const n = Math.max(12, Math.ceil((total * Math.max(rx, ry)) / step));
  const cr = Math.cos(rot);
  const sr = Math.sin(rot);
  const pts = [];
  for (let k = 0; k <= n; k++) {
    const a = start + (k / n) * total;
    // Радиус чуть «дышит» к концу обхода: рука редко возвращается в ту же точку.
    const drift = 1 + 0.035 * (k / n);
    const x = Math.cos(a) * rx * drift;
    const y = Math.sin(a) * ry * drift;
    pts.push([cx + x * cr - y * sr, cy + x * sr + y * cr]);
  }
  return pts;
}

/** Замкнутый многоугольник овала для заливок (без захода на себя). */
export function ellipsePoly(cx, cy, rx, ry, { rot = 0, n = 64 } = {}) {
  const cr = Math.cos(rot);
  const sr = Math.sin(rot);
  const pts = [];
  for (let k = 0; k < n; k++) {
    const a = (k / n) * TAU;
    const x = Math.cos(a) * rx;
    const y = Math.sin(a) * ry;
    pts.push([cx + x * cr - y * sr, cy + x * sr + y * cr]);
  }
  pts.closed = true;
  return pts;
}

/** Матрица 2×3 [a, b, c, d, e, f]: x' = a·x + c·y + e, y' = b·x + d·y + f. */
export const IDENTITY = [1, 0, 0, 1, 0, 0];

export function multiply(m, n) {
  return [
    m[0] * n[0] + m[2] * n[1],
    m[1] * n[0] + m[3] * n[1],
    m[0] * n[2] + m[2] * n[3],
    m[1] * n[2] + m[3] * n[3],
    m[0] * n[4] + m[2] * n[5] + m[4],
    m[1] * n[4] + m[3] * n[5] + m[5],
  ];
}

/** Перенос, поворот (в градусах) вокруг точки `origin` и масштаб. */
export function makeTransform({ x = 0, y = 0, rotate = 0, scale = 1, origin = [0, 0] } = {}) {
  const a = (rotate * Math.PI) / 180;
  const sx = Array.isArray(scale) ? scale[0] : scale;
  const sy = Array.isArray(scale) ? scale[1] : scale;
  const c = Math.cos(a);
  const s = Math.sin(a);
  // T(x,y) · T(origin) · R · S · T(-origin)
  let m = [1, 0, 0, 1, x + origin[0], y + origin[1]];
  m = multiply(m, [c * sx, s * sx, -s * sy, c * sy, 0, 0]);
  m = multiply(m, [1, 0, 0, 1, -origin[0], -origin[1]]);
  return m;
}

/** Тождественная ли матрица: тогда точки не трогаем вовсе, и неподвижный кадр SVG совпадает до бита. */
export function isIdentity(m) {
  return m[0] === 1 && m[1] === 0 && m[2] === 0 && m[3] === 1 && m[4] === 0 && m[5] === 0;
}

export function apply(m, p) {
  return [m[0] * p[0] + m[2] * p[1] + m[4], m[1] * p[0] + m[3] * p[1] + m[5]];
}

export function mapPoints(m, pts) {
  const out = pts.map((p) => apply(m, p));
  out.closed = pts.closed;
  return out;
}

/** Средний масштаб матрицы: чтобы толщина пера росла вместе с предметом. */
export function scaleOf(m) {
  return Math.sqrt(Math.abs(m[0] * m[3] - m[1] * m[2]));
}

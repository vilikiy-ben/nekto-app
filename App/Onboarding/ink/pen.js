// Перо сцены: собирает штрихи, заливки и штриховку в список, который потом
// уходит в SVG (неподвижный кадр) или на canvas (анимация, `preview/`). Текста в сценах нет: ни подписей, ни надписей
// на предметах — сцена понятна без слов и не зависит от языка. Сцена про цвета не знает — только роли:
// ink, tint, mark, paper, glint. Цвет подставляет тема при выводе.
//
// Что держит анимацию ровной:
// - Дрожь штриха зависит только от seed сцены и id штриха, не от `t` и не от порядка рисования. У всего, что
//   движется, id явный; автоматический (`#n`) помечается `auto`.
// - Сдвиг и поворот не меняют форму штриха: контур строится от длины пути и нормалей, а они от них не зависят.
//   Масштаб меняет: дрожь считается в пикселях. Поэтому у `with` есть `local: true` — контур строится
//   в собственных координатах предмета, а трансформация прикладывается к готовому контуру. Так предмет можно
//   уменьшать, растягивать плашку слева направо и не видеть, как «кипит» линия.
// - Прозрачность группы (`with({ opacity })`): предмет из нескольких слоёв гаснет целиком, а не каждый слой
//   по отдельности (иначе тень просвечивает сквозь бумагу листа).
// - Слои (`layer`): неподвижные части сцены плеер рисует один раз и кеширует, вращающиеся — поворачивает
//   готовыми. В SVG и в проверке слой — обычный `with` (с масштабом — `with({ local: true })`).
// - Перспектива (`with({ warp })`): предмет рисуется на своей плоскости, а на экран ложится через отображение
//   точки. Так створка двери поворачивается, а линии на ней не «ползут»: их дрожь посчитана один раз на плоскости.

import { pathToPolylines, ellipse, ellipsePoly, makeTransform, multiply, mapPoints, scaleOf, isIdentity, IDENTITY } from './geom.js';
import { strokeOutline, jitterPoly, ringOutline, polyToPath } from './brush.js';
import { hatchLines } from './hatch.js';
import { hash } from './rng.js';

/**
 * Залитый контур. `poly` — точки в координатах кадра (или слоя), `holes` — отверстия (у полосы гильоша),
 * `d` — путь SVG, считается по требованию.
 */
export class Shape {
  constructor(role, poly, { opacity = 1, id, auto = false, group = null, holes = null } = {}) {
    this.kind = 'path';
    this.role = role;
    this.poly = poly;
    this.holes = holes;
    this.opacity = opacity;
    this.id = id;
    this.auto = auto;
    this.group = group;
  }

  /** Путь SVG с прореживанием и округлением до 0,1 px — для неподвижных кадров. Плеер берёт `poly` как есть. */
  get d() {
    if (this._d === undefined) this._d = polyToPath(this.poly) + (this.holes ?? []).map((h) => polyToPath(h)).join('');
    return this._d;
  }
}

const ROOT = Object.freeze({ m: IDENTITY, base: IDENTITY, lm: IDENTITY, group: null, warp: null });

export class Pen {
  /**
   * @param seed   ключ сцены: от него и id штриха зависит дрожь
   * @param cache  Map для слоёв (`layer`). Без него слои рисуются как обычные штрихи — так делает SVG и проверка.
   */
  constructor(seed = 'nekto', { cache = null } = {}) {
    this.seed = seed;
    this.items = [];
    this.cache = cache;
    this.stack = [ROOT];
    this.counter = 0;
    this.groups = 0;
  }

  get top() {
    return this.stack[this.stack.length - 1];
  }

  /** Полная матрица текущего кадра. */
  get m() {
    return this.top.m;
  }

  /**
   * Рисует `fn` со сдвигом, поворотом или масштабом. Толщина пера масштабируется вместе с предметом.
   * `local: true` — контур строится в координатах этого кадра, трансформация прикладывается к готовому контуру.
   * `opacity` — прозрачность группы: всё внутри гаснет как одно целое.
   * `warp` — функция [x, y] → [x', y']: всё внутри строится на плоскости предмета, а на экран ложится через неё
   *          (вложенные `with` внутри работают на этой плоскости).
   */
  with(t, fn) {
    const top = this.top;
    const T = makeTransform(t);
    let frame;
    if (t.warp) frame = { m: T, base: IDENTITY, lm: T, warp: t.warp };
    else if (top.warp) frame = { m: multiply(top.m, T), base: IDENTITY, lm: multiply(top.lm, T), warp: top.warp };
    else {
      const m = multiply(top.m, T);
      frame = t.local ? { m, base: m, lm: IDENTITY, warp: null } : { m, base: top.base, lm: multiply(top.lm, T), warp: null };
    }
    frame.group = top.group;
    if (t.opacity != null) {
      const opacity = (top.group?.opacity ?? 1) * t.opacity;
      // Невидимую группу не рисуем вовсе: в ней все id явные, пропуск ничего не сдвигает.
      if (opacity <= 0) return this;
      frame.group = { id: ++this.groups, opacity };
    }
    this.stack.push(frame);
    try {
      fn();
    } finally {
      this.stack.pop();
    }
    return this;
  }

  /**
   * Слой для кеша плеера. Неподвижная часть сцены (`transform` нет) растрируется один раз; слой с `transform`
   * (например, поворот гильоша) строится один раз и поворачивается готовым. `key` — то, от чего зависит
   * содержимое слоя (состояние сцены); от `t` содержимое зависеть не должно.
   */
  layer(name, { key = '', transform } = {}, fn) {
    if (!this.cache) {
      // Без кеша (SVG, проверка) жёсткий слой рисуется как обычный `with`: при сдвиге и повороте контур тот же,
      // а неподвижный кадр SVG остаётся прежним до бита. С масштабом — `local`, как в плеере.
      const sc = transform?.scale;
      const scaled = sc != null && (Array.isArray(sc) ? sc[0] !== 1 || sc[1] !== 1 : sc !== 1);
      return this.with({ ...(transform ?? {}), local: scaled }, fn);
    }
    // Неподвижный слой захватывается в координатах кадра — ровно как ляжет в SVG — и растрируется плеером.
    // Подвижный — в своих координатах и каждый кадр заливается под новой матрицей.
    const matrix = transform ? multiply(this.m, makeTransform(transform)) : IDENTITY;
    const ck = `${name}|${key}`;
    let items = this.cache.get(ck);
    if (!items) {
      const saved = [this.items, this.stack];
      this.items = [];
      this.stack = [transform ? ROOT : { ...this.top, group: null }];
      try {
        fn();
        items = this.items;
      } finally {
        [this.items, this.stack] = saved;
      }
      this.cache.set(ck, items);
    }
    this.items.push({ kind: 'layer', name, key: ck, items, matrix, group: this.top.group });
    return this;
  }

  /** Ключ штриха. Явный `id` держит дрожь линии на месте, даже если порядок штрихов в кадре поменялся. */
  key(id) {
    return hash(this.seed, id ?? `#${this.counter++}`);
  }

  /** Фигура в координатах, где строится контур: строка пути, ломаная или массив ломаных. */
  polys(shape) {
    let list;
    if (typeof shape === 'string') list = pathToPolylines(shape);
    else if (Array.isArray(shape[0]?.[0])) list = shape;
    else list = [shape];
    const { lm } = this.top;
    return list.map((p) => mapPoints(lm, p));
  }

  /** Готовый контур — в координаты кадра. `warped` — контур уже на экране (штрих перо строит через `warp` само). */
  emit(role, ring, opts, warped = false) {
    const { base, group, warp } = this.top;
    const place = (r) => {
      if (warp && !warped) {
        const out = r.map(warp);
        out.closed = r.closed;
        return out;
      }
      return isIdentity(base) ? r : mapPoints(base, r);
    };
    const holes = opts.holes ? opts.holes.map(place) : null;
    this.items.push(new Shape(role, place(ring), { ...opts, holes, group }));
  }

  /** Имя штриха для проверки: явное или порядковое (тогда `auto`). */
  name(id, ...parts) {
    return id != null ? { id: [id, ...parts].join('/'), auto: false } : { id: `#${this.counter}`, auto: true };
  }

  /** Линия пером. */
  line(shape, { w = 2.6, color = 'ink', id, drift = 1.1, taper = [8, 14], pressure = 0.25, opacity = 1 } = {}) {
    const k = scaleOf(this.top.lm);
    this.polys(shape).forEach((p, i) => {
      const nm = this.name(id, i);
      const seed = this.key(id ? `${id}/${i}` : undefined);
      const o = strokeOutline(p, { w: w * k, seed, drift: drift * Math.sqrt(k), taper: taper.map((v) => v * k), pressure, warp: this.top.warp });
      if (o) this.emit(color, o, { opacity, ...nm }, true);
    });
    return this;
  }

  /** Пятно заливки. `jitter: 0` — ровный край (нужен для «бумаги», которая закрывает задний план). */
  fill(shape, { color = 'ink', id, jitter = 0.8, opacity = 1 } = {}) {
    const k = scaleOf(this.top.lm);
    this.polys(shape).forEach((p, i) => {
      const nm = this.name(id, i);
      const seed = this.key(id ? `${id}/${i}` : undefined);
      const ring = jitter > 0 ? jitterPoly(p, { seed, amount: jitter * k }) : p;
      this.emit(color, ring, { opacity, ...nm });
    });
    return this;
  }

  /** Штриховка внутри фигуры. */
  hatch(shape, { angle = -35, gap = 6, w = 1.4, color = 'ink', id, inset = 2, skip = 0 } = {}) {
    const k = scaleOf(this.top.lm);
    const auto = id == null;
    this.polys(shape).forEach((p, i) => {
      const base = id ?? `hatch${this.counter++}`;
      hatchLines(p, { angle, gap: gap * k, inset: inset * k, seed: this.key(`${base}/${i}`), skip }).forEach((seg, j) => {
        const o = strokeOutline(seg, { w: w * k, seed: this.key(`${base}/${i}/${j}`), drift: 0.4, taper: [3 * k, 4 * k], pressure: 0.3, warp: this.top.warp });
        if (o) this.emit(color, o, { id: `${base}/${i}/${j}`, auto }, true);
      });
    });
    return this;
  }

  /**
   * Машинная линия по замкнутому контуру: постоянная толщина, ни дрожи, ни концов (гильош). Точки — без
   * повтора первой в конце. Вращать такое кольцо можно на любой угол: у него нет места, где штрих начинается.
   */
  ring(pts, { w = 0.75, color = 'ink', id, opacity = 1 } = {}) {
    const k = scaleOf(this.top.lm);
    const nm = this.name(id, 0);
    this.key(id ? `${id}/0` : undefined);
    const [outer, inner] = ringOutline(this.polys(pts)[0], w * k);
    this.emit(color, outer, { opacity, ...nm, holes: [inner] });
    return this;
  }

  /** Обвод овала «от руки» — с заходом на себя. */
  oval(cx, cy, rx, ry, opts = {}) {
    const { start, overshoot, rot, ...rest } = opts;
    return this.line(ellipse(cx, cy, rx, ry, { start, overshoot, rot }), rest);
  }

  /** Залитый овал. */
  blob(cx, cy, rx, ry, opts = {}) {
    const { rot, ...rest } = opts;
    return this.fill(ellipsePoly(cx, cy, rx, ry, { rot }), rest);
  }

  /** Стрелка от руки: линия и две короткие засечки на конце, под углом к последнему отрезку. */
  arrow(shape, { w = 2.2, head = 11, spread = 28, id = 'arrow', ...rest } = {}) {
    this.line(shape, { w, id, taper: [4, 3], ...rest });
    const poly = this.polys(shape).at(-1);
    const end = poly.at(-1);
    let k = poly.length - 2;
    while (k > 0 && Math.hypot(end[0] - poly[k][0], end[1] - poly[k][1]) < head * 0.8) k--;
    const a = Math.atan2(end[1] - poly[k][1], end[0] - poly[k][0]);
    const s = (spread * Math.PI) / 180;
    // Засечки строятся там же, где линия (точки `poly` уже в этих координатах), без повторного масштаба.
    const top = this.top;
    this.stack.push({ m: top.base, base: top.base, lm: IDENTITY, group: top.group, warp: top.warp });
    try {
      for (const [side, sign] of [['l', 1], ['r', -1]]) {
        const b = a + Math.PI + sign * s;
        const tip = [end[0] + Math.cos(b) * head, end[1] + Math.sin(b) * head];
        this.line([tip, end], { w, id: `${id}/${side}`, taper: [5, 2], drift: 0.3 });
      }
    } finally {
      this.stack.pop();
    }
    return this;
  }
}

/**
 * Плоский список контуров кадра: слои раскрыты (точки переведены матрицей слоя), прозрачность группы
 * умножена на прозрачность контура. Для SVG и для проверки циклов.
 */
export function flatten(items) {
  const out = [];
  const walk = (list, matrix, outer) => {
    for (const it of list) {
      if (it.kind === 'layer') {
        walk(it.items, matrix ? multiply(matrix, it.matrix) : it.matrix, (it.group?.opacity ?? 1) * (outer ?? 1));
        continue;
      }
      const g = (it.group?.opacity ?? 1) * (outer ?? 1);
      const move = matrix && !isIdentity(matrix);
      if (!move && g === 1) {
        out.push(it);
        continue;
      }
      const poly = move ? mapPoints(matrix, it.poly) : it.poly;
      const holes = it.holes && move ? it.holes.map((h) => mapPoints(matrix, h)) : it.holes;
      out.push(new Shape(it.role, poly, { opacity: it.opacity * g, id: it.id, auto: it.auto, holes }));
    }
  };
  walk(items, null, null);
  return out;
}

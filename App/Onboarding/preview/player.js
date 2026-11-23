// Плеер одной сцены на <canvas>. Сцена рисуется тем же пером, что и неподвижные кадры SVG, но контуры идут
// на холст как есть: без прореживания и без округления до 0,1 px. Прореживание выбирает вершины заново
// в каждом кадре, а округление привязывает их к сетке — у движущегося предмета от этого дрожали бы края.
//
// Кеш:
// - слой без трансформации (`pen.layer(name, {}, fn)`) растрируется один раз под текущий масштаб и тему
//   и копируется на холст пиксель в пиксель;
// - слой с трансформацией (гильош) строится один раз как набор Path2D и каждый кадр заливается под новой
//   матрицей — поворот векторный, без пересэмплирования растра, поэтому кольца не мерцают муаром;
// - группа с прозрачностью меньше 1 рисуется на отдельный холст и накладывается целиком.

import { Pen } from '../ink/pen.js';
import { isIdentity } from '../ink/geom.js';

/** Путь холста из точек контура (и отверстий). */
function toPath2D(shape) {
  const p = new Path2D();
  for (const ring of [shape.poly, ...(shape.holes ?? [])]) {
    if (ring.length < 3) continue;
    p.moveTo(ring[0][0], ring[0][1]);
    for (let k = 1; k < ring.length; k++) p.lineTo(ring[k][0], ring[k][1]);
    p.closePath();
  }
  return p;
}

export class ScenePlayer {
  constructor(canvas, scene) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
    this.scene = scene;
    this.layers = new Map();   // ключ слоя → контуры (координаты слоя); от темы и масштаба не зависят
    this.paths = new WeakMap(); // контур слоя → Path2D
    this.rasters = new Map();  // ключ слоя → { canvas, x, y } под текущие тему и масштаб
    this.rasterKey = '';
    this.off = null;           // холст для групп с прозрачностью
    this.scale = 1;
  }

  /** Размер холста под ширину в CSS-пикселях и плотность экрана. */
  resize(cssWidth, dpr = window.devicePixelRatio || 1) {
    const [w, h] = this.scene.size;
    const pw = Math.max(1, Math.round(cssWidth * dpr));
    const ph = Math.max(1, Math.round((cssWidth * h / w) * dpr));
    if (pw === this.canvas.width && ph === this.canvas.height) return;
    this.canvas.width = pw;
    this.canvas.height = ph;
    this.scale = pw / w;
    this.rasters.clear();
    this.off = null;
  }

  /**
   * Кадр сцены в момент `t` (доля цикла). `colors` — роли палитры темы. Возвращает время отрисовки в мс.
   */
  draw(t, state, colors, themeName) {
    const t0 = performance.now();
    const key = `${themeName}|${this.scale}`;
    if (key !== this.rasterKey) {
      this.rasters.clear();
      this.rasterKey = key;
    }
    const pen = new Pen(this.scene.id, { cache: this.layers });
    this.scene.draw(pen, t, state);

    const ctx = this.ctx;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.globalAlpha = 1;
    ctx.fillStyle = colors.paper;
    ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);

    // Подряд идущие контуры одной полупрозрачной группы собираются на отдельном холсте.
    let group = null;
    let target = ctx;
    const flush = () => {
      if (!group) return;
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.globalAlpha = group.opacity;
      ctx.drawImage(this.off.canvas, 0, 0);
      ctx.globalAlpha = 1;
      group = null;
      target = ctx;
    };
    for (const it of pen.items) {
      const g = it.group && it.group.opacity < 1 ? it.group : null;
      if (g !== group) {
        flush();
        if (g) {
          target = this.offscreen();
          target.setTransform(1, 0, 0, 1, 0, 0);
          target.clearRect(0, 0, this.canvas.width, this.canvas.height);
          group = g;
        }
      }
      if (it.kind === 'layer') this.drawLayer(target, it, colors);
      else this.fillShape(target, it, colors, null);
    }
    flush();
    return performance.now() - t0;
  }

  offscreen() {
    if (!this.off) {
      const c = document.createElement('canvas');
      c.width = this.canvas.width;
      c.height = this.canvas.height;
      this.off = c.getContext('2d');
    }
    return this.off;
  }

  /** Один контур: матрица холста — масштаб панели, умноженный на `matrix` (если есть). */
  fillShape(ctx, shape, colors, matrix, cached = false) {
    const s = this.scale;
    if (matrix) ctx.setTransform(s * matrix[0], s * matrix[1], s * matrix[2], s * matrix[3], s * matrix[4], s * matrix[5]);
    else ctx.setTransform(s, 0, 0, s, 0, 0);
    let path = cached ? this.paths.get(shape) : null;
    if (!path) {
      path = toPath2D(shape);
      if (cached) this.paths.set(shape, path);
    }
    ctx.globalAlpha = shape.opacity;
    ctx.fillStyle = colors[shape.role];
    ctx.fill(path, shape.holes?.length ? 'evenodd' : 'nonzero');
    ctx.globalAlpha = 1;
  }

  drawLayer(ctx, layer, colors) {
    // Слой с трансформацией — векторно под матрицей; неподвижный — готовым растром.
    if (!isIdentity(layer.matrix)) {
      this.drawItems(ctx, layer.items, colors, layer.matrix);
      return;
    }
    let r = this.rasters.get(layer.key);
    if (!r) {
      r = this.rasterize(layer.items, colors);
      this.rasters.set(layer.key, r);
    }
    if (!r) return;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.drawImage(r.canvas, r.x, r.y);
  }

  drawItems(ctx, items, colors, matrix) {
    for (const it of items) {
      if (it.kind === 'layer') continue; // вложенных слоёв сцены не делают
      // Группы внутри слоя (редкость) — прозрачность прямо на контуре.
      if (it.group && it.group.opacity < 1) {
        const o = it.opacity;
        it.opacity = o * it.group.opacity;
        this.fillShape(ctx, it, colors, matrix, true);
        it.opacity = o;
      } else this.fillShape(ctx, it, colors, matrix, true);
    }
  }

  /** Растр слоя: только его рамка, начало — на целом пикселе, чтобы копия легла пиксель в пиксель. */
  rasterize(items, colors) {
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (const it of items) {
      if (it.kind === 'layer') continue;
      for (const [x, y] of it.poly) {
        if (x < x0) x0 = x;
        if (y < y0) y0 = y;
        if (x > x1) x1 = x;
        if (y > y1) y1 = y;
      }
    }
    if (!(x1 > x0)) return null;
    const s = this.scale;
    const px = Math.max(0, Math.floor(x0 * s) - 2);
    const py = Math.max(0, Math.floor(y0 * s) - 2);
    const pw = Math.min(this.canvas.width, Math.ceil(x1 * s) + 2) - px;
    const ph = Math.min(this.canvas.height, Math.ceil(y1 * s) + 2) - py;
    if (pw <= 0 || ph <= 0) return null;
    const c = document.createElement('canvas');
    c.width = pw;
    c.height = ph;
    const ctx = c.getContext('2d');
    // Сдвиг на целое число пикселей: x' = s·x − px.
    this.drawItems(ctx, items, colors, [1, 0, 0, 1, -px / s, -py / s]);
    return { canvas: c, x: px, y: py };
  }
}

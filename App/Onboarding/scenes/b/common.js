// «Защищённая печать». Общие элементы сцен.
//
// Гильош, как на банкнотах и паспортах, гравюрная штриховка, метки обреза по углам, тяжёлые графитовые массы.

const TAU = Math.PI * 2;

/**
 * Гильош: много тонких концентрических колец с мелкой волной, у каждого следующего кольца волна
 * чуть сдвинута — из сдвигов складывается муар, как на банкнотах и в паспортах. Кольца без дрожи руки:
 * гильош машинный, и рядом с ним рисованные предметы выглядят рисованными.
 *
 * Кольцо — полоса постоянной толщины без начала и конца (`pen.ring`), точек на кольце кратно числу лепестков.
 * Поэтому поворот на 1/petals оборота переводит кольцо в себя точка в точку, и цикл замыкается без шва.
 * Поворачивать лучше слоем (`pen.layer(…, { transform: { rotate } })`): плеер строит кольца один раз.
 * `turn` — поворот в долях оборота, если рисовать без слоя.
 */
export function guilloche(pen, cx, cy, { r0 = 150, r1 = 250, rings = 30, petals = 16, amp = 9, shift = 0.19, turn = 0, color = 'ink', opacity = 0.3, w = 0.75, id = 'guilloche' } = {}) {
  const rot = turn * TAU;
  for (let i = 0; i < rings; i++) {
    const base = r0 + ((r1 - r0) * i) / Math.max(1, rings - 1);
    // К краям волна гаснет: розетка начинается и кончается ровной окружностью.
    const env = Math.sin((Math.PI * (i + 0.5)) / rings);
    const pts = [];
    const n = petals * Math.ceil((base * TAU) / 2.5 / petals);
    for (let k = 0; k < n; k++) {
      const a = (k / n) * TAU;
      const r = base + amp * env * Math.sin(petals * a + i * shift);
      pts.push([cx + Math.cos(a + rot) * r, cy + Math.sin(a + rot) * r]);
    }
    pen.ring(pts, { id: `${id}/${i}`, w, color, opacity });
  }
}

/** Метки обреза по углам прямоугольника — как на печатном листе перед резкой. */
export function cropMarks(pen, x0, y0, x1, y1, { len = 18, gap = 8, color = 'ink', id = 'crop' } = {}) {
  const corners = [
    [x0, y0, -1, -1],
    [x1, y0, 1, -1],
    [x0, y1, -1, 1],
    [x1, y1, 1, 1],
  ];
  corners.forEach(([x, y, sx, sy], k) => {
    pen.line([[x + sx * gap, y], [x + sx * (gap + len), y]], { id: `${id}${k}h`, w: 1.4, color, taper: [1, 1], drift: 0.2 });
    pen.line([[x, y + sy * gap], [x, y + sy * (gap + len)]], { id: `${id}${k}v`, w: 1.4, color, taper: [1, 1], drift: 0.2 });
  });
}

// ───────────── Изометрия: общий язык сцен Б (у каждой сцены своё движение) ─────────────

/** Сдвиг глубины, как у слоёв монолита. */
export const DEPTH = { dx: 44, dy: -26 };

/**
 * Изометрический блок: фасад `front` ('ink' | 'mass' | 'sheet'), грань справа в штриховку, верх бледный.
 * (x0, y) — левый верхний угол фасада, w × h — его размер, `depth` — доля глубины монолита.
 */
export function block(pen, x0, y, w, h, { front = 'ink', depth = 1, id = 'block', top = 'tint' } = {}) {
  const x1 = x0 + w;
  const dx = DEPTH.dx * depth;
  const dy = DEPTH.dy * depth;
  const faceTop = `M ${x0} ${y} L ${x0 + dx} ${y + dy} L ${x1 + dx} ${y + dy} L ${x1} ${y} Z`;
  const side = `M ${x1} ${y} L ${x1 + dx} ${y + dy} L ${x1 + dx} ${y + h + dy} L ${x1} ${y + h} Z`;
  const face = `M ${x0} ${y} L ${x1} ${y} L ${x1} ${y + h} L ${x0} ${y + h} Z`;
  pen.fill(faceTop, { color: top, id: `${id}-top`, jitter: 0.5 });
  pen.fill(side, { color: 'sheet', id: `${id}-side-paper`, jitter: 0 });
  pen.hatch(side, { angle: 60, gap: 5, w: 1.1, id: `${id}-side-hatch`, inset: 1 });
  pen.fill(face, { color: front, id: `${id}-front`, jitter: front === 'sheet' ? 0 : 0.5 });
  const edge = `M ${x0} ${y} L ${x0 + dx} ${y + dy} L ${x1 + dx} ${y + dy} L ${x1 + dx} ${y + h + dy} L ${x1} ${y + h}`;
  pen.line(edge, { id: `${id}-edge`, w: 1.8, taper: [2, 2] });
  if (front === 'sheet') pen.line(face, { id: `${id}-face-edge`, w: 2.2 });
  return { x0, x1, y, h, dx, dy };
}

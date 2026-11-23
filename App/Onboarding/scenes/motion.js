// Время в сценах. `t` — доля цикла от 0 до 1; кадр 0 — неподвижный кадр сцены.

/** Плавный вход и выход (smoothstep). */
export const ease = (x) => {
  const c = Math.min(1, Math.max(0, x));
  return c * c * (3 - 2 * c);
};

/** Доля пути внутри окна [from, to] цикла: 0 до окна, 1 после. */
export const loop = (t, from, to) => Math.min(1, Math.max(0, (t - from) / (to - from)));

/** Синус с целым числом периодов за цикл — замыкается без шва. */
export const wave = (t, periods = 1, phase = 0) => Math.sin((t * periods + phase) * Math.PI * 2);

/** Линейная смесь a → b. */
export const lerp = (a, b, k) => a + (b - a) * k;

/**
 * Гладкая положительная половина волны: как `max(0, s)`, но без излома в нуле — предмет трогается
 * и садится с нулевой скоростью. При s ≥ knee значение ровно s, поэтому кадр 0 не меняется.
 */
export const rise = (s, knee = 0.35) => (s <= 0 ? 0 : s * ease(s / knee));

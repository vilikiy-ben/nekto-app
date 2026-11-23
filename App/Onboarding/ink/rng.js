// Случайность, которая повторяется: один и тот же seed даёт ту же дрожь линии в каждом кадре.
// Без этого рисунок «кипел» бы при каждом перерисовывании, а в неподвижном кадре и в анимации линии бы не совпали.

/** Целое 32 бита из набора чисел и строк — ключ для штриха. */
export function hash(...parts) {
  let h = 2166136261 >>> 0;
  for (const part of parts) {
    const s = String(part);
    for (let i = 0; i < s.length; i++) {
      h ^= s.charCodeAt(i);
      h = Math.imul(h, 16777619) >>> 0;
    }
    h ^= 0x9e3779b9;
  }
  return h >>> 0;
}

/** Генератор mulberry32: равномерно в [0, 1). */
export function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function lattice(i, seed) {
  return (hash(seed, i) / 4294967295) * 2 - 1;
}

/** Плавный одномерный шум в [-1, 1]: значения в целых точках, между ними — косинусная сглаженная интерполяция. */
export function noise1(x, seed) {
  const i = Math.floor(x);
  const f = x - i;
  const u = f * f * (3 - 2 * f);
  return lattice(i, seed) * (1 - u) + lattice(i + 1, seed) * u;
}

/** Шум из двух октав: крупный изгиб руки и мелкий тремор пера. */
export function wobble(x, seed) {
  return noise1(x, seed) * 0.75 + noise1(x * 3.1 + 17, seed ^ 0x5bd1e995) * 0.25;
}

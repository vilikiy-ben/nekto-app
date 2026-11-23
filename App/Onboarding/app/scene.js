// Сцена онбординга внутри приложения: одна сцена на весь вид, в реальном времени.
//
// Рисует `ScenePlayer` (`preview/player.js`) сценами из `scenes/b/`. Приложение
// (`App/Sources/Onboarding/SceneView.swift`) управляет страницей одним вызовом:
//
//   nekto.set({ scene: 'b-monolith', state: { progress: 0.4 }, theme: 'dark', still: false, playing: true, fps: 60 })
//
//   scene    — id сцены (`b-door`, `b-drop`, `b-monolith`, `b-folder`);
//   state    — состояние сцены (у монолита `{ progress }`), без него — как в макете;
//   theme    — 'light' | 'dark': тема окна приложения, а не системы (её передаёт приложение);
//   still    — «Уменьшить движение»: сцена стоит на кадре 0;
//   playing  — false, когда окно не на экране: кадры не рисуются вовсе, время стоит;
//   fps      — потолок частоты кадров (0 — как у экрана).
//
// Поля можно передавать по отдельности. Новая сцена или новое состояние появляются растворением поверх прежней
// (0,45 с); у той же сцены время продолжается, поэтому, например, гильош монолита не перескакивает. Тема меняется
// сразу: окно приложения само растворяет смену темы. До первого кадра страница прозрачна, затем проявляется
// и сообщает приложению `{ type: 'shown' }`; после загрузки модуля — `{ type: 'loaded' }`.

import { ScenePlayer } from '../preview/player.js';
import { palette } from '../ink/palette.js';
import door from '../scenes/b/door.js';
import drop from '../scenes/b/drop.js';
import monolith from '../scenes/b/monolith.js';
import folder from '../scenes/b/folder.js';

const SCENES = Object.fromEntries([door, drop, monolith, folder].map((s) => [s.id, s]));
const FADE_MS = 450;

const stage = document.getElementById('stage');
const app = {
  theme: 'light',
  still: false,
  playing: true,
  fps: 0,
  slots: [],        // снизу вверх; верхний — текущий, нижние гаснут под ним
  shown: false,
  frames: 0,        // для проверки: сколько кадров нарисовано
};

const post = (msg) => window.webkit?.messageHandlers?.scene?.postMessage(msg);
const keyOf = (scene, state) => `${scene.id}|${JSON.stringify(state ?? null)}`;
const animating = () => app.playing && !app.still && !document.hidden;

// ───────────── Слои-сцены ─────────────

function addSlot(scene, state) {
  const top = app.slots.at(-1);
  const canvas = document.createElement('canvas');
  const slot = {
    scene,
    state,
    key: keyOf(scene, state),
    // Та же сцена в новом состоянии продолжает время прежней: поворот гильоша совпадает, растворение не видно.
    time: top && top.scene === scene ? top.time : 0,
    canvas,
    player: new ScenePlayer(canvas, scene),
  };
  if (top) canvas.style.opacity = '0';
  stage.append(canvas);
  app.slots.push(slot);
  place(slot);
  if (top) {
    // Сначала кадр с прозрачностью 0, потом переход к 1 — иначе CSS не увидит начала перехода.
    requestAnimationFrame(() => requestAnimationFrame(() => { canvas.style.opacity = '1'; }));
    setTimeout(() => retire(slot), FADE_MS + 60);
  }
}

/** Убирает всё, что лежит под `slot`: оно уже закрыто им целиком. */
function retire(slot) {
  const i = app.slots.indexOf(slot);
  if (i <= 0) return;
  for (const old of app.slots.splice(0, i)) old.canvas.remove();
}

/** Сцена вписывается в вид целиком и стоит по центру; вокруг — та же бумага, что и под сценой. */
function place(slot) {
  const [w, h] = slot.scene.size;
  const vw = window.innerWidth;
  const vh = window.innerHeight;
  const k = Math.min(vw / w, vh / h);
  const cw = w * k;
  const ch = h * k;
  Object.assign(slot.canvas.style, { width: `${cw}px`, height: `${ch}px`, left: `${(vw - cw) / 2}px`, top: `${(vh - ch) / 2}px` });
  slot.player.resize(cw);
}

// ───────────── Кадры ─────────────

let raf = 0;
let last = 0;

function schedule() {
  if (!raf) raf = requestAnimationFrame(frame);
}

function frame(now) {
  raf = 0;
  const moving = animating();
  const dt = last ? now - last : 0;
  // Потолок частоты: кадр раньше срока пропускаем, время не теряется — оно считается от последнего нарисованного.
  if (moving && app.fps && last && dt < 1000 / app.fps - 2) {
    schedule();
    return;
  }
  last = moving ? now : 0;
  // Длинный промежуток (окно было скрыто) не прибавляем: сцена продолжается с того же места.
  if (moving && dt > 0 && dt < 250) for (const s of app.slots) s.time += dt / 1000;
  render();
  if (moving) schedule();
}

function render() {
  const colors = palette[app.theme];
  for (const s of app.slots) {
    const t = app.still ? 0 : (s.time / s.scene.loop) % 1;
    s.player.draw(t, s.state, colors, app.theme);
  }
  app.frames++;
  if (!app.shown && app.slots.length) {
    app.shown = true;
    stage.classList.add('shown');
    post({ type: 'shown' });
  }
}

// ───────────── Управление из приложения ─────────────

function set(cfg = {}) {
  if (cfg.theme && palette[cfg.theme] && cfg.theme !== app.theme) app.theme = cfg.theme;
  if (cfg.still != null) app.still = !!cfg.still;
  if (cfg.playing != null) app.playing = !!cfg.playing;
  if (cfg.fps != null) app.fps = Number(cfg.fps) || 0;
  stage.style.background = palette[app.theme].paper;

  const scene = SCENES[cfg.scene] ?? app.slots.at(-1)?.scene;
  if (scene) {
    const state = 'state' in cfg ? cfg.state ?? undefined : app.slots.at(-1)?.state;
    if (!app.slots.length || app.slots.at(-1).key !== keyOf(scene, state)) addSlot(scene, state);
  }
  if (!animating()) last = 0;
  // Первый кадр — сразу, не дожидаясь requestAnimationFrame: пустая панель не должна ждать.
  if (!app.shown && app.slots.length) render();
  schedule();
}

function relayout() {
  for (const s of app.slots) place(s);
  schedule();
}
window.addEventListener('resize', relayout);
// Окно переехало на экран другой плотности: холст пересобирается под новую.
(function watchDensity() {
  matchMedia(`(resolution: ${window.devicePixelRatio}dppx)`).addEventListener('change', () => {
    relayout();
    watchDensity();
  }, { once: true });
})();
document.addEventListener('visibilitychange', () => {
  last = 0;
  schedule();
});

window.nekto = {
  set,
  /** Для проверки: сколько кадров нарисовано, что на экране. */
  stats: () => ({ frames: app.frames, slots: app.slots.map((s) => s.key), playing: animating(), theme: app.theme }),
};
post({ type: 'loaded' });

"use strict";

const state = {
  apps: [],
  view: "home",
  editingIndex: -1,
  form: { name: "", url: "" },
  oskTarget: null,
  confirmAction: null,
};

const $ = (sel) => document.querySelector(sel);

async function api(path, opts) {
  const r = await fetch(path, opts);
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(data.error || ("HTTP " + r.status));
  return data;
}

function showToast(msg, isError) {
  const t = $("#toast");
  t.textContent = msg;
  t.className = isError ? "error" : "";
  clearTimeout(showToast._timer);
  showToast._timer = setTimeout(() => t.classList.add("hidden"), 3500);
}

/* ---------- directional (remote-friendly) navigation ---------- */

function navRoot() {
  if (state.oskTarget) return $("#osk");
  return state.view === "settings" ? $("#view-settings .nav-scope") : $("#tiles");
}

function focusables() {
  const root = navRoot();
  if (!root) return [];
  return [...root.querySelectorAll("button, a[href]")].filter(
    (el) => el.offsetParent !== null && !el.disabled
  );
}

function moveFocus(dx, dy) {
  const els = focusables();
  if (!els.length) return;
  const cur = document.activeElement;
  const inList = cur && els.includes(cur);
  const cr = inList ? cur.getBoundingClientRect() : null;
  const cx = cr ? cr.left + cr.width / 2 : window.innerWidth / 2;
  const cy = cr ? cr.top + cr.height / 2 : window.innerHeight / 2;
  let best = null;
  let bestScore = Infinity;
  for (const el of els) {
    if (el === cur) continue;
    const r = el.getBoundingClientRect();
    const vx = r.left + r.width / 2 - cx;
    const vy = r.top + r.height / 2 - cy;
    if (dx && Math.sign(vx) !== dx) continue;
    if (dy && Math.sign(vy) !== dy) continue;
    const primary = dx ? Math.abs(vx) : Math.abs(vy);
    const perp = dx ? Math.abs(vy) : Math.abs(vx);
    if (primary < 4) continue;
    const score = primary + perp * 2.5;
    if (score < bestScore) {
      bestScore = score;
      best = el;
    }
  }
  if (best) best.focus();
}

function goBack() {
  if (state.oskTarget) {
    closeOsk(false);
    return;
  }
  if (state.editingIndex >= 0) {
    cancelForm();
    return;
  }
  if (state.view === "settings") setView("home");
}

document.addEventListener("keydown", (e) => {
  if (state.oskTarget) {
    if (e.key.startsWith("Arrow")) {
      e.preventDefault();
      const map = { ArrowUp: [0, -1], ArrowDown: [0, 1], ArrowLeft: [-1, 0], ArrowRight: [1, 0] };
      moveFocus(...map[e.key]);
    } else if (e.key === "Backspace" || e.key === "Escape") {
      e.preventDefault();
      closeOsk(false);
    } else if (e.key === " " && document.activeElement && document.activeElement.tagName === "BUTTON") {
      e.preventDefault();
      document.activeElement.click();
    }
    return;
  }
  switch (e.key) {
    case "ArrowUp": e.preventDefault(); moveFocus(0, -1); break;
    case "ArrowDown": e.preventDefault(); moveFocus(0, 1); break;
    case "ArrowLeft": e.preventDefault(); moveFocus(-1, 0); break;
    case "ArrowRight": e.preventDefault(); moveFocus(1, 0); break;
    case "Backspace":
    case "Escape":
      e.preventDefault();
      goBack();
      break;
    case "F10":
      e.preventDefault();
      setView(state.view === "home" ? "settings" : "home");
      break;
    case " ":
      if (document.activeElement && document.activeElement.tagName === "A") {
        e.preventDefault();
        document.activeElement.click();
      }
      break;
    default:
      break;
  }
});

/* ---------- views ---------- */

function setView(view) {
  state.view = view;
  $("#view-home").classList.toggle("hidden", view !== "home");
  $("#view-settings").classList.toggle("hidden", view !== "settings");
  $("#view-label").textContent = view;
  if (view === "settings") refreshStatus();
  const els = focusables();
  if (els.length) els[0].focus();
}

function renderHome() {
  const grid = $("#tiles");
  grid.innerHTML = "";
  if (!state.apps.length) {
    const p = document.createElement("p");
    p.className = "hint";
    p.textContent = "No apps yet. Press the menu key (or select Settings) to add your Emby / Jellyfin / Plex servers.";
    grid.appendChild(p);
  }
  for (const app of state.apps) {
    const a = document.createElement("a");
    a.className = "tile";
    a.href = app.url;
    a.target = "_blank";
    a.rel = "noopener";
    const span = document.createElement("span");
    span.textContent = app.name;
    a.appendChild(span);
    grid.appendChild(a);
  }
  const gear = document.createElement("button");
  gear.className = "tile tile-settings";
  gear.type = "button";
  gear.textContent = "⚙ Settings";
  gear.addEventListener("click", () => setView("settings"));
  grid.appendChild(gear);
}

function renderSettings() {
  const list = $("#apps-list");
  list.innerHTML = "";
  state.apps.forEach((app, i) => {
    const row = document.createElement("div");
    row.className = "app-row";
    const info = document.createElement("div");
    info.className = "app-info";
    const name = document.createElement("div");
    name.className = "app-name";
    name.textContent = app.name;
    const url = document.createElement("div");
    url.className = "app-url";
    url.textContent = app.url;
    info.appendChild(name);
    info.appendChild(url);
    const edit = document.createElement("button");
    edit.className = "btn";
    edit.type = "button";
    edit.textContent = "Edit";
    edit.addEventListener("click", () => startEdit(i));
    const del = document.createElement("button");
    del.className = "btn";
    del.type = "button";
    del.textContent = "Delete";
    del.addEventListener("click", () => deleteApp(i));
    row.appendChild(info);
    row.appendChild(edit);
    row.appendChild(del);
    list.appendChild(row);
  });
  renderForm();
}

function renderForm() {
  const form = $("#app-form");
  const editing = state.editingIndex >= 0;
  form.classList.toggle("hidden", !editing);
  if (!editing) return;
  $("#form-title").textContent = state.editingIndex < state.apps.length ? "Edit app" : "Add app";
  $("#field-name").innerHTML = "";
  $("#field-name").appendChild(fieldText(state.form.name));
  $("#field-url").innerHTML = "";
  $("#field-url").appendChild(fieldText(state.form.url));
}

function fieldText(value) {
  const span = document.createElement("span");
  span.textContent = value || "";
  const cur = document.createElement("span");
  cur.className = "cursor";
  span.appendChild(cur);
  return span;
}

function startEdit(i) {
  state.editingIndex = i;
  state.form = { name: state.apps[i].name, url: state.apps[i].url };
  renderForm();
  $("#field-name").focus();
}

function startAdd() {
  state.editingIndex = state.apps.length;
  state.form = { name: "", url: "http://" };
  renderForm();
  $("#field-name").focus();
}

function cancelForm() {
  state.editingIndex = -1;
  renderForm();
  $("#btn-add").focus();
}

async function saveForm() {
  const name = state.form.name.trim();
  const url = state.form.url.trim();
  if (!name) return showToast("Name is required", true);
  if (!/^https?:\/\//i.test(url)) return showToast("URL must start with http:// or https://", true);
  const apps = state.apps.slice();
  const entry = { name, url };
  if (state.editingIndex < apps.length) apps[state.editingIndex] = entry;
  else apps.push(entry);
  try {
    await api("/api/config", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ apps }),
    });
    showToast("Saved");
    state.editingIndex = -1;
    await loadConfig();
    setView("settings");
  } catch (err) {
    showToast(err.message, true);
  }
}

async function deleteApp(i) {
  const apps = state.apps.slice();
  apps.splice(i, 1);
  try {
    await api("/api/config", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ apps }),
    });
    showToast("Deleted");
    await loadConfig();
    setView("settings");
  } catch (err) {
    showToast(err.message, true);
  }
}

/* ---------- on-screen keyboard ---------- */

const OSK_ROWS = [
  ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
  ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
  ["a", "s", "d", "f", "g", "h", "j", "k", "l", ";"],
  ["z", "x", "c", "v", "b", "n", "m", ".", "-", "/"],
  ["@", ":", "_", "⌫", "␣", "OK", "CANCEL"],
];

function openOsk(target) {
  state.oskTarget = target;
  $("#osk-target").textContent =
    (target === "name" ? "Name: " : "URL: ") + state.form[target];
  const osk = $("#osk");
  osk.innerHTML = "";
  for (const row of OSK_ROWS) {
    for (const k of row) {
      const b = document.createElement("button");
      b.type = "button";
      b.className = "osk-key" + (k === "OK" ? " ok wide" : "") + (k === "CANCEL" ? " cancel wide" : "") + (["⌫", "␣"].includes(k) ? " wide" : "");
      b.textContent = k === "␣" ? "space" : k;
      b.dataset.key = k;
      b.addEventListener("click", () => oskPress(k));
      osk.appendChild(b);
    }
  }
  $("#osk-overlay").classList.remove("hidden");
  const els = focusables();
  if (els.length) els[0].focus();
}

function closeOsk() {
  state.oskTarget = null;
  $("#osk-overlay").classList.add("hidden");
  renderForm();
  if (state.editingIndex >= 0) {
    const f = $("#field-" + (state.lastTarget || "name"));
    (f || $("#btn-save")).focus();
  }
}

function oskPress(k) {
  const t = state.oskTarget;
  if (!t) return;
  if (k === "OK") return closeOsk(true);
  if (k === "CANCEL") return closeOsk(false);
  if (k === "⌫") state.form[t] = state.form[t].slice(0, -1);
  else if (k === "␣") state.form[t] += " ";
  else state.form[t] += k;
  $("#osk-target").textContent = (t === "name" ? "Name: " : "URL: ") + state.form[t];
}

/* ---------- status & system ---------- */

async function refreshStatus() {
  try {
    const data = await api("/api/status");
    const box = $("#status");
    box.innerHTML = "";
    for (const [svc, st] of Object.entries(data.services)) {
      const b = document.createElement("span");
      b.className = "badge";
      const ok = st === "active";
      b.innerHTML = "";
      const name = document.createElement("b");
      name.textContent = svc;
      const val = document.createElement("span");
      val.className = ok ? "ok" : "bad";
      val.textContent = " " + st;
      b.appendChild(name);
      b.appendChild(val);
      box.appendChild(b);
    }
  } catch (err) {
    /* ignore */
  }
}

async function systemAction(action, btn) {
  if (state.confirmAction !== action) {
    state.confirmAction = action;
    btn.classList.add("danger-armed");
    btn.textContent = "Press again to confirm";
    setTimeout(() => {
      state.confirmAction = null;
      btn.classList.remove("danger-armed");
      btn.textContent = action === "reboot" ? "Reboot" : "Power off";
    }, 3000);
    return;
  }
  state.confirmAction = null;
  try {
    await api("/api/system/" + action, { method: "POST" });
    showToast(action === "reboot" ? "Rebooting…" : "Powering off…");
  } catch (err) {
    showToast(err.message, true);
  }
}

/* ---------- init ---------- */

async function loadConfig() {
  const data = await api("/api/config");
  state.apps = data.apps || [];
  renderHome();
  renderSettings();
}

$("#btn-add").addEventListener("click", startAdd);
$("#btn-save").addEventListener("click", saveForm);
$("#btn-cancel").addEventListener("click", cancelForm);
$("#field-name").addEventListener("click", () => { state.lastTarget = "name"; openOsk("name"); });
$("#field-url").addEventListener("click", () => { state.lastTarget = "url"; openOsk("url"); });
$("#btn-reboot").addEventListener("click", (e) => systemAction("reboot", e.target));
$("#btn-poweroff").addEventListener("click", (e) => systemAction("poweroff", e.target));
$("#btn-home").addEventListener("click", () => setView("home"));

setInterval(() => {
  if (state.view === "settings" && !state.oskTarget) refreshStatus();
}, 10000);

loadConfig().then(() => setView("home")).catch((err) => showToast(err.message, true));

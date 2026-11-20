"use strict";

const state = {
  apps: [],
  view: "home",
  editingIndex: -1,
  form: { name: "", url: "", type: "browser", server: "url", item: "" },
  oskTarget: null,
  confirmAction: null,
  net: { interfaces: [], ifaceIdx: 0, mode: "dhcp", confirm: false },
  netForm: { address: "", gateway: "", dns: "" },
  media: { app: null, stack: [], items: [] },
};

const $ = (sel) => document.querySelector(sel);

const APP_TYPES = [
  { value: "mpv", label: "mpv (native HEVC)" },
  { value: "browser", label: "browser tab" },
];
const APP_SERVERS = [
  { value: "url", label: "url" },
  { value: "jellyfin", label: "jellyfin" },
  { value: "emby", label: "emby" },
  { value: "plex", label: "plex" },
];
const OSK_LABELS = {
  name: "Name", url: "URL", item: "Item ID",
  "net-address": "Address/CIDR", "net-gateway": "Gateway", "net-dns": "DNS (comma sep.)",
};

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
  if (state.view === "media") return $("#view-media .nav-scope");
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

function cycleValue(list, current, dir) {
  const i = list.findIndex((x) => x.value === current);
  const n = list[(i + dir + list.length) % list.length];
  return n.value;
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
  if (state.view === "media") {
    mediaBack();
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
  const cur = document.activeElement;
  if (cur && cur.classList && cur.classList.contains("cycle")) {
    if (e.key === "ArrowLeft" || e.key === "ArrowRight" || e.key === "Enter" || e.key === " ") {
      e.preventDefault();
      cur.dataset.dir = e.key === "ArrowLeft" ? "-1" : "1";
      cur.click();
      return;
    }
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
      if (cur && cur.tagName === "A") {
        e.preventDefault();
        cur.click();
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
  $("#view-media").classList.toggle("hidden", view !== "media");
  $("#view-label").textContent = view;
  if (view === "settings") { refreshStatus(); refreshNet(); }
  const els = focusables();
  if (els.length) els[0].focus();
}

/* ---------- home tiles + launch ---------- */

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
    if (app.type === "mpv") {
      const b = document.createElement("button");
      b.className = "tile tile-mpv";
      b.type = "button";
      const span = document.createElement("span");
      span.textContent = app.name;
      const badge = document.createElement("em");
      badge.className = "tile-badge";
      badge.textContent = "MPV";
      b.appendChild(span);
      b.appendChild(badge);
      b.addEventListener("click", () => openMedia(app));
      grid.appendChild(b);
    } else {
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
  }
  const gear = document.createElement("button");
  gear.className = "tile tile-settings";
  gear.type = "button";
  gear.textContent = "⚙ Settings";
  gear.addEventListener("click", () => setView("settings"));
  grid.appendChild(gear);
}

function openMedia(app) {
  if (app.type !== "mpv") {
    window.open(app.url, "_blank", "noopener");
    return;
  }
  state.media.app = app;
  state.media.stack = [];
  setView("media");
  loadMedia();
}

/* ---------- media browse (Jellyfin/Emby -> native MPV) ---------- */

function fmtTicks(t) {
  const s = Math.floor(t / 10000000);
  const m = Math.floor(s / 60);
  const h = Math.floor(m / 60);
  const mm = h > 0 ? String(m % 60).padStart(2, "0") : String(m % 60);
  return (h > 0 ? h + ":" + mm : mm) + ":" + String(s % 60).padStart(2, "0");
}

function mediaQ() {
  return "app=" + encodeURIComponent(state.media.app.name);
}

async function loadMedia() {
  const grid = $("#media-grid");
  grid.innerHTML = "";
  const p = document.createElement("p");
  p.className = "hint";
  p.textContent = "loading…";
  grid.appendChild(p);
  const stack = state.media.stack;
  $("#media-crumb").textContent =
    state.media.app.name + (stack.length ? " › " + stack.map((s) => s.name).join(" › ") : "");
  try {
    let items = [];
    if (!stack.length) {
      const [libs, res] = await Promise.all([
        api("/api/media/libraries?" + mediaQ()),
        api("/api/media/resume?" + mediaQ()).catch(() => ({ items: [] })),
      ]);
      for (const it of (res.items || [])) {
        if (!it.isFolder && it.resume > 0) items.push(Object.assign({ resumed: true }, it));
      }
      items = items.concat(libs.items || []);
    } else {
      const top = stack[stack.length - 1];
      const data = await api("/api/media/items?" + mediaQ() +
        "&parent=" + encodeURIComponent(top.id) +
        "&type=" + encodeURIComponent(top.type || "") +
        "&series=" + encodeURIComponent(top.series || ""));
      items = data.items || [];
    }
    state.media.items = items;
    renderMedia();
  } catch (err) {
    grid.innerHTML = "";
    const e = document.createElement("p");
    e.className = "hint";
    e.textContent = err.message + " — check the server URL and the credentials in /etc/jellyby/players.json (SSH)";
    grid.appendChild(e);
  }
}

function renderMedia() {
  const grid = $("#media-grid");
  grid.innerHTML = "";
  if (!state.media.items.length) {
    const p = document.createElement("p");
    p.className = "hint";
    p.textContent = "nothing here — check the server credentials in /etc/jellyby/players.json over SSH";
    grid.appendChild(p);
    return;
  }
  for (const it of state.media.items) {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "media-tile" + (it.resumed ? " resumed" : "");
    if (it.poster) {
      const img = document.createElement("img");
      img.className = "media-poster";
      img.loading = "lazy";
      img.alt = "";
      img.src = "/api/media/poster?" + mediaQ() + "&item=" + encodeURIComponent(it.id);
      img.addEventListener("error", () => img.remove());
      b.appendChild(img);
    }
    const label = document.createElement("span");
    label.className = "media-label";
    label.textContent = (it.resumed ? "▶ " : "") + it.name +
      (it.series ? " · " + it.series : "");
    b.appendChild(label);
    if (!it.isFolder && it.resume > 0) {
      const r = document.createElement("em");
      r.className = "media-resume";
      r.textContent = fmtTicks(it.resume);
      b.appendChild(r);
    }
    b.addEventListener("click", () => mediaSelect(it));
    grid.appendChild(b);
  }
  const els = focusables();
  if (els.length) els[0].focus();
}

function mediaSelect(it) {
  if (it.isFolder || it.type === "Series" || it.type === "Season") {
    const series = it.type === "Series" ? it.id : (it.series_id || "");
    state.media.stack.push({ id: it.id, name: it.name, type: it.type, series: series });
    loadMedia();
    return;
  }
  playItem(it);
}

async function playItem(it) {
  try {
    const res = await api("/api/media/play", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        app: state.media.app.name,
        item: it.id,
        start: it.resume || 0,
      }),
    });
    if (res.mode === "mpv") {
      showToast("Playing in MPV (native HEVC) — the remote exit key returns here");
    } else {
      showToast("MPV failed (" + (res.reason || "resolve") + ") — opening browser", true);
      window.open(res.url || state.media.app.url, "_blank", "noopener");
    }
  } catch (err) {
    showToast(err.message, true);
  }
}

function mediaBack() {
  if (state.media.stack.length) {
    state.media.stack.pop();
    loadMedia();
  } else {
    setView("home");
  }
}

/* ---------- settings: apps ---------- */

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
    name.textContent = app.name + "  [" + app.type + (app.server !== "url" ? "/" + app.server : "") + "]";
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

function cycleLabel(list, value) {
  const f = list.find((x) => x.value === value);
  return f ? f.label : value;
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
  $("#field-item").innerHTML = "";
  $("#field-item").appendChild(fieldText(state.form.item || ""));
  $("#field-type").textContent = cycleLabel(APP_TYPES, state.form.type);
  $("#field-server").textContent = cycleLabel(APP_SERVERS, state.form.server);
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
  const a = state.apps[i];
  state.form = { name: a.name, url: a.url, type: a.type || "browser", server: a.server || "url", item: a.item || "" };
  renderForm();
  $("#field-name").focus();
}

function startAdd() {
  state.editingIndex = state.apps.length;
  state.form = { name: "", url: "http://", type: "browser", server: "url", item: "" };
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
  const entry = { name, url, type: state.form.type, server: state.form.server };
  if (state.form.item.trim()) entry.item = state.form.item.trim();
  const apps = state.apps.slice();
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

/* ---------- settings: network ---------- */

async function refreshNet() {
  try {
    const data = await api("/api/network");
    state.net.interfaces = data.interfaces || [];
    if (!state.net.interfaces.length) {
      $("#net-current").textContent = "no interfaces found";
      return;
    }
    if (state.net.ifaceIdx >= state.net.interfaces.length) state.net.ifaceIdx = 0;
    const cur = state.net.interfaces[state.net.ifaceIdx];
    $("#net-current").textContent =
      state.net.interfaces.map((i) =>
        `${i.name} (${i.type}): ${i.state}${i.address ? " " + i.address : ""}${i.method ? " via " + i.method : ""}`
      ).join("  ·  ");
    $("#net-iface").textContent = cur.name;
    $("#net-mode").textContent = state.net.mode === "dhcp" ? "DHCP" : "Static";
    $("#net-static-fields").classList.toggle("hidden", state.net.mode !== "static");
    if (state.net.mode === "static") {
      $("#net-address").innerHTML = ""; $("#net-address").appendChild(fieldText(state.netForm.address || (cur.address || "")));
      $("#net-gateway").innerHTML = ""; $("#net-gateway").appendChild(fieldText(state.netForm.gateway || (cur.gateway || "")));
      $("#net-dns").innerHTML = ""; $("#net-dns").appendChild(fieldText(state.netForm.dns || (cur.dns || []).join(",")));
    }
  } catch (err) {
    $("#net-current").textContent = "network state unavailable: " + err.message;
  }
}

async function applyNet(btn) {
  if (!state.net.confirm) {
    state.net.confirm = true;
    btn.classList.add("danger-armed");
    btn.textContent = "Press again to APPLY (may drop this connection)";
    setTimeout(() => { state.net.confirm = false; btn.classList.remove("danger-armed"); btn.textContent = "Apply network"; }, 4000);
    return;
  }
  state.net.confirm = false;
  btn.classList.remove("danger-armed");
  btn.textContent = "Apply network";
  const cur = state.net.interfaces[state.net.ifaceIdx];
  const payload = { interface: cur.name, mode: state.net.mode, confirm: true };
  if (state.net.mode === "static") {
    payload.address = state.netForm.address.trim() || $("#net-address").textContent.trim();
    payload.gateway = state.netForm.gateway.trim() || $("#net-gateway").textContent.trim();
    payload.dns = (state.netForm.dns.trim() || $("#net-dns").textContent.trim()).split(",").map((s) => s.trim()).filter(Boolean);
  }
  try {
    await api("/api/network", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    showToast("Network applied — if you lose SSH, revert with: sudo /opt/jellyby/netapply.sh " + cur.name + " dhcp");
    await refreshNet();
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
  ["@", ":", "_", ",", "⌫", "␣", "OK", "CANCEL"],
];

function oskValue() {
  const t = state.oskTarget;
  if (!t) return "";
  if (t.startsWith("net-")) return state.netForm[t.slice(4)] || "";
  return state.form[t] || "";
}

function oskSet(v) {
  const t = state.oskTarget;
  if (!t) return;
  if (t.startsWith("net-")) state.netForm[t.slice(4)] = v;
  else state.form[t] = v;
}

function openOsk(target) {
  state.oskTarget = target;
  state.oskOriginal = oskValue();
  $("#osk-target").textContent = (OSK_LABELS[target] || target) + ": " + oskValue();
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

function closeOsk(accept) {
  if (!accept && state.oskTarget) oskSet(state.oskOriginal || "");
  state.oskTarget = null;
  $("#osk-overlay").classList.add("hidden");
  renderForm();
  refreshNet();
  if (state.editingIndex >= 0) {
    const f = $("#field-" + (state.lastTarget || "name"));
    (f || $("#btn-save")).focus();
  }
}

function oskPress(k) {
  if (!state.oskTarget) return;
  let v = oskValue();
  if (k === "OK") return closeOsk(true);
  if (k === "CANCEL") return closeOsk(false);
  if (k === "⌫") v = v.slice(0, -1);
  else if (k === "␣") v += " ";
  else v += k;
  oskSet(v);
  $("#osk-target").textContent = (OSK_LABELS[state.oskTarget] || state.oskTarget) + ": " + v;
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
$("#field-item").addEventListener("click", () => { state.lastTarget = "item"; openOsk("item"); });
$("#field-type").addEventListener("click", (e) => {
  const dir = Number(e.target.dataset.dir || 1);
  state.form.type = cycleValue(APP_TYPES, state.form.type, dir);
  renderForm();
});
$("#field-server").addEventListener("click", (e) => {
  const dir = Number(e.target.dataset.dir || 1);
  state.form.server = cycleValue(APP_SERVERS, state.form.server, dir);
  renderForm();
});
$("#net-iface").addEventListener("click", (e) => {
  const dir = Number(e.target.dataset.dir || 1);
  state.net.ifaceIdx = (state.net.ifaceIdx + dir + state.net.interfaces.length) % Math.max(1, state.net.interfaces.length);
  refreshNet();
});
$("#net-mode").addEventListener("click", (e) => {
  const dir = Number(e.target.dataset.dir || 1);
  state.net.mode = cycleValue([{ value: "dhcp" }, { value: "static" }], state.net.mode, dir);
  refreshNet();
});
$("#net-address").addEventListener("click", () => { state.lastTarget = "net-address"; openOsk("net-address"); });
$("#net-gateway").addEventListener("click", () => { state.lastTarget = "net-gateway"; openOsk("net-gateway"); });
$("#net-dns").addEventListener("click", () => { state.lastTarget = "net-dns"; openOsk("net-dns"); });
$("#btn-net-apply").addEventListener("click", (e) => applyNet(e.target));
$("#btn-reboot").addEventListener("click", (e) => systemAction("reboot", e.target));
$("#btn-poweroff").addEventListener("click", (e) => systemAction("poweroff", e.target));
$("#btn-home").addEventListener("click", () => setView("home"));

setInterval(() => {
  if (state.view === "settings" && !state.oskTarget) refreshStatus();
}, 10000);

loadConfig().then(() => setView("home")).catch((err) => showToast(err.message, true));

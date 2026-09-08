-- Single self-contained page for the local web UI. No CDN, fonts or network
-- assets: everything the browser needs is inline so the page works offline and
-- never leaks the session token to a third party via a Referer header.
local M = {}

-- Palette sampled from the user's wallpaper (see speech_webui_contract.md).
-- Tests assert that every colour below appears verbatim in the served page.
M.palette = {
  bg = "#081018",
  surface = "#0b1622",
  surface_alt = "#0e1c2a",
  border = "#102844",
  wave_line = "#142444",
  text = "#00a8f0",
  text_bright = "#5fd0ff",
  text_muted = "#4f86b4",
  accent = "#00d8c8",
  gradient_start = "#00a0f0",
  warning = "#f0b429",
  error = "#ff5c7a",
  indigo = "#7b6cff",
}

-- The page is served on every GET /; keep it small so the response is one
-- write and so a mistake in this file cannot turn into a memory bound problem.
M.html_bytes_max = 128 * 1024

local style = [[
:root{--bg:#081018;--surface:#0b1622;--surface-alt:#0e1c2a;--border:#102844;
--wave:#142444;--text:#00a8f0;--text-bright:#5fd0ff;--muted:#4f86b4;--accent:#00d8c8;
--grad-a:#00a0f0;--grad-b:#00d8c8;--warning:#f0b429;--error:#ff5c7a;--indigo:#7b6cff;
--font:"Inter","Cantarell","Noto Sans",system-ui,sans-serif;
--mono:"JetBrains Mono","Fira Code",ui-monospace,monospace}
*{box-sizing:border-box}
html,body{margin:0;min-height:100%;background:var(--bg);color:var(--text);
font:16px/1.5 var(--font)}
body{display:grid;grid-template-rows:auto 1fr auto;min-height:100vh}
header{display:flex;flex-wrap:wrap;align-items:center;gap:.75rem;padding:.75rem 1rem;
border-bottom:1px solid var(--border);background:var(--surface)}
h1{font-size:1.15rem;margin:0;font-weight:600;
background:linear-gradient(90deg,var(--grad-a),var(--grad-b));
-webkit-background-clip:text;background-clip:text;color:transparent}
.pill{display:inline-flex;align-items:center;gap:.4rem;padding:.15rem .6rem;
border:1px solid var(--border);border-radius:999px;background:var(--surface-alt);
font-size:.85rem;color:var(--text-bright)}
.pill::before{content:"";width:.55rem;height:.55rem;border-radius:50%;background:var(--muted)}
.pill.ok::before{background:var(--accent)}
.pill.warn::before{background:var(--warning)}
.pill.err::before{background:var(--error)}
main{display:grid;grid-template-columns:minmax(0,2fr) minmax(280px,1fr);gap:1rem;
padding:1rem;max-width:1200px;width:100%;margin:0 auto}
@media (max-width:820px){main{grid-template-columns:1fr}}
section{background:var(--surface);border:1px solid var(--border);border-radius:.75rem;
padding:1rem;display:flex;flex-direction:column;gap:.75rem;min-width:0}
h2{font-size:1rem;margin:0;color:var(--text-bright);font-weight:600}
#transcript{display:flex;flex-direction:column;gap:.6rem;min-height:14rem;max-height:52vh;
overflow:auto;padding-right:.25rem}
.msg{border-left:3px solid var(--wave);padding:.35rem .75rem;border-radius:.25rem;
background:var(--surface-alt);white-space:pre-wrap;word-break:break-word}
.msg .role{display:block;font-size:.75rem;text-transform:uppercase;letter-spacing:.06em;
color:var(--muted);margin-bottom:.15rem}
.msg.user{border-left-color:var(--text)}
.msg.assistant{border-left-color:var(--accent)}
.msg.error{border-left-color:var(--error);color:var(--error)}
textarea,input{width:100%;background:var(--bg);color:var(--text-bright);
border:1px solid var(--border);border-radius:.5rem;padding:.6rem;font:inherit;resize:vertical}
textarea:focus,input:focus,button:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.row{display:flex;flex-wrap:wrap;gap:.5rem;align-items:center}
button{font:inherit;font-weight:600;padding:.5rem .9rem;border-radius:.5rem;cursor:pointer;
border:1px solid var(--border);background:var(--surface-alt);color:var(--text-bright);
transition:background-color .15s ease,border-color .15s ease}
button.primary{background:linear-gradient(90deg,var(--grad-a),var(--grad-b));
color:var(--bg);border-color:transparent}
button:hover:not([disabled]){border-color:var(--accent)}
button[disabled]{cursor:not-allowed;opacity:.55}
button[aria-pressed="true"]{border-color:var(--error);color:var(--error)}
.hint{font-size:.85rem;color:var(--muted);margin:0}
.hint.warn{color:var(--warning)}
.hint.err{color:var(--error)}
pre{margin:0;font:.85rem/1.45 var(--mono);background:var(--bg);border:1px solid var(--border);
border-radius:.5rem;padding:.75rem;overflow:auto;max-height:40vh;color:var(--text-bright)}
details summary{cursor:pointer;color:var(--text-bright);font-weight:600}
audio{width:100%}
footer{padding:.5rem 1rem;border-top:1px solid var(--border);font-size:.8rem;color:var(--muted)}
.sr-only{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0)}
@media (prefers-reduced-motion:reduce){*{transition:none!important;animation:none!important;
scroll-behavior:auto!important}}
]]

local body = [[
<header>
  <h1>Rose</h1>
  <span id="pill-provider" class="pill" role="status">provider: …</span>
  <span id="pill-flow" class="pill" role="status">Flow: …</span>
  <span id="pill-speech" class="pill" role="status">speech: …</span>
</header>
<main>
  <section aria-labelledby="chat-title">
    <h2 id="chat-title">Chat</h2>
    <div id="transcript" role="log" aria-live="polite" aria-relevant="additions"></div>
    <label for="prompt" class="sr-only">Prompt</label>
    <textarea id="prompt" rows="3" placeholder="Ask Rose… (Ctrl+Enter sends)"></textarea>
    <div class="row">
      <button id="send" class="primary" type="button">Send</button>
      <button id="dictate" type="button" aria-pressed="false">Dictate</button>
      <button id="speak" type="button">Speak</button>
      <button id="clear" type="button">Clear</button>
    </div>
    <p id="speech-hint" class="hint" aria-live="polite"></p>
    <audio id="audio" controls hidden aria-label="Spoken reply"></audio>
  </section>
  <div style="display:flex;flex-direction:column;gap:1rem;min-width:0">
    <section aria-labelledby="flow-title">
      <h2 id="flow-title">Flow run</h2>
      <label for="flow-task" class="sr-only">Flow task</label>
      <textarea id="flow-task" rows="3" placeholder="Bounded task for Flow"></textarea>
      <div class="row"><button id="flow-run" class="primary" type="button">Run Flow</button></div>
      <p id="flow-hint" class="hint" aria-live="polite"></p>
      <pre id="flow-report" hidden></pre>
    </section>
    <section aria-labelledby="state-title">
      <details id="drawer">
        <summary id="state-title">Health and state</summary>
        <div class="row" style="margin:.5rem 0">
          <button id="refresh" type="button">Refresh</button>
        </div>
        <pre id="state">loading…</pre>
      </details>
    </section>
  </div>
</main>
<footer>Local only: loopback, session token, no TLS.
  Close Neovim or run :RoseWebUIStop to end.</footer>
]]

local script = [[
"use strict";
const token = new URLSearchParams(location.search).get("token") || "";
const MESSAGE_LIMIT = 64;
const messages = [];
const el = (id) => document.getElementById(id);
const state = { speech: null, provider: null, flow: null, recorder: null, chunks: [] };
async function api(path, options) {
  const headers = Object.assign({ Authorization: "Bearer " + token }, options.headers || {});
  const response = await fetch(path, Object.assign({}, options, { headers }));
  const type = response.headers.get("content-type") || "";
  if (!response.ok) {
    let detail = response.status + " " + response.statusText;
    if (type.startsWith("application/json")) {
      const data = await response.json();
      if (data.error) detail = data.error;
    }
    throw new Error(detail);
  }
  return type.startsWith("application/json") ? response.json() : response.blob();
}
function append(role, text, cls) {
  const box = document.createElement("div");
  box.className = "msg " + (cls || role);
  const label = document.createElement("span");
  label.className = "role";
  label.textContent = role;
  box.appendChild(label);
  box.appendChild(document.createTextNode(text));
  el("transcript").appendChild(box);
  el("transcript").scrollTop = el("transcript").scrollHeight;
}
function pill(id, text, cls) {
  const node = el(id);
  node.textContent = text;
  node.className = "pill " + cls;
}
function disable(button, reason) {
  button.disabled = true;
  button.title = reason;
  button.setAttribute("aria-disabled", "true");
}
function enable(button) {
  button.disabled = false;
  button.title = "";
  button.removeAttribute("aria-disabled");
}
function applySpeech(speech) {
  state.speech = speech;
  const stt = (speech.capabilities && speech.capabilities.stt || []).filter((c) => c.available);
  const tts = (speech.capabilities && speech.capabilities.tts || []).filter((c) => c.available);
  const reasons = [];
  if (!speech.available) {
    const why = "speech module unavailable: " + (speech.reason || "not installed");
    disable(el("dictate"), why); disable(el("speak"), why); reasons.push(why);
  } else {
    if (stt.length === 0) {
      const why = "no speech-to-text engine available";
      disable(el("dictate"), why); reasons.push(why);
    } else if (!("MediaRecorder" in window) || !navigator.mediaDevices) {
      const why = "this browser has no MediaRecorder / microphone access";
      disable(el("dictate"), why); reasons.push(why);
    } else enable(el("dictate"));
    if (tts.length === 0) {
      const why = "no text-to-speech engine available";
      disable(el("speak"), why); reasons.push(why);
    } else enable(el("speak"));
  }
  const ok = stt.length > 0 || tts.length > 0;
  pill("pill-speech", "speech: " + (ok ? "stt " + stt.length + " / tts " + tts.length : "off"),
    ok ? "ok" : "warn");
  el("speech-hint").textContent = reasons.join(" · ");
  el("speech-hint").className = "hint" + (reasons.length ? " warn" : "");
}
async function refresh() {
  try {
    const [health, data] = await Promise.all([api("/api/health", {}), api("/api/state", {})]);
    state.provider = data.provider; state.flow = data.flow;
    pill("pill-provider", "provider: " + data.provider.provider + (data.provider.model ?
      " / " + data.provider.model : ""), data.provider.cloud ? "warn" : "ok");
    pill("pill-flow", "Flow: " + (data.flow.available ? "ready" : "unavailable"),
      data.flow.available ? "ok" : "warn");
    applySpeech(data.speech);
    el("state").textContent = JSON.stringify({ health, state: data }, null, 2);
    if (!data.flow.available) disable(el("flow-run"), data.flow.reason || "Flow unavailable");
    else enable(el("flow-run"));
  } catch (error) {
    const why = "state unavailable: " + error.message;
    el("state").textContent = why;
    pill("pill-provider", "provider: error", "err");
    pill("pill-flow", "Flow: unknown", "err"); pill("pill-speech", "speech: unknown", "err");
    disable(el("dictate"), why); disable(el("speak"), why); disable(el("flow-run"), why);
  }
}
async function send() {
  const text = el("prompt").value.trim();
  if (!text) return;
  if (messages.length >= MESSAGE_LIMIT) messages.splice(0, 2);
  messages.push({ role: "user", content: text });
  append("user", text);
  el("prompt").value = "";
  el("send").disabled = true;
  try {
    const result = await api("/api/chat", { method: "POST",
      headers: { "Content-Type": "application/json" }, body: JSON.stringify({ messages }) });
    messages.push({ role: "assistant", content: result.message.content });
    append("assistant", result.message.content);
  } catch (error) {
    messages.pop();
    append("error", error.message, "error");
  } finally { el("send").disabled = false; el("prompt").focus(); }
}
async function speak() {
  const last = [...messages].reverse().find((m) => m.role === "assistant");
  const text = el("prompt").value.trim() || (last && last.content) || "";
  if (!text) { el("speech-hint").textContent = "Nothing to speak yet."; return; }
  el("speak").disabled = true;
  try {
    const blob = await api("/api/speech/speak", { method: "POST",
      headers: { "Content-Type": "application/json" }, body: JSON.stringify({ text }) });
    const audio = el("audio");
    if (audio.dataset.url) URL.revokeObjectURL(audio.dataset.url);
    audio.dataset.url = URL.createObjectURL(blob);
    audio.src = audio.dataset.url; audio.hidden = false;
    await audio.play().catch(() => {});
  } catch (error) { append("error", "speak: " + error.message, "error"); }
  finally { el("speak").disabled = false; }
}
async function dictate() {
  const button = el("dictate");
  if (state.recorder) { state.recorder.stop(); return; }
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    const recorder = new MediaRecorder(stream);
    state.chunks = [];
    recorder.ondataavailable = (event) => { if (event.data.size) state.chunks.push(event.data); };
    recorder.onstop = async () => {
      stream.getTracks().forEach((track) => track.stop());
      state.recorder = null; button.setAttribute("aria-pressed", "false");
      button.textContent = "Dictate";
      const blob = new Blob(state.chunks, { type: recorder.mimeType || "audio/webm" });
      try {
        const result = await api("/api/speech/transcribe", { method: "POST",
          headers: { "Content-Type": blob.type }, body: blob });
        el("prompt").value = (el("prompt").value + " " + result.text).trim();
        el("prompt").focus();
      } catch (error) { append("error", "transcribe: " + error.message, "error"); }
    };
    recorder.start();
    state.recorder = recorder;
    button.setAttribute("aria-pressed", "true"); button.textContent = "Stop";
    setTimeout(() => { if (state.recorder === recorder) recorder.stop(); }, 60000);
  } catch (error) { append("error", "microphone: " + error.message, "error"); }
}
async function runFlow() {
  const task = el("flow-task").value.trim();
  if (!task) return;
  el("flow-run").disabled = true; el("flow-hint").textContent = "running…";
  el("flow-hint").className = "hint";
  try {
    const report = await api("/api/flow/run", { method: "POST",
      headers: { "Content-Type": "application/json" }, body: JSON.stringify({ task }) });
    el("flow-report").hidden = false;
    el("flow-report").textContent = JSON.stringify(report, null, 2);
    el("flow-hint").textContent = "status: " + (report.status || "done");
  } catch (error) {
    el("flow-hint").textContent = error.message; el("flow-hint").className = "hint err";
  } finally { el("flow-run").disabled = false; }
}
el("send").addEventListener("click", send);
el("speak").addEventListener("click", speak);
el("dictate").addEventListener("click", dictate);
el("flow-run").addEventListener("click", runFlow);
el("refresh").addEventListener("click", refresh);
el("clear").addEventListener("click", () => { messages.length = 0;
  el("transcript").textContent = ""; });
el("prompt").addEventListener("keydown", (event) => {
  if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) { event.preventDefault(); send(); }
});
if (!token) append("error", "Missing session token: open the URL printed by :RoseWebUI.", "error");
refresh();
]]

--- Render the complete HTML document. Pure: the same input always yields the
--- same bytes, which lets the server compute Content-Length once at startup.
function M.html()
  local document = table.concat({
    '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n',
    '<meta name="viewport" content="width=device-width, initial-scale=1">\n',
    '<meta name="referrer" content="no-referrer">\n',
    '<meta name="color-scheme" content="dark">\n',
    "<title>Rose</title>\n<style>\n",
    style,
    "</style>\n</head>\n<body>\n",
    body,
    "<script>\n",
    script,
    "</script>\n</body>\n</html>\n",
  })
  assert(#document > 1024, "web UI page is implausibly small")
  assert(#document <= M.html_bytes_max, "web UI page exceeds html_bytes_max")
  for name, colour in pairs(M.palette) do
    assert(document:find(colour, 1, true), "palette colour missing from page: " .. name)
  end
  return document
end

return M

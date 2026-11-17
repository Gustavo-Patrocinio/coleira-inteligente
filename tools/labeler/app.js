/* Labeler UI: wires the video, the charts (uPlot) and the core.js logic. */
(function () {
  "use strict";
  const C = window.LabelerCore;
  const $ = (id) => document.getElementById(id);

  const WINDOWS_S = [10, 30, 120, Infinity];
  const SPEEDS = [0.25, 0.5, 1, 2, 4];
  const FRAME_S = 1 / 30;

  const state = {
    meta: null,
    timeline: null,
    phys: null,
    taps: {},
    segments: [],
    open: null, // { class_id, start_ms }
    armedSignalTap: null, // "start_device_ms" | "end_device_ms" while waiting for a chart click
    winIdx: 1,
    speedIdx: 2,
    charts: [],
    xVideoS: null, // chart x axis, in video seconds
  };

  const video = $("video");
  const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();

  // ------------------------------------------------------------ helpers

  function setStatus(msg, isError = false) {
    $("status").textContent = msg;
    $("status").classList.toggle("error", isError);
  }

  function readText(file) {
    return file.text();
  }

  function storageKey() {
    return state.meta ? `coleira-labeler:${state.meta.session_id}` : null;
  }

  function saveDraft() {
    const k = storageKey();
    if (!k) return;
    try {
      localStorage.setItem(k, JSON.stringify({ segments: state.segments, taps: state.taps }));
    } catch (_) { /* storage unavailable: no draft */ }
  }

  function loadDraft() {
    const k = storageKey();
    if (!k) return false;
    try {
      const d = JSON.parse(localStorage.getItem(k) || "null");
      if (!d) return false;
      state.segments = d.segments || [];
      state.taps = d.taps || {};
      return true;
    } catch (_) {
      return false;
    }
  }

  function download(name, text, type) {
    const url = URL.createObjectURL(new Blob([text], { type }));
    const a = Object.assign(document.createElement("a"), { href: url, download: name });
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  // --------------------------------------------------------------- sync

  function currentSync() {
    const s = C.syncFromTaps(state.taps);
    if (s.mode === "none" && state.timeline) {
      // no taps: align the first sample with the start of the video (display only)
      return { a: -state.timeline.deviceMs[0], b: 1, mode: "none" };
    }
    return s;
  }

  function recomputeX() {
    if (!state.timeline) return;
    const s = currentSync();
    const d = state.timeline.deviceMs;
    state.xVideoS = Float64Array.from(d, (v) => C.deviceToVideo(s, v) / 1000);
    for (const u of state.charts) {
      const data = u.data.slice();
      data[0] = state.xVideoS;
      u.setData(data, false);
    }
    renderSyncInfo(s);
    followVideo(true);
  }

  function renderSyncInfo(s) {
    for (const key of ["start_video_ms", "start_device_ms", "end_video_ms", "end_device_ms"]) {
      const v = state.taps[key];
      $(`v_${key}`).textContent = v == null ? "—" : key.includes("video") ? C.fmtTime(v) : `${(v / 1000).toFixed(2)} s`;
    }
    const info = {
      none: "not synced: the chart is only aligned by its start",
      offset: `offset applied (${((s.a) / 1000).toFixed(3)} s). Mark the end too to correct drift.`,
      drift: `offset + drift: ${((s.b - 1) * 1e6).toFixed(0)} ppm (${((s.b - 1) * 600).toFixed(2)} s every 10 min)`,
    }[s.mode];
    $("syncInfo").textContent = info;
  }

  // ------------------------------------------------------------- charts

  function bandsPlugin() {
    return {
      hooks: {
        draw: [
          (u) => {
            const { ctx, bbox } = u;
            const top = bbox.top, h = bbox.height;
            ctx.save();
            const all = state.open
              ? [...state.segments, { ...state.open, end_ms: video.currentTime * 1000, _open: true }]
              : state.segments;
            for (const s of all) {
              const x0 = u.valToPos(s.start_ms / 1000, "x", true);
              const x1 = u.valToPos(s.end_ms / 1000, "x", true);
              if (x1 < bbox.left || x0 > bbox.left + bbox.width) continue;
              ctx.fillStyle = C.CLASS_BY_ID[s.class_id].color;
              ctx.globalAlpha = s._open ? 0.12 : (s.confidence ?? 1) < 1 ? 0.1 : 0.2;
              ctx.fillRect(x0, top, x1 - x0, h);
              ctx.globalAlpha = 0.9;
              ctx.fillRect(x0, top, x1 - x0, 4 * devicePixelRatio);
            }
            // taps
            const s = currentSync();
            ctx.globalAlpha = 1;
            ctx.setLineDash([4, 4]);
            ctx.strokeStyle = css("--muted");
            for (const k of ["start_device_ms", "end_device_ms"]) {
              if (state.taps[k] == null) continue;
              const x = u.valToPos(C.deviceToVideo(s, state.taps[k]) / 1000, "x", true);
              ctx.beginPath(); ctx.moveTo(x, top); ctx.lineTo(x, top + h); ctx.stroke();
            }
            // video cursor
            ctx.setLineDash([]);
            ctx.strokeStyle = css("--cursor");
            ctx.lineWidth = 2 * devicePixelRatio;
            const xv = u.valToPos(video.currentTime, "x", true);
            ctx.beginPath(); ctx.moveTo(xv, top); ctx.lineTo(xv, top + h); ctx.stroke();
            ctx.restore();
          },
        ],
      },
    };
  }

  function makeChart(el, title, series, data, yLabel) {
    const axisColor = css("--muted");
    const grid = { stroke: css("--border"), width: 1 };
    const opts = {
      title,
      width: el.clientWidth || 900,
      height: 200,
      cursor: { drag: { x: false, y: false }, sync: { key: "imu" } },
      legend: { show: true },
      scales: { x: { time: false } },
      axes: [
        { stroke: axisColor, grid, values: (u, vals) => vals.map((v) => C.fmtTime(v * 1000)) },
        { stroke: axisColor, grid, label: yLabel },
      ],
      series: [{ label: "t", value: (u, v) => (v == null ? "—" : C.fmtTime(v * 1000)) }, ...series],
      plugins: [bandsPlugin()],
    };
    const u = new uPlot(opts, data, el);
    u.over.addEventListener("click", (e) => {
      const tVideoS = u.posToVal(e.offsetX, "x");
      if (state.armedSignalTap) {
        const s = currentSync();
        const clickDev = C.videoToDevice(s, tVideoS * 1000);
        const snapped = C.snapToPeak(state.timeline.deviceMs, state.phys.amag, clickDev, 500);
        state.taps[state.armedSignalTap] = snapped;
        disarm();
        saveDraft();
        recomputeX();
        return;
      }
      seek(tVideoS);
    });
    return u;
  }

  function buildCharts() {
    for (const u of state.charts) u.destroy();
    const p = state.phys;
    const x = state.xVideoS;
    const accSeries = [
      { label: "ax", stroke: "#4C78A8", width: 1 },
      { label: "ay", stroke: "#F58518", width: 1 },
      { label: "az", stroke: "#54A24B", width: 1 },
      { label: "|a|", stroke: css("--text"), width: 1.5 },
    ];
    const gyroSeries = [
      { label: "gx", stroke: "#4C78A8", width: 1 },
      { label: "gy", stroke: "#F58518", width: 1 },
      { label: "gz", stroke: "#54A24B", width: 1 },
    ];
    state.charts = [
      makeChart($("chartAcc"), "Accelerometer (g)", accSeries, [x, p.ax, p.ay, p.az, p.amag], "g"),
      makeChart($("chartGyro"), "Gyroscope (°/s)", gyroSeries, [x, p.gx, p.gy, p.gz], "°/s"),
    ];
  }

  function followVideo(force = false) {
    if (!state.charts.length || !state.xVideoS) return;
    const w = WINDOWS_S[state.winIdx];
    const t = video.currentTime;
    for (const u of state.charts) {
      if (w === Infinity) {
        const x = state.xVideoS;
        if (force) u.setScale("x", { min: x[0], max: x[x.length - 1] });
        else u.redraw(false);
      } else {
        u.setScale("x", { min: t - w / 2, max: t + w / 2 });
      }
    }
  }

  // -------------------------------------------------------------- video

  function seek(tS) {
    video.currentTime = Math.max(0, Math.min(video.duration || tS, tS));
    tick();
  }

  let rafPending = false;
  function tick() {
    if (rafPending) return;
    rafPending = true;
    requestAnimationFrame(() => {
      rafPending = false;
      const ms = video.currentTime * 1000;
      $("clock").textContent = C.fmtTime(ms);
      const i = C.segmentAt(state.segments, ms);
      const lab = $("nowLabel");
      if (i >= 0) {
        const c = C.CLASS_BY_ID[state.segments[i].class_id];
        lab.textContent = c.name + ((state.segments[i].confidence ?? 1) < 1 ? " (uncertain)" : "");
        lab.style.background = c.color;
      } else {
        lab.textContent = "no label";
        lab.style.background = "";
      }
      const os = $("openSeg");
      os.hidden = !state.open;
      if (state.open) {
        const c = C.CLASS_BY_ID[state.open.class_id];
        os.textContent = `● recording ${c.name} since ${C.fmtTime(state.open.start_ms)}`;
      }
      highlightRow(i);
      followVideo();
      if (!video.paused) tick();
    });
  }

  video.addEventListener("play", tick);
  video.addEventListener("seeked", tick);
  video.addEventListener("timeupdate", tick);

  // ----------------------------------------------------------- segments

  function closeOpen(atMs) {
    if (!state.open) return;
    state.segments = C.insertSegment(state.segments, {
      class_id: state.open.class_id,
      start_ms: Math.min(state.open.start_ms, atMs),
      end_ms: Math.max(state.open.start_ms, atMs),
      confidence: 1,
    });
    state.open = null;
  }

  function onClassKey(cls) {
    const now = video.currentTime * 1000;
    const same = state.open && state.open.class_id === cls.id;
    closeOpen(now);
    if (!same) state.open = { class_id: cls.id, start_ms: now };
    changed();
  }

  function changed() {
    saveDraft();
    renderSegments();
    renderLegend();
    for (const u of state.charts) u.redraw(false);
    tick();
  }

  function renderLegend() {
    const tot = C.totalsByClass(state.segments);
    $("legend").innerHTML = C.CLASSES.map((c) => {
      const min = (tot[c.id] || 0) / 60000;
      const ok = c.id <= 4 && min >= 3; // Phase 1 target: ≥ 3 min of classes 0–4
      return `<li><kbd>${c.key}</kbd><span class="sw" style="background:${c.color}"></span>${c.name}
        <span class="tot ${ok ? "ok" : ""}">${min.toFixed(1)} min</span></li>`;
    }).join("");
  }

  function renderSegments() {
    const body = $("segBody");
    body.innerHTML = state.segments.map((s, i) => {
      const c = C.CLASS_BY_ID[s.class_id];
      return `<tr data-i="${i}">
        <td>${C.fmtTime(s.start_ms)}</td><td>${C.fmtTime(s.end_ms)}</td>
        <td>${((s.end_ms - s.start_ms) / 1000).toFixed(1)} s</td>
        <td><span class="sw" style="display:inline-block;width:10px;height:10px;border-radius:2px;background:${c.color}"></span> ${c.name}</td>
        <td>${(s.confidence ?? 1).toFixed(2)}</td>
        <td><button class="small" data-del="${i}">delete</button></td></tr>`;
    }).join("");
    $("segCount").textContent = `(${state.segments.length})`;
    const ready = !!state.meta;
    $("exportLabels").disabled = !ready;
    $("exportMeta").disabled = !ready;
  }

  let lastHighlighted = -2;
  function highlightRow(i) {
    if (i === lastHighlighted) return;
    lastHighlighted = i;
    for (const tr of $("segBody").children) tr.classList.toggle("current", Number(tr.dataset.i) === i);
  }

  $("segBody").addEventListener("click", (e) => {
    const del = e.target.closest("[data-del]");
    if (del) {
      state.segments = C.removeSegment(state.segments, Number(del.dataset.del));
      changed();
      return;
    }
    const tr = e.target.closest("tr[data-i]");
    if (tr) seek(state.segments[Number(tr.dataset.i)].start_ms / 1000);
  });

  // --------------------------------------------------------------- taps

  function disarm() {
    state.armedSignalTap = null;
    document.querySelectorAll("button[data-tap]").forEach((b) => b.classList.remove("armed"));
  }

  document.querySelectorAll("button[data-tap]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const key = btn.dataset.tap;
      if (key.endsWith("video_ms")) {
        state.taps[key] = video.currentTime * 1000;
        saveDraft();
        recomputeX();
      } else {
        disarm();
        state.armedSignalTap = key;
        btn.classList.add("armed");
        setStatus("Click the tap peak on the chart (the click snaps to the nearest peak, ±0.5 s).");
      }
    });
  });

  $("clearSync").addEventListener("click", () => {
    state.taps = {};
    disarm();
    saveDraft();
    recomputeX();
  });

  // ------------------------------------------------------------ keyboard

  document.addEventListener("keydown", (e) => {
    if (e.target.matches("input, textarea, select")) return;
    if (e.ctrlKey || e.metaKey || e.altKey) return;
    const k = e.key.toLowerCase();
    const cls = C.CLASS_BY_KEY[k];
    if (cls) { onClassKey(cls); e.preventDefault(); return; }
    switch (k) {
      case " ": video.paused ? video.play() : video.pause(); break;
      case "arrowleft": seek(video.currentTime - (e.shiftKey ? 5 : 1)); break;
      case "arrowright": seek(video.currentTime + (e.shiftKey ? 5 : 1)); break;
      case ",": video.pause(); seek(video.currentTime - FRAME_S); break;
      case ".": video.pause(); seek(video.currentTime + FRAME_S); break;
      case "[": case "]":
        state.speedIdx = Math.max(0, Math.min(SPEEDS.length - 1, state.speedIdx + (k === "]" ? 1 : -1)));
        video.playbackRate = SPEEDS[state.speedIdx];
        $("speedLabel").textContent = `${SPEEDS[state.speedIdx]}×`;
        break;
      case "z":
        state.winIdx = (state.winIdx + 1) % WINDOWS_S.length;
        $("winLabel").textContent = WINDOWS_S[state.winIdx] === Infinity ? "all" : `${WINDOWS_S[state.winIdx]} s`;
        followVideo(true);
        break;
      case "enter": closeOpen(video.currentTime * 1000); changed(); break;
      case "escape": state.open = null; disarm(); changed(); break;
      case "delete": case "backspace": {
        const i = C.segmentAt(state.segments, video.currentTime * 1000);
        if (i >= 0) { state.segments = C.removeSegment(state.segments, i); changed(); }
        break;
      }
      case "i": {
        const i = C.segmentAt(state.segments, video.currentTime * 1000);
        if (i >= 0) {
          const s = state.segments[i];
          state.segments[i] = { ...s, confidence: (s.confidence ?? 1) < 1 ? 1 : 0.5 };
          changed();
        }
        break;
      }
      default: return;
    }
    e.preventDefault();
  });

  // --------------------------------------------------------------- files

  async function loadSession({ csvFile, metaFile, videoFile }) {
    try {
      if (!csvFile || !metaFile) throw new Error("missing imu.csv or meta.json");
      const meta = JSON.parse(await readText(metaFile));
      const cols = C.parseImuCsv(await readText(csvFile));
      state.meta = meta;
      state.timeline = C.buildTimeline(cols);
      state.phys = C.toPhysical(cols, meta.accel_range ?? 16, meta.gyro_range ?? 2000);
      state.segments = [];
      state.taps = { ...(meta.sync_taps || {}) };
      state.open = null;
      const restored = loadDraft();
      if (videoFile) video.src = URL.createObjectURL(videoFile);

      const s = currentSync();
      state.xVideoS = Float64Array.from(state.timeline.deviceMs, (v) => C.deviceToVideo(s, v) / 1000);
      buildCharts();
      recomputeX();
      renderSegments();
      renderLegend();

      const tl = state.timeline;
      $("sessionInfo").innerHTML = `
        <b>${meta.session_id}</b> · dog ${meta.dog_id ?? "?"}<br>
        ${cols.seq.length.toLocaleString("en-US")} samples, measured ODR ${tl.odrHz.toFixed(2)} Hz<br>
        packets: ${tl.packetsReceived}/${tl.packetsExpected}
        (loss <b style="color:${tl.packetLoss < 0.01 ? "#2b8a3e" : "#c92a2a"}">${(tl.packetLoss * 100).toFixed(2)}%</b>, target < 1%)<br>
        ranges: ±${meta.accel_range} g, ±${meta.gyro_range} dps`;
      setStatus(
        `Session ${meta.session_id} loaded${videoFile ? "" : " (no video)"}.` +
        (restored ? " Restored the previous draft from this browser." : "")
      );
    } catch (err) {
      console.error(err);
      setStatus(`Could not open: ${err.message}`, true);
    }
  }

  $("dirInput").addEventListener("change", (e) => {
    const files = [...e.target.files];
    const byName = (re) => files.find((f) => re.test(f.name));
    loadSession({
      csvFile: byName(/^imu\.csv$/i),
      metaFile: byName(/^meta\.json$/i),
      videoFile: files.find((f) => f.type.startsWith("video/")) || byName(/\.(mp4|mov|webm|mkv)$/i),
    });
  });

  const loose = {};
  for (const [id, key] of [["csvInput", "csvFile"], ["metaInput", "metaFile"], ["videoInput", "videoFile"]]) {
    $(id).addEventListener("change", (e) => {
      loose[key] = e.target.files[0];
      if (loose.csvFile && loose.metaFile) loadSession(loose);
    });
  }

  $("labelsInput").addEventListener("change", async (e) => {
    const f = e.target.files[0];
    if (!f) return;
    state.segments = C.parseLabelsCsv(await readText(f)).reduce(C.insertSegment, []);
    changed();
    setStatus(`Imported ${state.segments.length} segments from ${f.name}.`);
  });

  $("exportLabels").addEventListener("click", () => {
    closeOpen(video.currentTime * 1000);
    changed();
    download(`${state.meta.session_id}.csv`, C.labelsToCsv(state.segments, $("annotator").value), "text/csv");
  });

  $("exportMeta").addEventListener("click", () => {
    const meta = { ...state.meta, sync_taps: { ...state.taps } };
    download("meta.json", JSON.stringify(meta, null, 2) + "\n", "application/json");
  });

  // annotator name remembered in this browser
  try { $("annotator").value = localStorage.getItem("coleira-labeler:annotator") || ""; } catch (_) {}
  $("annotator").addEventListener("change", (e) => {
    try { localStorage.setItem("coleira-labeler:annotator", e.target.value); } catch (_) {}
  });

  window.addEventListener("resize", () => {
    for (const u of state.charts) u.setSize({ width: u.root.parentElement.clientWidth, height: 200 });
  });

  renderLegend();
})();

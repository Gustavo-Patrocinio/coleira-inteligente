/*
 * Lógica pura do labeler (sem DOM), testável com `node --test`.
 * Carregado como script clássico (sem módulos ES), porque módulos não funcionam
 * em páginas abertas via file:// e o labeler não tem build step.
 *
 * Tempos:
 *   device_ms : relógio da coleira (CSV, contrato 4.5)
 *   video_ms  : tempo do vídeo; os rótulos são exportados nele (contrato 4.6)
 * O mapeamento video_ms = a + b * device_ms vem das batidinhas (ADR 0003).
 */
(function (root) {
  "use strict";

  const SAMPLES_PER_PACKET = 10; // contrato 4.4
  const UNKNOWN = 255;

  const CLASSES = [
    { id: 0, key: "0", name: "parado", color: "#4C78A8" },
    { id: 1, key: "1", name: "andando", color: "#54A24B" },
    { id: 2, key: "2", name: "correndo", color: "#F58518" },
    { id: 3, key: "3", name: "cocando", color: "#E45756" },
    { id: 4, key: "4", name: "chacoalhando", color: "#B279A2" },
    { id: 5, key: "5", name: "comendo", color: "#9D755D" },
    { id: 6, key: "6", name: "bebendo", color: "#72B7B2" },
    { id: UNKNOWN, key: "x", name: "desconhecido", color: "#9A9A9A" },
  ];
  const CLASS_BY_ID = Object.fromEntries(CLASSES.map((c) => [c.id, c]));
  const CLASS_BY_KEY = Object.fromEntries(CLASSES.map((c) => [c.key, c]));

  // ------------------------------------------------------------------ CSV

  /** imu.csv (contrato 4.5) → colunas como arrays numéricos. */
  function parseImuCsv(text) {
    const lines = text.trim().split(/\r?\n/);
    const header = lines[0].split(",").map((h) => h.trim());
    const need = ["phone_ts_ms", "device_ms", "seq", "ax", "ay", "az", "gx", "gy", "gz"];
    for (const n of need) {
      if (!header.includes(n)) throw new Error(`coluna ausente no CSV: ${n}`);
    }
    const idx = Object.fromEntries(need.map((n) => [n, header.indexOf(n)]));
    const cols = Object.fromEntries(need.map((n) => [n, new Float64Array(lines.length - 1)]));
    let k = 0;
    for (let i = 1; i < lines.length; i++) {
      if (!lines[i]) continue;
      const p = lines[i].split(",");
      for (const n of need) cols[n][k] = Number(p[idx[n]]);
      k++;
    }
    for (const n of need) cols[n] = cols[n].subarray(0, k);
    return cols;
  }

  // ------------------------------------------------------------ timeline

  /** Desembrulha o seq uint16 (dá a volta em 65535). */
  function unwrapSeq(seq) {
    const out = new Float64Array(seq.length);
    let offset = 0;
    for (let i = 0; i < seq.length; i++) {
      if (i > 0 && seq[i] < seq[i - 1] - 32768) offset += 65536;
      out[i] = seq[i] + offset;
    }
    return out;
  }

  /**
   * Índice global de cada amostra, contando as amostras dos pacotes perdidos.
   * Amostras do mesmo pacote compartilham `seq`; a posição dentro do pacote é a ordem.
   */
  function sampleIndex(seq) {
    const useq = unwrapSeq(seq);
    const first = useq[0];
    const k = new Float64Array(seq.length);
    let pos = 0;
    for (let i = 0; i < seq.length; i++) {
      pos = i > 0 && useq[i] === useq[i - 1] ? pos + 1 : 0;
      k[i] = (useq[i] - first) * SAMPLES_PER_PACKET + pos;
    }
    return k;
  }

  /** Regressão linear simples y = a + b x. */
  function linfit(x, y) {
    const n = x.length;
    let sx = 0, sy = 0;
    for (let i = 0; i < n; i++) { sx += x[i]; sy += y[i]; }
    const mx = sx / n, my = sy / n;
    let sxx = 0, sxy = 0;
    for (let i = 0; i < n; i++) {
      const dx = x[i] - mx;
      sxx += dx * dx;
      sxy += dx * (y[i] - my);
    }
    const b = sxx > 0 ? sxy / sxx : 0;
    return { a: my - b * mx, b };
  }

  /**
   * Tempo do dispositivo para cada amostra, estimando a taxa REAL do IMU por regressão
   * de device_ms contra o índice da amostra (ADR 0003), em vez de supor 20 ms exatos.
   */
  function buildTimeline(cols) {
    const k = sampleIndex(cols.seq);
    const fit = linfit(k, cols.device_ms);
    const t = new Float64Array(k.length);
    for (let i = 0; i < k.length; i++) t[i] = fit.a + fit.b * k[i];
    const useq = unwrapSeq(cols.seq);
    const expected = useq[useq.length - 1] - useq[0] + 1;
    let received = 1;
    for (let i = 1; i < useq.length; i++) if (useq[i] !== useq[i - 1]) received++;
    return {
      deviceMs: t,
      samplePeriodMs: fit.b,
      odrHz: 1000 / fit.b,
      packetsExpected: expected,
      packetsReceived: received,
      packetLoss: 1 - received / expected,
    };
  }

  /** Valores crus int16 → g e °/s, usando as faixas do meta.json. */
  function toPhysical(cols, accelRangeG, gyroRangeDps) {
    const ka = accelRangeG / 32768, kg = gyroRangeDps / 32768;
    const n = cols.ax.length;
    const out = {};
    for (const c of ["ax", "ay", "az"]) out[c] = Float64Array.from(cols[c], (v) => v * ka);
    for (const c of ["gx", "gy", "gz"]) out[c] = Float64Array.from(cols[c], (v) => v * kg);
    out.amag = new Float64Array(n);
    for (let i = 0; i < n; i++) {
      out.amag[i] = Math.hypot(out.ax[i], out.ay[i], out.az[i]);
    }
    return out;
  }

  // ---------------------------------------------------------------- sync

  /**
   * Mapeamento device_ms → video_ms a partir das batidinhas.
   * Só início: offset puro (b = 1). Início + fim: offset + correção de deriva.
   */
  function syncFromTaps(taps) {
    const s = taps && taps.start_video_ms != null && taps.start_device_ms != null;
    const e = taps && taps.end_video_ms != null && taps.end_device_ms != null;
    if (!s) return { a: 0, b: 1, mode: "none" };
    if (!e) return { a: taps.start_video_ms - taps.start_device_ms, b: 1, mode: "offset" };
    const dd = taps.end_device_ms - taps.start_device_ms;
    if (Math.abs(dd) < 1) throw new Error("batidinhas de início e fim no mesmo instante");
    const b = (taps.end_video_ms - taps.start_video_ms) / dd;
    return { a: taps.start_video_ms - b * taps.start_device_ms, b, mode: "drift" };
  }

  const deviceToVideo = (sync, d) => sync.a + sync.b * d;
  const videoToDevice = (sync, v) => (v - sync.a) / sync.b;

  /** Pico de |a| mais próximo dentro de ±windowMs (para "grudar" o clique na batida). */
  function snapToPeak(deviceMs, amag, clickDeviceMs, windowMs = 500) {
    let best = -1, bestV = -Infinity;
    for (let i = 0; i < deviceMs.length; i++) {
      if (Math.abs(deviceMs[i] - clickDeviceMs) <= windowMs && amag[i] > bestV) {
        bestV = amag[i];
        best = i;
      }
    }
    return best < 0 ? clickDeviceMs : deviceMs[best];
  }

  // ------------------------------------------------------------ segments

  /** Ordena e remove sobreposições: o segmento mais novo "corta" os antigos. */
  function insertSegment(segments, seg) {
    if (!(seg.end_ms > seg.start_ms)) return segments.slice();
    const out = [];
    for (const s of segments) {
      if (s.end_ms <= seg.start_ms || s.start_ms >= seg.end_ms) {
        out.push(s);
        continue;
      }
      if (s.start_ms < seg.start_ms) out.push({ ...s, end_ms: seg.start_ms });
      if (s.end_ms > seg.end_ms) out.push({ ...s, start_ms: seg.end_ms });
    }
    out.push({ ...seg });
    return out.sort((x, y) => x.start_ms - y.start_ms);
  }

  function segmentAt(segments, t) {
    return segments.findIndex((s) => s.start_ms <= t && t < s.end_ms);
  }

  function removeSegment(segments, i) {
    return segments.filter((_, j) => j !== i);
  }

  /** Minutos por classe (critério de pronto da Fase 1: ≥ 3 min de cada classe 0–4). */
  function totalsByClass(segments) {
    const tot = {};
    for (const s of segments) tot[s.class_id] = (tot[s.class_id] || 0) + (s.end_ms - s.start_ms);
    return tot;
  }

  // -------------------------------------------------------------- export

  /** Rótulos no formato do contrato 4.6 (tempo relativo ao início do vídeo). */
  function labelsToCsv(segments, annotator) {
    const safe = String(annotator || "").replace(/[,\r\n]/g, " ").trim();
    const rows = ["start_ms,end_ms,class_id,annotator,confidence"];
    for (const s of [...segments].sort((x, y) => x.start_ms - y.start_ms)) {
      rows.push([
        Math.round(s.start_ms),
        Math.round(s.end_ms),
        s.class_id,
        safe,
        (s.confidence ?? 1).toFixed(2),
      ].join(","));
    }
    return rows.join("\n") + "\n";
  }

  function parseLabelsCsv(text) {
    const lines = text.trim().split(/\r?\n/).slice(1).filter(Boolean);
    return lines.map((l) => {
      const p = l.split(",");
      return {
        start_ms: Number(p[0]),
        end_ms: Number(p[1]),
        class_id: Number(p[2]),
        confidence: p[4] !== undefined ? Number(p[4]) : 1,
      };
    });
  }

  function fmtTime(ms) {
    const neg = ms < 0 ? "-" : "";
    ms = Math.abs(ms);
    const m = Math.floor(ms / 60000);
    const s = (ms % 60000) / 1000;
    return `${neg}${m}:${s.toFixed(2).padStart(5, "0")}`;
  }

  const api = {
    SAMPLES_PER_PACKET, UNKNOWN, CLASSES, CLASS_BY_ID, CLASS_BY_KEY,
    parseImuCsv, unwrapSeq, sampleIndex, linfit, buildTimeline, toPhysical,
    syncFromTaps, deviceToVideo, videoToDevice, snapToPeak,
    insertSegment, segmentAt, removeSegment, totalsByClass,
    labelsToCsv, parseLabelsCsv, fmtTime,
  };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.LabelerCore = api;
})(typeof window !== "undefined" ? window : globalThis);

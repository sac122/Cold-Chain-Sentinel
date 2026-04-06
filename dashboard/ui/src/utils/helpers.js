// ── Temperature helpers ───────────────────────────────────────────────────────

export function formatTemp(c) {
  if (c == null) return "N/A";
  return `${c >= 0 ? "+" : ""}${c.toFixed(1)}°C`;
}

export function tempColor(c) {
  if (c == null) return "text-slate-400";
  if (c > -10)  return "text-red-400";
  if (c > -15)  return "text-amber-400";
  return "text-emerald-400";
}

export function tempBg(c) {
  if (c == null) return "bg-slate-700";
  if (c > -10)  return "bg-red-500";
  if (c > -15)  return "bg-amber-500";
  return "bg-emerald-500";
}

export function chartLineColor(c) {
  if (c == null) return "#64748b";
  if (c > -10)  return "#f87171";
  if (c > -15)  return "#fbbf24";
  return "#34d399";
}

// ── Status helpers ────────────────────────────────────────────────────────────

export function statusLabel(s) {
  return { normal: "Normal", warning: "Warning",
           critical: "Critical", offline: "Offline", unknown: "Unknown" }[s] ?? s;
}

export function statusDotClass(s) {
  return {
    normal:   "bg-emerald-400",
    warning:  "bg-amber-400",
    critical: "bg-red-400 flicker",
    offline:  "bg-slate-500",
    unknown:  "bg-slate-500",
  }[s] ?? "bg-slate-500";
}

export function statusRingClass(s) {
  return {
    normal:   "ring-emerald-500/30",
    warning:  "ring-amber-500/40",
    critical: "ring-red-500/50",
    offline:  "ring-slate-600/30",
    unknown:  "ring-slate-600/30",
  }[s] ?? "ring-slate-600/30";
}

// ── Event helpers ─────────────────────────────────────────────────────────────

export function severityClass(sev) {
  return {
    CRITICAL: "badge badge-critical",
    WARNING:  "badge badge-warning",
    INFO:     "badge bg-sky-500/20 text-sky-400",
  }[sev] ?? "badge badge-unknown";
}

export function severityBorder(sev) {
  return {
    CRITICAL: "border-red-500/40",
    WARNING:  "border-amber-500/40",
    INFO:     "border-sky-500/30",
  }[sev] ?? "border-slate-700/40";
}

export function eventTypeLabel(t) {
  return {
    TEMP_EXCURSION:    "🌡 Temp Excursion",
    DOOR_OPEN_TOO_LONG:"🚪 Door Open",
    BATTERY_LOW:       "🔋 Battery Low",
    SENSOR_STUCK:      "📌 Sensor Stuck",
    ANOMALY:           "⚡ Anomaly",
    GPS_JUMP:          "📍 GPS Jump",
    COMPRESSOR_FAIL:   "❄ Compressor Fail",
  }[t] ?? t;
}

// ── Time helpers ──────────────────────────────────────────────────────────────

export function relativeTime(ts) {
  if (!ts) return "—";
  const diff = Date.now() / 1000 - ts;
  if (diff < 5)   return "just now";
  if (diff < 60)  return `${Math.floor(diff)}s ago`;
  if (diff < 3600)return `${Math.floor(diff / 60)}m ago`;
  return `${Math.floor(diff / 3600)}h ago`;
}

export function fmtTime(ts) {
  if (!ts) return "—";
  return new Date(ts * 1000).toLocaleTimeString();
}

// ── Battery ───────────────────────────────────────────────────────────────────

export function batteryColor(v) {
  if (v == null) return "text-slate-400";
  if (v < 11.0)  return "text-red-400";
  if (v < 11.5)  return "text-amber-400";
  return "text-emerald-400";
}

export function batteryPct(v) {
  // 12.6V = 100%, 10.5V = 0%
  if (v == null) return 0;
  return Math.max(0, Math.min(100, ((v - 10.5) / 2.1) * 100));
}

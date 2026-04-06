/**
 * CommandCenter — slide-over control panel for real-time simulator control.
 *
 * Features
 * --------
 *  - Device selector (all live devices)
 *  - Door toggle  → POST /api/control/{id}/door
 *  - Temperature override slider → POST /api/control/{id}/temp
 *  - Battery override slider    → POST /api/control/{id}/battery
 *  - Scenario injection buttons → POST /api/control/{id}/scenario
 *  - Per-device Reset           → POST /api/control/{id}/reset
 *  - Command log (last 15 commands, colour-coded success/error)
 */
import { useState, useEffect } from "react";
import {
  X, Terminal, DoorOpen, DoorClosed, Thermometer, BatteryMedium,
  RotateCcw, Zap, ChevronDown,
} from "lucide-react";

// ── Scenario definitions ─────────────────────────────────────────────────────

const SCENARIOS = [
  {
    id:    "compressor_fail",
    label: "Compressor Fail",
    icon:  "❄️",
    color: "border-red-500/40 hover:bg-red-500/10 text-red-300",
    activeColor: "bg-red-500/20 border-red-500 text-red-200",
    desc:  "+0.05°C per tick — temp rises until compressor is fixed",
  },
  {
    id:    "door_open",
    label: "Door Open",
    icon:  "🚪",
    color: "border-amber-500/40 hover:bg-amber-500/10 text-amber-300",
    activeColor: "bg-amber-500/20 border-amber-500 text-amber-200",
    desc:  "Forces door open for ~8 minutes (240 ticks)",
  },
  {
    id:    "sensor_stuck",
    label: "Sensor Stuck",
    icon:  "📌",
    color: "border-sky-500/40 hover:bg-sky-500/10 text-sky-300",
    activeColor: "bg-sky-500/20 border-sky-500 text-sky-200",
    desc:  "Freezes temperature reading for ~2 minutes (60 ticks)",
  },
  {
    id:    "gps_jump",
    label: "GPS Jump",
    icon:  "📍",
    color: "border-purple-500/40 hover:bg-purple-500/10 text-purple-300",
    activeColor: "bg-purple-500/20 border-purple-500 text-purple-200",
    desc:  "One-shot ~500 km GPS teleport",
  },
];

// ── Helpers ──────────────────────────────────────────────────────────────────

async function apiPost(path, body) {
  const res = await fetch(path, {
    method:  "POST",
    headers: { "Content-Type": "application/json" },
    body:    JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}

function LogEntry({ entry }) {
  return (
    <div className={`flex items-start gap-2 text-xs py-1 border-b border-slate-800/60
                     last:border-0 font-mono`}>
      <span className="text-slate-600 shrink-0 tabular-nums">{entry.ts}</span>
      <span className={entry.ok ? "text-emerald-400" : "text-red-400"}>
        {entry.ok ? "✓" : "✗"}
      </span>
      <span className={entry.ok ? "text-slate-300" : "text-red-300"}>
        {entry.msg}
      </span>
    </div>
  );
}

// ── Main component ───────────────────────────────────────────────────────────

export default function CommandCenter({ devices, onClose }) {
  const deviceIds = Object.keys(devices).sort();
  const [selectedId,     setSelectedId]     = useState(deviceIds[0] ?? "");
  const [log,            setLog]            = useState([]);

  // Per-UI state (not per-device — we don't sync back from server)
  const [doorForced,     setDoorForced]     = useState(null);   // null | true | false
  const [tempEnabled,    setTempEnabled]    = useState(false);
  const [tempValue,      setTempValue]      = useState(-18);
  const [battEnabled,    setBattEnabled]    = useState(false);
  const [battValue,      setBattValue]      = useState(12.0);
  const [activeScenarios,setActiveScenarios]= useState(new Set());

  // Reset local UI state whenever the selected device changes
  useEffect(() => {
    setDoorForced(null);
    setTempEnabled(false);
    setTempValue(-18);
    setBattEnabled(false);
    setBattValue(12.0);
    setActiveScenarios(new Set());
  }, [selectedId]);

  // Keep deviceIds in sync — if the selected device disappears, pick first
  useEffect(() => {
    if (deviceIds.length && !deviceIds.includes(selectedId)) {
      setSelectedId(deviceIds[0]);
    }
  }, [deviceIds.join(",")]);  // eslint-disable-line react-hooks/exhaustive-deps

  // ── Logging helper ───────────────────────────────────────────────────────

  const addLog = (msg, ok = true) => {
    const ts = new Date().toLocaleTimeString("en-US", { hour12: false });
    setLog(prev => [{ ts, msg, ok }, ...prev].slice(0, 15));
  };

  // ── Command senders ──────────────────────────────────────────────────────

  const send = async (label, path, body) => {
    if (!selectedId) return;
    try {
      await apiPost(`/api/control/${selectedId}/${path}`, body);
      addLog(`[${selectedId}] ${label}`);
    } catch (e) {
      addLog(`[${selectedId}] ${label} FAILED: ${e.message}`, false);
    }
  };

  const handleDoor = async (open) => {
    await send(open ? "open door" : "close door", "door", { open });
    setDoorForced(open);
  };

  const handleTempToggle = async (enabled) => {
    setTempEnabled(enabled);
    if (enabled) {
      await send(`set temp → ${tempValue}°C`, "temp", { value: tempValue });
    } else {
      await send("clear temp override", "temp", { value: null });
    }
  };

  const handleTempSlider = async (v) => {
    setTempValue(v);
    if (tempEnabled) {
      await send(`set temp → ${v}°C`, "temp", { value: v });
    }
  };

  const handleBattToggle = async (enabled) => {
    setBattEnabled(enabled);
    if (enabled) {
      await send(`set battery → ${battValue.toFixed(1)}V`, "battery", { value: battValue });
    } else {
      await send("clear battery override", "battery", { value: null });
    }
  };

  const handleBattSlider = async (v) => {
    setBattValue(v);
    if (battEnabled) {
      await send(`set battery → ${v.toFixed(1)}V`, "battery", { value: v });
    }
  };

  const handleScenario = async (id, currentlyActive) => {
    const next = new Set(activeScenarios);
    if (currentlyActive) {
      next.delete(id);
      await send(`clear scenario: ${id}`, "scenario", { scenario: id, active: false });
    } else {
      next.add(id);
      await send(`add scenario: ${id}`, "scenario", { scenario: id, active: true });
    }
    setActiveScenarios(next);
  };

  const handleReset = async () => {
    await send("reset all overrides", "reset", {});
    setDoorForced(null);
    setTempEnabled(false);
    setBattEnabled(false);
    setActiveScenarios(new Set());
    addLog(`[${selectedId}] ↺ reset`);
  };

  // ── Render ───────────────────────────────────────────────────────────────

  return (
    /* Backdrop */
    <div
      className="fixed inset-0 z-50 flex justify-end"
      onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}
    >
      {/* Dim overlay */}
      <div className="absolute inset-0 bg-slate-950/60 backdrop-blur-sm" onClick={onClose} />

      {/* Panel */}
      <aside className="relative w-full max-w-sm bg-slate-900 border-l border-slate-700/60
                        flex flex-col h-full overflow-hidden shadow-2xl z-10">

        {/* ── Header ── */}
        <div className="flex items-center justify-between px-5 py-4
                        border-b border-slate-700/60 shrink-0">
          <div className="flex items-center gap-2.5">
            <div className="bg-blue-600/20 p-1.5 rounded-lg">
              <Terminal className="w-4 h-4 text-blue-400" />
            </div>
            <div>
              <p className="font-bold text-white text-sm leading-none">Command Center</p>
              <p className="text-slate-500 text-xs mt-0.5">Simulator runtime control</p>
            </div>
          </div>
          <button onClick={onClose}
                  className="text-slate-500 hover:text-white transition-colors p-1 -mr-1">
            <X className="w-5 h-5" />
          </button>
        </div>

        {/* ── Scrollable body ── */}
        <div className="flex-1 overflow-y-auto">

          {/* Device selector */}
          <div className="px-5 pt-4 pb-3 border-b border-slate-800">
            <label className="text-xs text-slate-500 uppercase tracking-widest font-semibold mb-2 block">
              Target Device
            </label>
            <div className="relative">
              <select
                value={selectedId}
                onChange={e => setSelectedId(e.target.value)}
                className="w-full bg-slate-800 border border-slate-700 rounded-lg px-3 py-2
                           text-white text-sm appearance-none pr-8 focus:outline-none
                           focus:border-blue-500 cursor-pointer"
              >
                {deviceIds.length === 0 && (
                  <option value="">— no devices yet —</option>
                )}
                {deviceIds.map(id => (
                  <option key={id} value={id}>{id}</option>
                ))}
              </select>
              <ChevronDown className="absolute right-2.5 top-2.5 w-4 h-4 text-slate-400 pointer-events-none" />
            </div>
          </div>

          {selectedId && (
            <>
              {/* ── Door control ── */}
              <section className="px-5 py-4 border-b border-slate-800">
                <p className="text-xs text-slate-500 uppercase tracking-widest font-semibold mb-3">
                  Door
                </p>
                <div className="flex gap-2">
                  <button
                    onClick={() => handleDoor(true)}
                    className={`flex-1 flex items-center justify-center gap-2 py-2.5 rounded-lg
                                border text-sm font-medium transition-all
                                ${doorForced === true
                                  ? "bg-amber-500/20 border-amber-500 text-amber-200"
                                  : "border-slate-700 hover:bg-amber-500/10 hover:border-amber-500/50 text-slate-300"
                                }`}
                  >
                    <DoorOpen className="w-4 h-4" />
                    Force Open
                  </button>
                  <button
                    onClick={() => handleDoor(false)}
                    className={`flex-1 flex items-center justify-center gap-2 py-2.5 rounded-lg
                                border text-sm font-medium transition-all
                                ${doorForced === false
                                  ? "bg-emerald-500/20 border-emerald-500 text-emerald-200"
                                  : "border-slate-700 hover:bg-emerald-500/10 hover:border-emerald-500/50 text-slate-300"
                                }`}
                  >
                    <DoorClosed className="w-4 h-4" />
                    Force Close
                  </button>
                </div>
                {doorForced !== null && (
                  <p className="text-xs text-slate-500 mt-2">
                    Override active — door is forced {doorForced ? "OPEN" : "CLOSED"}.
                    {" "}
                    <button onClick={() => { send("clear door override","door",{open:false}); setDoorForced(null); }}
                            className="text-slate-400 underline hover:text-white">
                      Release
                    </button>
                  </p>
                )}
              </section>

              {/* ── Temperature override ── */}
              <section className="px-5 py-4 border-b border-slate-800">
                <div className="flex items-center justify-between mb-3">
                  <p className="text-xs text-slate-500 uppercase tracking-widest font-semibold flex items-center gap-1.5">
                    <Thermometer className="w-3.5 h-3.5" /> Temperature Override
                  </p>
                  <label className="flex items-center gap-1.5 cursor-pointer">
                    <input
                      type="checkbox"
                      checked={tempEnabled}
                      onChange={e => handleTempToggle(e.target.checked)}
                      className="accent-blue-500"
                    />
                    <span className="text-xs text-slate-400">{tempEnabled ? "Active" : "Off"}</span>
                  </label>
                </div>
                <div className={`space-y-2 transition-opacity ${tempEnabled ? "opacity-100" : "opacity-40 pointer-events-none"}`}>
                  <div className="flex justify-between text-xs text-slate-400">
                    <span>−30°C</span>
                    <span className={`font-bold tabular-nums ${tempValue > -10 ? "text-red-400" : tempValue > -15 ? "text-amber-400" : "text-emerald-400"}`}>
                      {tempValue > 0 ? "+" : ""}{tempValue.toFixed(1)}°C
                    </span>
                    <span>+5°C</span>
                  </div>
                  <input
                    type="range" min="-30" max="5" step="0.5"
                    value={tempValue}
                    onChange={e => handleTempSlider(parseFloat(e.target.value))}
                    className="w-full accent-blue-500"
                  />
                  <p className="text-xs text-slate-600">
                    Drag to set an exact temperature reading on the sensor.
                  </p>
                </div>
              </section>

              {/* ── Battery override ── */}
              <section className="px-5 py-4 border-b border-slate-800">
                <div className="flex items-center justify-between mb-3">
                  <p className="text-xs text-slate-500 uppercase tracking-widest font-semibold flex items-center gap-1.5">
                    <BatteryMedium className="w-3.5 h-3.5" /> Battery Override
                  </p>
                  <label className="flex items-center gap-1.5 cursor-pointer">
                    <input
                      type="checkbox"
                      checked={battEnabled}
                      onChange={e => handleBattToggle(e.target.checked)}
                      className="accent-blue-500"
                    />
                    <span className="text-xs text-slate-400">{battEnabled ? "Active" : "Off"}</span>
                  </label>
                </div>
                <div className={`space-y-2 transition-opacity ${battEnabled ? "opacity-100" : "opacity-40 pointer-events-none"}`}>
                  <div className="flex justify-between text-xs text-slate-400">
                    <span>10.5V (dead)</span>
                    <span className={`font-bold tabular-nums ${battValue < 11.0 ? "text-red-400" : battValue < 11.5 ? "text-amber-400" : "text-emerald-400"}`}>
                      {battValue.toFixed(2)} V
                    </span>
                    <span>12.6V (full)</span>
                  </div>
                  <input
                    type="range" min="10.5" max="12.6" step="0.05"
                    value={battValue}
                    onChange={e => handleBattSlider(parseFloat(e.target.value))}
                    className="w-full accent-blue-500"
                  />
                  <p className="text-xs text-slate-600">
                    Set below 11.2V to trigger a battery-low event.
                  </p>
                </div>
              </section>

              {/* ── Scenario injection ── */}
              <section className="px-5 py-4 border-b border-slate-800">
                <p className="text-xs text-slate-500 uppercase tracking-widest font-semibold mb-3 flex items-center gap-1.5">
                  <Zap className="w-3.5 h-3.5" /> Inject Scenario
                </p>
                <div className="grid grid-cols-2 gap-2">
                  {SCENARIOS.map(sc => {
                    const active = activeScenarios.has(sc.id);
                    return (
                      <button
                        key={sc.id}
                        onClick={() => handleScenario(sc.id, active)}
                        title={sc.desc}
                        className={`flex flex-col items-start p-2.5 rounded-lg border text-left
                                    transition-all text-xs font-medium
                                    ${active ? sc.activeColor : sc.color}`}
                      >
                        <span className="text-base leading-none mb-1">{sc.icon}</span>
                        <span>{sc.label}</span>
                        {active && (
                          <span className="text-[10px] opacity-70 mt-0.5">● active — click to stop</span>
                        )}
                      </button>
                    );
                  })}
                </div>
                <p className="text-xs text-slate-600 mt-2">
                  Click a scenario to inject it. Click again to remove it.
                  Results appear in the event feed within ~5–10 seconds.
                </p>
              </section>

              {/* ── Reset ── */}
              <section className="px-5 py-4 border-b border-slate-800">
                <button
                  onClick={handleReset}
                  className="w-full flex items-center justify-center gap-2 py-2.5 rounded-lg
                             border border-slate-700 hover:bg-slate-800 text-slate-400
                             hover:text-white text-sm font-medium transition-all"
                >
                  <RotateCcw className="w-4 h-4" />
                  Reset All Overrides
                </button>
                <p className="text-xs text-slate-700 mt-1.5 text-center">
                  Returns {selectedId} to pure physics simulation
                </p>
              </section>
            </>
          )}

          {/* ── Command Log ── */}
          <section className="px-5 pt-4 pb-6">
            <p className="text-xs text-slate-500 uppercase tracking-widest font-semibold mb-2 flex items-center gap-1.5">
              <Terminal className="w-3.5 h-3.5" /> Command Log
            </p>
            {log.length === 0 ? (
              <p className="text-xs text-slate-700 italic">
                No commands sent yet. Select a device and use the controls above.
              </p>
            ) : (
              <div className="space-y-0">
                {log.map((entry, i) => (
                  <LogEntry key={i} entry={entry} />
                ))}
              </div>
            )}
          </section>

        </div>
      </aside>
    </div>
  );
}

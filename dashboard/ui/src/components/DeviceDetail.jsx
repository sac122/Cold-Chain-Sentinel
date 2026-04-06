import { X, Thermometer, Droplets, BatteryMedium, DoorOpen,
         DoorClosed, MapPin, Activity, Clock } from "lucide-react";
import TempChart from "./TempChart.jsx";
import {
  formatTemp, tempColor, statusDotClass, statusLabel,
  eventTypeLabel, severityClass, relativeTime, fmtTime,
  batteryColor, batteryPct,
} from "../utils/helpers.js";

function Row({ label, value, cls = "text-white" }) {
  return (
    <div className="flex justify-between items-center py-2 border-b border-slate-700/40 last:border-0">
      <span className="text-slate-400 text-sm">{label}</span>
      <span className={`text-sm font-medium ${cls}`}>{value ?? "—"}</span>
    </div>
  );
}

function BatteryBar({ v }) {
  const pct = batteryPct(v);
  return (
    <div className="flex items-center gap-2">
      <div className="flex-1 bg-slate-700 rounded-full h-1.5">
        <div
          className={`h-1.5 rounded-full transition-all ${
            pct > 50 ? "bg-emerald-400" : pct > 20 ? "bg-amber-400" : "bg-red-400"
          }`}
          style={{ width: `${pct}%` }}
        />
      </div>
      <span className={`text-sm font-medium ${batteryColor(v)}`}>
        {v != null ? `${v.toFixed(1)} V` : "—"}
      </span>
    </div>
  );
}

export default function DeviceDetail({ device, onClose }) {
  if (!device) return null;
  const tel    = device.telemetry ?? {};
  const status = device.status ?? "unknown";

  return (
    /* Backdrop */
    <div
      className="fixed inset-0 z-50 bg-slate-950/70 backdrop-blur-sm flex items-end sm:items-center
                 justify-center p-0 sm:p-4"
      onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}
    >
      {/* Panel */}
      <div className="card w-full sm:max-w-lg max-h-[90vh] flex flex-col overflow-hidden
                      sm:rounded-2xl rounded-t-2xl">

        {/* Header */}
        <div className="flex items-center justify-between p-5 border-b border-slate-700/60">
          <div className="flex items-center gap-3">
            <span className={`w-3 h-3 rounded-full ${statusDotClass(status)}`} />
            <div>
              <h2 className="font-bold text-white text-lg leading-none">{device.device_id}</h2>
              <p className="text-slate-500 text-xs mt-0.5">
                Last seen {relativeTime(device.last_seen)}
              </p>
            </div>
          </div>
          <div className="flex items-center gap-3">
            <span className={`badge badge-${status}`}>{statusLabel(status)}</span>
            <button onClick={onClose}
                    className="text-slate-500 hover:text-white transition-colors p-1 -mr-1">
              <X className="w-5 h-5" />
            </button>
          </div>
        </div>

        <div className="overflow-y-auto flex-1">

          {/* Temperature big + chart */}
          <div className="p-5 border-b border-slate-700/60">
            <div className="flex items-baseline gap-2 mb-3">
              <Thermometer className={`w-6 h-6 ${tempColor(tel.temp_c)}`} />
              <span className={`text-4xl font-bold tabular-nums ${tempColor(tel.temp_c)}`}>
                {tel.temp_c != null ? tel.temp_c.toFixed(2) : "—"}
              </span>
              <span className="text-slate-400 text-xl">°C</span>
              {tel.ewma_temp != null && (
                <span className="text-slate-500 text-sm ml-auto">
                  EWMA {tel.ewma_temp.toFixed(2)}°C
                </span>
              )}
            </div>
            <div className="h-32">
              <TempChart history={device.temp_history} />
            </div>
            {tel.anomaly_score != null && (
              <p className="text-xs text-slate-500 mt-1 text-right">
                z-score: <span className={
                  Math.abs(tel.anomaly_score) > 3 ? "text-amber-400" : "text-slate-400"
                }>{tel.anomaly_score.toFixed(3)}</span>
              </p>
            )}
          </div>

          {/* Telemetry stats */}
          <div className="p-5 border-b border-slate-700/60">
            <p className="text-xs text-slate-500 uppercase tracking-widest font-semibold mb-3">
              Telemetry
            </p>

            <div className="mb-3">
              <p className="text-slate-400 text-sm mb-1.5">Battery</p>
              <BatteryBar v={tel.battery_v} />
            </div>

            <Row label="Humidity"
                 value={tel.humidity != null ? `${tel.humidity.toFixed(1)} %` : null}
                 cls="text-sky-400" />
            <Row label="Door"
                 value={tel.door_open ? "OPEN ⚠" : "Closed"}
                 cls={tel.door_open ? "text-amber-400" : "text-emerald-400"} />
            <Row label="Vibration"
                 value={tel.vibration != null ? `${tel.vibration.toFixed(3)} m/s²` : null} />
            <Row label="GPS"
                 value={tel.gps ? `${tel.gps.lat.toFixed(5)}, ${tel.gps.lon.toFixed(5)}` : null}
                 cls="text-slate-400" />
            <Row label="Sequence #"
                 value={tel.seq != null ? `#${tel.seq}` : null}
                 cls="text-slate-500" />
          </div>

          {/* Last event */}
          {device.last_event && (
            <div className="p-5">
              <p className="text-xs text-slate-500 uppercase tracking-widest font-semibold mb-3">
                Latest Event
              </p>
              <div className="bg-slate-800/60 rounded-lg p-3 space-y-2">
                <div className="flex items-center gap-2">
                  <span className={severityClass(device.last_event.severity)}>
                    {device.last_event.severity}
                  </span>
                  <span className="text-white text-sm font-medium">
                    {eventTypeLabel(device.last_event.event_type)}
                  </span>
                </div>
                <p className="text-slate-300 text-sm leading-relaxed">
                  {device.last_event.reason}
                </p>
                <p className="text-slate-500 text-xs flex items-center gap-1">
                  <Clock className="w-3 h-3" />
                  {fmtTime(device.last_event.ts)} · {relativeTime(device.last_event.ts)}
                </p>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

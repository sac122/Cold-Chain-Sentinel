import {
  Thermometer, Droplets, BatteryMedium, DoorOpen, DoorClosed,
  MapPin, Zap, AlertTriangle,
} from "lucide-react";
import TempChart from "./TempChart.jsx";
import {
  formatTemp, tempColor, statusDotClass, statusRingClass,
  statusLabel, eventTypeLabel, relativeTime, batteryColor,
} from "../utils/helpers.js";

function Pill({ icon: Icon, value, cls = "text-slate-400" }) {
  return (
    <div className={`flex items-center gap-1 text-xs ${cls}`}>
      <Icon className="w-3 h-3 shrink-0" />
      <span className="tabular-nums truncate">{value}</span>
    </div>
  );
}

export default function DeviceCard({ device, onClick }) {
  const tel    = device.telemetry ?? {};
  const status = device.status ?? "unknown";
  const evt    = device.last_event;
  const isCrit = status === "critical";

  return (
    <button
      onClick={onClick}
      className={`card w-full text-left p-4 flex flex-col gap-3 cursor-pointer
                  hover:border-slate-500 hover:bg-slate-800/60 transition-all duration-150
                  ring-1 ${statusRingClass(status)}`}
    >
      {/* ── Header row ── */}
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="font-semibold text-white text-sm truncate">{device.device_id}</p>
          <p className="text-slate-500 text-xs mt-0.5">{relativeTime(device.last_seen)}</p>
        </div>
        <span className={`badge badge-${status} shrink-0`}>
          <span className={`w-1.5 h-1.5 rounded-full ${statusDotClass(status)}`} />
          {statusLabel(status)}
        </span>
      </div>

      {/* ── Temperature (big) ── */}
      <div className="flex items-end gap-3">
        <div className="flex items-center gap-1.5">
          <Thermometer className={`w-5 h-5 ${tempColor(tel.temp_c)}`} />
          <span className={`text-3xl font-bold tabular-nums ${tempColor(tel.temp_c)}`}>
            {tel.temp_c != null ? tel.temp_c.toFixed(1) : "—"}
            <span className="text-base font-normal ml-0.5">°C</span>
          </span>
        </div>
        {tel.anomaly_score != null && Math.abs(tel.anomaly_score) > 2 && (
          <span className="text-xs text-amber-400 ml-auto">
            z={tel.anomaly_score.toFixed(1)}
          </span>
        )}
      </div>

      {/* ── Mini chart ── */}
      <div className="h-16 -mx-1">
        <TempChart history={device.temp_history} compact />
      </div>

      {/* ── Stats grid ── */}
      <div className="grid grid-cols-2 gap-x-3 gap-y-1.5 text-xs">
        <Pill icon={Droplets}
              value={tel.humidity != null ? `${tel.humidity.toFixed(0)}% RH` : "—"}
              cls="text-sky-400" />
        <Pill icon={tel.door_open ? DoorOpen : DoorClosed}
              value={tel.door_open ? "Door OPEN" : "Door Closed"}
              cls={tel.door_open ? "text-amber-400" : "text-slate-400"} />
        <Pill icon={BatteryMedium}
              value={tel.battery_v != null ? `${tel.battery_v.toFixed(1)} V` : "—"}
              cls={batteryColor(tel.battery_v)} />
        <Pill icon={MapPin}
              value={tel.gps ? `${tel.gps.lat.toFixed(3)}, ${tel.gps.lon.toFixed(3)}` : "—"}
              cls="text-slate-500" />
      </div>

      {/* ── Last event ── */}
      {evt && (
        <div className={`flex items-start gap-2 pt-2 border-t border-slate-700/50
                         ${isCrit ? "border-red-500/30" : ""}`}>
          <AlertTriangle className={`w-3.5 h-3.5 mt-0.5 shrink-0
                                     ${isCrit ? "text-red-400" : "text-amber-400"}`} />
          <div className="min-w-0">
            <p className={`text-xs font-medium truncate
                           ${isCrit ? "text-red-300" : "text-amber-300"}`}>
              {eventTypeLabel(evt.event_type)}
            </p>
            <p className="text-slate-500 text-xs truncate">{relativeTime(evt.ts)}</p>
          </div>
        </div>
      )}
    </button>
  );
}

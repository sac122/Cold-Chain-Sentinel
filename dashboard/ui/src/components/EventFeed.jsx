import { useState } from "react";
import { Bell, Filter } from "lucide-react";
import {
  severityClass, severityBorder, eventTypeLabel, relativeTime, fmtTime,
} from "../utils/helpers.js";

function EventRow({ evt }) {
  const [expanded, setExpanded] = useState(false);
  const tel = evt.telemetry ?? {};

  return (
    <button
      onClick={() => setExpanded(x => !x)}
      className={`w-full text-left p-3 border-l-2 ${severityBorder(evt.severity)}
                  hover:bg-slate-800/60 transition-colors duration-100 rounded-r-lg`}
    >
      <div className="flex items-start gap-2">
        <span className={severityClass(evt.severity)}>
          {evt.severity}
        </span>
        <div className="min-w-0 flex-1">
          <p className="text-white text-xs font-medium truncate">
            {eventTypeLabel(evt.event_type)}
          </p>
          <p className="text-slate-400 text-xs truncate">{evt.device_id}</p>
        </div>
        <span className="text-slate-600 text-xs shrink-0">{relativeTime(evt.ts)}</span>
      </div>

      {expanded && (
        <div className="mt-2 pt-2 border-t border-slate-700/40 text-xs text-slate-400 space-y-1">
          <p className="text-slate-300 leading-relaxed">{evt.reason}</p>
          <div className="grid grid-cols-2 gap-x-4 gap-y-0.5 mt-1">
            {tel.temp_c   != null && <span>Temp: {tel.temp_c?.toFixed(2)}°C</span>}
            {tel.humidity != null && <span>Hum:  {tel.humidity?.toFixed(0)}%</span>}
            {tel.battery_v != null&& <span>Bat:  {tel.battery_v?.toFixed(2)}V</span>}
            {evt.anomaly_score != null &&
              <span>z-score: {evt.anomaly_score?.toFixed(2)}</span>}
            {evt.duration_seconds != null &&
              <span className="col-span-2">Duration: {evt.duration_seconds?.toFixed(0)}s</span>}
          </div>
          <p className="text-slate-600">{fmtTime(evt.ts)}</p>
        </div>
      )}
    </button>
  );
}

export default function EventFeed({ events }) {
  const [filter, setFilter] = useState("ALL");
  const levels = ["ALL", "CRITICAL", "WARNING", "INFO"];

  const filtered = filter === "ALL"
    ? events
    : events.filter(e => e.severity === filter);

  return (
    <div className="card flex flex-col h-full overflow-hidden">
      {/* Header */}
      <div className="flex items-center justify-between p-4 border-b border-slate-700/60 shrink-0">
        <div className="flex items-center gap-2">
          <Bell className="w-4 h-4 text-slate-400" />
          <span className="text-sm font-semibold text-white">Event Feed</span>
          {events.length > 0 && (
            <span className="bg-slate-700 text-slate-300 text-xs px-1.5 py-0.5 rounded-full">
              {events.length}
            </span>
          )}
        </div>
        <div className="flex items-center gap-1">
          <Filter className="w-3.5 h-3.5 text-slate-500" />
          {levels.map(l => (
            <button
              key={l}
              onClick={() => setFilter(l)}
              className={`text-xs px-2 py-0.5 rounded-full transition-colors
                          ${filter === l
                            ? "bg-blue-600 text-white"
                            : "text-slate-500 hover:text-slate-300"}`}
            >
              {l}
            </button>
          ))}
        </div>
      </div>

      {/* List */}
      <div className="flex-1 overflow-y-auto p-2 space-y-1">
        {filtered.length === 0 ? (
          <div className="flex flex-col items-center justify-center py-12 text-slate-600 gap-2">
            <Bell className="w-8 h-8" />
            <p className="text-sm">No events yet</p>
          </div>
        ) : (
          filtered.map((evt, i) => (
            <EventRow key={evt.event_id ?? i} evt={evt} />
          ))
        )}
      </div>
    </div>
  );
}

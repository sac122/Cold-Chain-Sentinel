import { Thermometer, AlertTriangle, DoorOpen, BatteryLow } from "lucide-react";
import { formatTemp } from "../utils/helpers.js";

function StatCard({ icon: Icon, label, value, sub, accent }) {
  const colors = {
    blue:   "text-blue-400   bg-blue-500/10   border-blue-500/20",
    emerald:"text-emerald-400 bg-emerald-500/10 border-emerald-500/20",
    amber:  "text-amber-400  bg-amber-500/10  border-amber-500/20",
    red:    "text-red-400    bg-red-500/10    border-red-500/20",
  };
  const cls = colors[accent] ?? colors.blue;

  return (
    <div className={`card p-4 flex items-start gap-3 ring-1 ${cls.split(" ").slice(2).join(" ")}`}>
      <div className={`p-2 rounded-lg ${cls.split(" ").slice(1,2).join(" ")}`}>
        <Icon className={`w-5 h-5 ${cls.split(" ")[0]}`} />
      </div>
      <div className="min-w-0">
        <p className="text-slate-400 text-xs mb-0.5 truncate">{label}</p>
        <p className={`stat-value ${cls.split(" ")[0]}`}>{value ?? "—"}</p>
        {sub && <p className="text-slate-500 text-xs mt-0.5">{sub}</p>}
      </div>
    </div>
  );
}

export default function StatsBar({ stats }) {
  const alertCount  = stats?.active_alerts ?? 0;
  const critCount   = stats?.critical_count ?? 0;
  const warnCount   = stats?.warning_count ?? 0;

  return (
    <div className="grid grid-cols-2 lg:grid-cols-4 gap-3">
      <StatCard
        icon={Thermometer}
        label="Fleet Avg Temperature"
        value={formatTemp(stats?.avg_temp_c)}
        sub={`min ${formatTemp(stats?.min_temp_c)} · max ${formatTemp(stats?.max_temp_c)}`}
        accent="blue"
      />
      <StatCard
        icon={AlertTriangle}
        label="Active Alerts"
        value={alertCount}
        sub={`${critCount} critical · ${warnCount} warning`}
        accent={critCount > 0 ? "red" : warnCount > 0 ? "amber" : "emerald"}
      />
      <StatCard
        icon={DoorOpen}
        label="Doors Open"
        value={stats?.open_doors ?? 0}
        sub={`${stats?.online_devices ?? 0} / ${stats?.total_devices ?? 0} devices online`}
        accent={(stats?.open_doors ?? 0) > 0 ? "amber" : "emerald"}
      />
      <StatCard
        icon={BatteryLow}
        label="Low Battery"
        value={stats?.low_battery ?? 0}
        sub="below 11.5 V"
        accent={(stats?.low_battery ?? 0) > 0 ? "amber" : "emerald"}
      />
    </div>
  );
}

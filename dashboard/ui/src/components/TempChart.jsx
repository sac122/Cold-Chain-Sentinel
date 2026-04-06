import {
  ResponsiveContainer, AreaChart, Area,
  ReferenceLine, Tooltip, YAxis,
} from "recharts";
import { chartLineColor } from "../utils/helpers.js";

const CustomTooltip = ({ active, payload }) => {
  if (!active || !payload?.length) return null;
  const d = payload[0].payload;
  return (
    <div className="bg-slate-800 border border-slate-600 rounded px-2 py-1 text-xs text-slate-200">
      <div>{d.temp != null ? `${d.temp.toFixed(2)}°C` : "—"}</div>
      {d.ewma != null && <div className="text-slate-400">EWMA {d.ewma.toFixed(2)}°C</div>}
    </div>
  );
};

export default function TempChart({ history, compact = false }) {
  if (!history || history.length < 2) {
    return (
      <div className="flex items-center justify-center h-full text-slate-600 text-xs">
        Collecting data…
      </div>
    );
  }

  const data = history.map(([ts, temp, ewma]) => ({ ts, temp, ewma }));
  const lastTemp  = data[data.length - 1]?.temp;
  const lineColor = chartLineColor(lastTemp);

  // Reference line at the warning threshold
  const domainPad = 1.5;
  const temps = data.map(d => d.temp).filter(Boolean);
  const yMin = Math.min(...temps) - domainPad;
  const yMax = Math.max(...temps) + domainPad;

  return (
    <ResponsiveContainer width="100%" height="100%">
      <AreaChart data={data} margin={{ top: 4, right: 0, bottom: 0, left: 0 }}>
        <defs>
          <linearGradient id={`tg-${lineColor.replace("#","")}`} x1="0" y1="0" x2="0" y2="1">
            <stop offset="5%"  stopColor={lineColor} stopOpacity={0.3} />
            <stop offset="95%" stopColor={lineColor} stopOpacity={0.02} />
          </linearGradient>
        </defs>
        <YAxis domain={[yMin, yMax]} hide />
        <ReferenceLine y={-15} stroke="#f59e0b" strokeDasharray="3 3" strokeWidth={1} />
        <Tooltip content={<CustomTooltip />} />
        <Area
          type="monotone"
          dataKey="temp"
          stroke={lineColor}
          strokeWidth={compact ? 1.5 : 2}
          dot={false}
          fill={`url(#tg-${lineColor.replace("#","")})`}
          isAnimationActive={false}
        />
        {!compact && (
          <Area
            type="monotone"
            dataKey="ewma"
            stroke="#94a3b8"
            strokeWidth={1}
            strokeDasharray="4 2"
            dot={false}
            fill="none"
            isAnimationActive={false}
          />
        )}
      </AreaChart>
    </ResponsiveContainer>
  );
}

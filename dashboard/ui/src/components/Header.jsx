import { Snowflake, Wifi, WifiOff, Activity } from "lucide-react";

export default function Header({ connected, stats }) {
  const alertCount = stats?.active_alerts ?? 0;

  return (
    <header className="sticky top-0 z-50 bg-slate-950/90 backdrop-blur border-b border-slate-800">
      <div className="max-w-screen-2xl mx-auto px-4 sm:px-6 h-14 flex items-center justify-between">

        {/* Logo */}
        <div className="flex items-center gap-2.5">
          <div className="bg-blue-600/20 p-1.5 rounded-lg">
            <Snowflake className="w-5 h-5 text-blue-400" />
          </div>
          <div>
            <span className="font-bold text-white tracking-tight">Cold-Chain Sentinel</span>
            <span className="hidden sm:inline text-slate-500 text-xs ml-2">Fleet Monitoring</span>
          </div>
        </div>

        {/* Right-side status */}
        <div className="flex items-center gap-4">

          {/* Alert badge */}
          {alertCount > 0 && (
            <div className="flex items-center gap-1.5 bg-red-500/15 border border-red-500/30
                            px-2.5 py-1 rounded-full">
              <Activity className="w-3.5 h-3.5 text-red-400 flicker" />
              <span className="text-red-400 text-xs font-semibold">
                {alertCount} alert{alertCount > 1 ? "s" : ""}
              </span>
            </div>
          )}

          {/* Device count */}
          <span className="hidden sm:inline text-slate-400 text-sm">
            {stats?.total_devices ?? 0} devices
          </span>

          {/* Connection dot */}
          <div className={`flex items-center gap-1.5 text-xs font-medium
                           ${connected ? "text-emerald-400" : "text-slate-500"}`}>
            {connected
              ? <><Wifi className="w-4 h-4" /><span className="hidden sm:inline">Live</span></>
              : <><WifiOff className="w-4 h-4" /><span className="hidden sm:inline">Reconnecting…</span></>
            }
            <span className={`w-2 h-2 rounded-full
                              ${connected ? "bg-emerald-400 animate-pulse" : "bg-slate-600"}`} />
          </div>
        </div>

      </div>
    </header>
  );
}

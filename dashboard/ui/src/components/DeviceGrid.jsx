import DeviceCard from "./DeviceCard.jsx";
import { Package } from "lucide-react";

export default function DeviceGrid({ devices, onSelect }) {
  const sorted = Object.values(devices).sort((a, b) => {
    // Sort: critical first, then warning, then normal, then offline
    const order = { critical: 0, warning: 1, normal: 2, offline: 3, unknown: 4 };
    return (order[a.status] ?? 5) - (order[b.status] ?? 5);
  });

  if (sorted.length === 0) {
    return (
      <div className="flex flex-col items-center justify-center py-20 text-slate-600 gap-3">
        <Package className="w-12 h-12" />
        <p className="text-sm">Waiting for devices to publish telemetry…</p>
        <p className="text-xs text-slate-700">Make sure the simulator is running</p>
      </div>
    );
  }

  return (
    <div className="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-3 2xl:grid-cols-4 gap-3">
      {sorted.map(device => (
        <DeviceCard
          key={device.device_id}
          device={device}
          onClick={() => onSelect(device)}
        />
      ))}
    </div>
  );
}

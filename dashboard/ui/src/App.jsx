import { useState, useCallback, useRef } from "react";
import Header       from "./components/Header.jsx";
import StatsBar     from "./components/StatsBar.jsx";
import DeviceGrid   from "./components/DeviceGrid.jsx";
import EventFeed    from "./components/EventFeed.jsx";
import DeviceDetail from "./components/DeviceDetail.jsx";
import CommandCenter from "./components/CommandCenter.jsx";
import { useWebSocket } from "./hooks/useWebSocket.js";

const MAX_EVENTS = 200;

export default function App() {
  const [connected,      setConnected]      = useState(false);
  const [devices,        setDevices]        = useState({});
  const [events,         setEvents]         = useState([]);
  const [stats,          setStats]          = useState({});
  const [selectedDevice, setSelectedDevice] = useState(null);
  const [showControl,    setShowControl]    = useState(false);

  // When the user has a device detail open we want to keep it updated live
  const selectedIdRef = useRef(null);
  selectedIdRef.current = selectedDevice?.device_id ?? null;

  const onMessage = useCallback((msg) => {
    switch (msg.type) {

      case "init":
        setDevices(msg.devices ?? {});
        setEvents(msg.events   ?? []);
        setStats(msg.stats     ?? {});
        break;

      case "telemetry": {
        const { device_id, data, history, status } = msg;
        setDevices(prev => ({
          ...prev,
          [device_id]: {
            ...(prev[device_id] ?? { device_id }),
            telemetry:    data,
            temp_history: history,
            last_seen:    data?.ts,
            status,
          },
        }));
        // Keep detail modal in sync
        if (selectedIdRef.current === device_id) {
          setSelectedDevice(prev =>
            prev ? { ...prev, telemetry: data, temp_history: history, status } : prev
          );
        }
        break;
      }

      case "event": {
        const evt = msg.data;
        setEvents(prev => [evt, ...prev].slice(0, MAX_EVENTS));
        // Update device's last_event + status
        if (evt.device_id) {
          setDevices(prev => {
            const old = prev[evt.device_id];
            if (!old) return prev;
            return {
              ...prev,
              [evt.device_id]: { ...old, last_event: evt },
            };
          });
          if (selectedIdRef.current === evt.device_id) {
            setSelectedDevice(prev => prev ? { ...prev, last_event: evt } : prev);
          }
        }
        break;
      }

      case "stats":
        setStats(msg.data ?? {});
        break;

      default:
        break;
    }
  }, []);

  useWebSocket(
    onMessage,
    () => setConnected(true),
    () => setConnected(false),
  );

  return (
    <div className="min-h-screen bg-slate-950">
      <Header
        connected={connected}
        stats={stats}
        onToggleControl={() => setShowControl(x => !x)}
        controlOpen={showControl}
      />

      <main className="max-w-screen-2xl mx-auto px-4 sm:px-6 py-5 space-y-5">
        {/* Stats row */}
        <StatsBar stats={stats} />

        {/* Device grid + event feed */}
        <div className="grid grid-cols-1 lg:grid-cols-[1fr_340px] gap-5">
          {/* Left: device grid */}
          <section>
            <div className="flex items-center justify-between mb-3">
              <h2 className="text-sm font-semibold text-slate-300 uppercase tracking-widest">
                Fleet ({Object.keys(devices).length})
              </h2>
              <p className="text-slate-600 text-xs">Click a pallet to inspect</p>
            </div>
            <DeviceGrid
              devices={devices}
              onSelect={(d) => setSelectedDevice(d)}
            />
          </section>

          {/* Right: event feed */}
          <section className="lg:sticky lg:top-[4.5rem] lg:max-h-[calc(100vh-5.5rem)]">
            <EventFeed events={events} />
          </section>
        </div>
      </main>

      {/* Device detail modal */}
      {selectedDevice && (
        <DeviceDetail
          device={selectedDevice}
          onClose={() => setSelectedDevice(null)}
        />
      )}

      {/* Simulator Command Center slide-over */}
      {showControl && (
        <CommandCenter
          devices={devices}
          onClose={() => setShowControl(false)}
        />
      )}
    </div>
  );
}

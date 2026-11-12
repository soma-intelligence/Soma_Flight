import { Clock, Plane, WifiOff } from "lucide-react";
import { useEffect, useState } from "react";
import type { Flight } from "@/data/types";
import { clock, destinationCode, originCode } from "@/ui/format";
import { estimate, estimateDetail } from "./facts";

/** The browser's connection, kept current. */
function useOnline(): boolean {
  const [online, setOnline] = useState(() => (typeof navigator === "undefined" ? true : navigator.onLine));
  useEffect(() => {
    const up = () => setOnline(true);
    const down = () => setOnline(false);
    window.addEventListener("online", up);
    window.addEventListener("offline", down);
    return () => {
      window.removeEventListener("online", up);
      window.removeEventListener("offline", down);
    };
  }, []);
  return online;
}

/**
 * The estimate (EstimatedProgressCard): while the app cannot hear about a flight in the air (offline, or
 * no live update for five minutes), a badge with the last update, a dashed bar at the estimated share of
 * the trip and what it rests on. Nothing when the flight is live.
 */
export function Progress({ flight, now }: { flight: Flight; now: Date }) {
  const online = useOnline();
  const e = estimate(flight, now, online);
  if (!e) return null;
  const from = originCode(flight);
  const to = destinationCode(flight);
  const pct = Math.round(e.progress * 100);
  const last = `Last update ${clock(e.lastUpdate, null)}`;
  const Icon = e.reason === "offline" ? WifiOff : Clock;
  return (
    <div
      role="group"
      aria-label={`Estimated, ${last.toLowerCase()}. About ${pct} percent of the way from ${from} to ${to}. ${estimateDetail(e)}`}
      className="flex flex-col gap-2.5 rounded-[18px] border p-[14px]"
      style={{
        background: "color-mix(in srgb, var(--sf-late) 10%, transparent)",
        borderColor: "color-mix(in srgb, var(--sf-late) 25%, transparent)",
      }}
    >
      <div className="flex items-center gap-2" aria-hidden>
        <span
          className="flex items-center gap-[5px] rounded-full px-2 py-[3px] text-[13px] font-semibold text-[var(--sf-late)]"
          style={{ background: "color-mix(in srgb, var(--sf-late) 16%, transparent)" }}
        >
          <Icon size={12} strokeWidth={2.6} />
          {e.reason === "offline" ? "Estimated, offline" : "Estimated, no live update"}
        </span>
        <span className="ml-auto text-[13px] text-[var(--sf-secondary)] tabular-nums">{last}</span>
      </div>
      <div className="flex items-center gap-2.5" aria-hidden>
        <span className="text-[13px] font-semibold text-[var(--sf-secondary)]">{from}</span>
        <div className="relative h-[18px] flex-1">
          <div className="absolute top-1/2 right-0 left-0 h-[3px] -translate-y-1/2 rounded-full bg-[var(--sf-pill)]" />
          <div
            data-testid="progress-dash"
            className="absolute top-1/2 left-0 h-[3px] -translate-y-1/2"
            style={{
              width: `${pct}%`,
              backgroundImage:
                "repeating-linear-gradient(to right, color-mix(in srgb, var(--sf-primary) 70%, transparent) 0 4px, transparent 4px 9px)",
            }}
          />
          <Plane
            size={14}
            strokeWidth={2.4}
            className="absolute top-1/2 -translate-x-1/2 -translate-y-1/2 rotate-45 text-[color-mix(in_srgb,var(--sf-primary)_70%,transparent)]"
            style={{ left: `clamp(8px, ${pct}%, calc(100% - 8px))` }}
          />
        </div>
        <span className="text-[13px] font-semibold text-[var(--sf-secondary)]">{to}</span>
      </div>
      <p className="text-[13px] text-[var(--sf-secondary)]" aria-hidden>
        {estimateDetail(e)}
      </p>
    </div>
  );
}

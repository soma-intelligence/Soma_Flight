import { Box, Tag, TowerControl } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { initCore } from "@/core/flightcore";
import { callFunction } from "@/data/api";
import { useFakes } from "@/data/flights";
import type { Flight } from "@/data/types";
import { RoundButton } from "@/ui/RoundButton";
import { useShellNav } from "../nav";
import { PANEL_INSET, PANEL_WIDTH } from "../Panel";
import { useWide } from "../useWide";
import { loadAirports } from "./airports";
import { globeContent } from "./content";
import { loadMapKit, type MapKit } from "./loadMapKit";

/** The camera's left padding when the panel stands over the globe (its width plus its inset). */
export const GLOBE_PADDING_WIDE = PANEL_WIDTH + PANEL_INSET;
const NO_FLIGHTS: Flight[] = [];

async function fetchToken(): Promise<string> {
  const a = await callFunction<{ token: string; expiresAt: string }>("mapkit-token", { method: "GET" });
  return a.token;
}

type Phase = "loading" | "ready" | "failed";

/**
 * The satellite globe across the window, behind the panel. When the token or MapKit JS is not available
 * (always so in fakes mode, where the function is not called) it stays a calm dark fill with a quiet Retry,
 * and the controls, the control tower button included, stay where they are.
 */
export function Globe({ flights = NO_FLIGHTS }: { flights?: Flight[] }) {
  const wide = useWide();
  const nav = useShellNav();
  const fakes = useFakes();
  const host = useRef<HTMLDivElement>(null);
  const [phase, setPhase] = useState<Phase>("loading");
  const [attempt, setAttempt] = useState(0);
  const [mapkit, setMapkit] = useState<MapKit | null>(null);
  const [labels, setLabels] = useState(true);
  const [tilt, setTilt] = useState(false);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const map = useRef<any>(null);

  // Loads MapKit, then builds the map in the host element.
  useEffect(() => {
    if (fakes) {
      setPhase("failed");
      return;
    }
    let cancelled = false;
    setPhase("loading");
    loadMapKit(fetchToken).then(
      (mk) => {
        if (cancelled || !host.current) return;
        const m = new mk.Map(host.current, {
          mapType: mk.Map.MapTypes.Hybrid,
          showsMapTypeControl: false,
          showsZoomControl: false,
          showsCompass: mk.FeatureVisibility?.Hidden ?? "hidden",
        });
        // The globe projection, where this MapKit JS offers it.
        const globe = mk.Map.Projections?.Globe ?? mk.MapProjection?.Globe;
        if (globe !== undefined && "projection" in m) m.projection = globe;
        map.current = m;
        setMapkit(mk);
        setPhase("ready");
      },
      () => {
        if (!cancelled) setPhase("failed");
      },
    );
    return () => {
      cancelled = true;
      map.current?.destroy?.();
      map.current = null;
      setMapkit(null);
    };
  }, [attempt, fakes]);

  // The camera frames the area beside the panel.
  useEffect(() => {
    if (!mapkit || !map.current) return;
    map.current.padding = new mapkit.Padding(0, 0, 0, wide ? GLOBE_PADDING_WIDE : 0);
  }, [mapkit, wide]);

  useEffect(() => {
    if (!mapkit || !map.current) return;
    map.current.mapType = labels ? mapkit.Map.MapTypes.Hybrid : mapkit.Map.MapTypes.Satellite;
  }, [mapkit, labels]);

  useEffect(() => {
    if (!mapkit || !map.current) return;
    map.current.isRotationEnabled = tilt;
  }, [mapkit, tilt]);

  // Routes, planes and airports for the flights.
  useEffect(() => {
    if (!mapkit || !map.current || flights.length === 0) return;
    let cancelled = false;
    const m = map.current;
    const added: { overlays: unknown[]; annotations: unknown[] } = { overlays: [], annotations: [] };
    void (async () => {
      try {
        const [lookup] = await Promise.all([loadAirports(), initCore()]);
        if (cancelled) return;
        const c = globeContent(flights, new Date(), lookup);
        const coord = (p: { lat: number; lon: number }) => new mapkit.Coordinate(p.lat, p.lon);
        for (const r of c.routes) {
          added.overlays.push(
            new mapkit.PolylineOverlay(r.map(coord), {
              style: new mapkit.Style({ lineWidth: 2, strokeColor: "#FFFFFF", strokeOpacity: 0.85 }),
            }),
          );
        }
        for (const a of c.airports) {
          added.annotations.push(
            new mapkit.Annotation(coord(a.at), () => dot(a.code), { calloutEnabled: false }),
          );
        }
        for (const p of c.planes) {
          added.annotations.push(
            new mapkit.Annotation(coord(p.at), () => plane(p.heading), { calloutEnabled: false }),
          );
        }
        m.addOverlays(added.overlays);
        m.addAnnotations(added.annotations);
      } catch {
        // the map stays as it is; the panel does not depend on it
      }
    })();
    return () => {
      cancelled = true;
      m.removeOverlays?.(added.overlays);
      m.removeAnnotations?.(added.annotations);
    };
  }, [mapkit, flights]);

  return (
    <div data-globe className="absolute inset-0" style={{ background: "#18181A" }}>
      <div ref={host} className="absolute inset-0" />
      {phase === "failed" && (
        <div className="absolute inset-0 flex items-center justify-center" style={{ paddingLeft: wide ? GLOBE_PADDING_WIDE : 0 }}>
          <button
            type="button"
            onClick={() => setAttempt((n) => n + 1)}
            className="rounded-full px-3 py-1 text-[13px] text-white/45 hover:text-white/70"
          >
            Retry
          </button>
        </div>
      )}
      <div className="absolute right-3 top-3 flex gap-2 min-[768px]:right-4 min-[768px]:top-4">
        <Switch label="3D" pressed={tilt} onClick={() => setTilt((v) => !v)} icon={Box} />
        <Switch label="Labels" pressed={labels} onClick={() => setLabels((v) => !v)} icon={Tag} />
        <RoundButton icon={TowerControl} label="Airports" onClick={() => nav.open("/airports")} />
      </div>
    </div>
  );
}

function Switch({
  label,
  pressed,
  onClick,
  icon: Icon,
}: {
  label: string;
  pressed: boolean;
  onClick: () => void;
  icon: typeof Box;
}) {
  return (
    <button
      type="button"
      aria-label={label}
      aria-pressed={pressed}
      onClick={onClick}
      className={`sf-glass flex h-11 w-11 items-center justify-center rounded-full ${
        pressed ? "text-[var(--sf-accent)]" : "text-[var(--sf-secondary)]"
      }`}
    >
      <Icon size={18} strokeWidth={2.2} aria-hidden />
    </button>
  );
}

function dot(code: string): HTMLElement {
  const el = document.createElement("div");
  el.setAttribute("aria-label", code);
  el.style.cssText = "width:8px;height:8px;border-radius:50%;background:#fff;box-shadow:0 0 0 2px rgb(0 0 0 / .35)";
  return el;
}

function plane(heading: number): HTMLElement {
  const el = document.createElement("div");
  el.style.cssText = `width:22px;height:22px;transform:rotate(${heading}deg)`;
  el.innerHTML =
    '<svg viewBox="0 0 24 24" width="22" height="22" fill="#fff"><path d="M12 2l2.2 7.5L22 14v2l-7.8-2.2L13 20l2.5 1.5V23L12 22l-3.5 1v-1.5L11 20l-1.2-6.2L2 16v-2l7.8-4.5z"/></svg>';
  return el;
}

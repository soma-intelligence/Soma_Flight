import { useEffect, useState, type ReactNode } from "react";
import { useLocation, useNavigationType, useOutlet } from "react-router";
import { motionMs, transition } from "./motion";

type Phase = "entering" | "shown" | "leaving";
type Layer = { key: string; element: ReactNode; phase: Phase };

/** Next layers for a move to `key`: a card pushed, a card returned to, or every card closed. */
function nextLayers(
  layers: Layer[],
  key: string,
  isCard: boolean,
  element: ReactNode,
  how: "POP" | "PUSH" | "REPLACE",
): Layer[] {
  if (!isCard) return layers.map((l) => (l.phase === "leaving" ? l : { ...l, phase: "leaving" }));
  const at = layers.findIndex((l) => l.key === key);
  if (how === "POP" && at >= 0) {
    return layers.map((l, i) => (i < at ? l : i === at ? { ...l, phase: "shown" } : { ...l, phase: "leaving" }));
  }
  const live = layers.filter((l) => l.phase !== "leaving");
  const top = live[live.length - 1];
  if (how === "REPLACE" && top) {
    return layers.map((l) => (l === top ? { key, element, phase: "shown" } : l));
  }
  if (how === "POP" && top) {
    // Back to a card this stack never held (opened before a reload): it shows in place under the top
    // card, which drops away over it.
    const i = layers.indexOf(top);
    return [
      ...layers.slice(0, i),
      { key, element, phase: "shown" },
      { ...top, phase: "leaving" },
      ...layers.slice(i + 1),
    ];
  }
  return [...layers, { key, element, phase: "entering" }];
}

/**
 * The tab's list with the open cards over it, after CardStack in FlightKit: a card rises from the bottom
 * and drops back down, the screen under it dims under a black overlay at 0.3. Only `transform` and
 * `opacity` animate. Cards under the top one stay mounted (inert) for the way back.
 */
export function CardStack({ root, isCard }: { root: ReactNode; isCard: boolean }) {
  const location = useLocation();
  const how = useNavigationType();
  const outlet = useOutlet();
  // A card already open when the stack mounts (a reload, the window crossing 768 px) shows at once.
  const [layers, setLayers] = useState<Layer[]>(() =>
    isCard ? [{ key: location.key, element: outlet, phase: "shown" }] : [],
  );
  const [seen, setSeen] = useState(location.key);
  if (seen !== location.key) {
    setSeen(location.key);
    setLayers(nextLayers(layers, location.key, isCard, outlet, how));
  }

  // Entering cards start below the stack and rise on the next frames.
  const entering = layers.some((l) => l.phase === "entering");
  useEffect(() => {
    if (!entering) return;
    let second = 0;
    const first = requestAnimationFrame(() => {
      second = requestAnimationFrame(() =>
        setLayers((ls) => ls.map((l) => (l.phase === "entering" ? { ...l, phase: "shown" } : l))),
      );
    });
    return () => {
      cancelAnimationFrame(first);
      cancelAnimationFrame(second);
    };
  }, [entering]);

  // Leaving cards are dropped once they are down.
  const leaving = layers.some((l) => l.phase === "leaving");
  useEffect(() => {
    if (!leaving) return;
    const t = setTimeout(() => setLayers((ls) => ls.filter((l) => l.phase !== "leaving")), motionMs() + 30);
    return () => clearTimeout(t);
  }, [leaving, layers]);

  const live = layers.filter((l) => l.phase !== "leaving");
  const top = live[live.length - 1];
  const rootCovered = live.length > 0;

  return (
    <div className="relative h-full w-full overflow-hidden">
      <Covered covered={rootCovered} z={0}>
        {root}
      </Covered>
      {layers.map((l, i) => {
        const down = l.phase !== "shown";
        const covered = l !== top && l.phase !== "leaving";
        return (
          <div
            key={l.key}
            className="absolute inset-0 bg-[var(--sf-background)]"
            style={{
              zIndex: i + 1,
              transform: down ? "translateY(100%)" : "translateY(0)",
              transition: l.phase === "entering" ? "none" : transition("transform"),
              pointerEvents: l.phase === "leaving" ? "none" : undefined,
            }}
          >
            <Covered covered={covered} z={0}>
              {l.key === location.key ? outlet : l.element}
            </Covered>
          </div>
        );
      })}
    </div>
  );
}

/** A screen under a card: kept, out of reach of taps and screen readers, dimmed. */
function Covered({ covered, z, children }: { covered: boolean; z: number; children: ReactNode }) {
  return (
    <div className="absolute inset-0" style={{ zIndex: z }} inert={covered} aria-hidden={covered || undefined}>
      {children}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0 bg-black"
        style={{ opacity: covered ? 0.3 : 0, transition: transition("opacity"), zIndex: 50 }}
      />
    </div>
  );
}

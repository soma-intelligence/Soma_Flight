import { useEffect, useRef, useState, type KeyboardEvent, type PointerEvent, type ReactNode } from "react";
import { FootContext } from "./foot";
import { MOTION_EASE, motionMs } from "./motion";
import { lowered, raised, sheetTop, snap, webGeometry, type Detent, type SheetGeometry } from "./sheetGeometry";

/** Theme.sheetRadius. */
export const SHEET_RADIUS = 38;
/** The grabber's strip at the sheet's top, and the capsule in it. */
export const GRABBER_STRIP = 22;
const DETENT_INDEX: Record<Detent, number> = { collapsed: 0, medium: 1, expanded: 2 };

function useWindowHeight(): number {
  const [h, setH] = useState(() => (typeof window === "undefined" ? 874 : window.innerHeight));
  useEffect(() => {
    const on = () => setH(window.innerHeight);
    window.addEventListener("resize", on);
    return () => window.removeEventListener("resize", on);
  }, []);
  return h;
}

/** Past either end the sheet follows at a third of the finger, like a rubber band (RegularHomeView). */
function rubberBand(top: number, g: SheetGeometry): number {
  const highest = sheetTop("expanded", g);
  const lowest = sheetTop("collapsed", g);
  if (top < highest) return highest - (highest - top) / 3;
  if (top > lowest) return lowest + (top - lowest) / 3;
  return top;
}

type Drag = { id: number; startY: number; startTop: number; moved: boolean; samples: { y: number; t: number }[] };

/**
 * The narrow window's bottom sheet, the iPhone's: three detents, a 36 x 5 grabber in a 22 px strip. A drag
 * on the strip moves the sheet and snaps it as SheetGeometry.snap does; a tap steps it up (from expanded
 * back to collapsed); the arrow keys on the focused grabber step it. Only `transform` moves the sheet.
 */
export function Sheet({
  detent,
  onDetent,
  children,
}: {
  detent: Detent;
  onDetent: (d: Detent) => void;
  children: ReactNode;
}) {
  const height = useWindowHeight();
  const g = webGeometry(height);
  const rest = sheetTop(detent, g);
  const [dragTop, setDragTop] = useState<number | null>(null);
  const drag = useRef<Drag | null>(null);
  const suppressClick = useRef(false);
  const top = dragTop ?? rest;

  // The content box is sized for the highest top it shows during a move: it grows at once and shrinks
  // only when the sheet has come down, so no gap ever opens at the window's bottom.
  const [boxTop, setBoxTop] = useState(rest);
  const dragging = dragTop !== null;
  useEffect(() => {
    if (dragging) return;
    if (rest <= boxTop) {
      if (rest !== boxTop) setBoxTop(rest);
      return;
    }
    const t = setTimeout(() => setBoxTop(rest), motionMs());
    return () => clearTimeout(t);
  }, [rest, boxTop, dragging]);
  const shownBoxTop = Math.min(boxTop, rest, top);

  const moving = dragging ? "none" : `transform ${motionMs()}ms ${MOTION_EASE}`;

  function down(e: PointerEvent<HTMLDivElement>) {
    e.currentTarget.setPointerCapture?.(e.pointerId);
    drag.current = { id: e.pointerId, startY: e.clientY, startTop: rest, moved: false, samples: [{ y: e.clientY, t: e.timeStamp }] };
  }
  function move(e: PointerEvent<HTMLDivElement>) {
    const d = drag.current;
    if (!d || d.id !== e.pointerId) return;
    const dy = e.clientY - d.startY;
    if (!d.moved && Math.abs(dy) < 4) return;
    if (!d.moved) {
      d.moved = true;
      setBoxTop(sheetTop("expanded", g));
    }
    d.samples.push({ y: e.clientY, t: e.timeStamp });
    if (d.samples.length > 6) d.samples.shift();
    setDragTop(rubberBand(d.startTop + dy, g));
  }
  function up(e: PointerEvent<HTMLDivElement>) {
    const d = drag.current;
    drag.current = null;
    if (!d || d.id !== e.pointerId || !d.moved) return;
    suppressClick.current = true;
    // Speed over the last samples, in px per second, positive downward.
    const first = d.samples[0];
    const last = d.samples[d.samples.length - 1];
    const dt = (last.t - first.t) / 1000;
    const velocity = dt > 0 ? (last.y - first.y) / dt : 0;
    const to = snap(d.startTop + (e.clientY - d.startY), velocity, g);
    setDragTop(null);
    onDetent(to);
  }
  function click() {
    if (suppressClick.current) {
      suppressClick.current = false;
      return;
    }
    onDetent(raised(detent) ?? "collapsed");
  }
  function key(e: KeyboardEvent<HTMLDivElement>) {
    let to: Detent | null = null;
    if (e.key === "ArrowUp" || e.key === "ArrowRight") to = raised(detent);
    else if (e.key === "ArrowDown" || e.key === "ArrowLeft") to = lowered(detent);
    else if (e.key === "Home") to = "collapsed";
    else if (e.key === "End") to = "expanded";
    else if (e.key === "Enter" || e.key === " ") to = raised(detent) ?? "collapsed";
    else return;
    e.preventDefault();
    if (to) onDetent(to);
  }

  return (
    <section
      data-testid="sheet"
      aria-label="Panel"
      className="absolute right-0 left-0 bg-[var(--sf-background)]"
      style={{
        top: 0,
        // Taller than the window so the rubber band past expanded never shows its bottom edge.
        height: height + 120,
        borderTopLeftRadius: SHEET_RADIUS,
        borderTopRightRadius: SHEET_RADIUS,
        transform: `translateY(${top}px)`,
        transition: moving,
        willChange: "transform",
      }}
    >
      <div
        className="relative overflow-hidden"
        style={{ height: height - shownBoxTop, borderTopLeftRadius: SHEET_RADIUS, borderTopRightRadius: SHEET_RADIUS }}
      >
        <FootContext.Provider value={{ y: height - top, transition: moving }}>{children}</FootContext.Provider>
      </div>
      <div
        role="slider"
        tabIndex={0}
        aria-label="Panel height"
        aria-orientation="vertical"
        aria-valuemin={0}
        aria-valuemax={2}
        aria-valuenow={DETENT_INDEX[detent]}
        aria-valuetext={detent}
        onPointerDown={down}
        onPointerMove={move}
        onPointerUp={up}
        onPointerCancel={up}
        onClick={click}
        onKeyDown={key}
        className="absolute top-0 right-0 left-0 z-[200] flex cursor-grab justify-center outline-none focus-visible:[&>span]:bg-[var(--sf-accent)]"
        style={{ height: GRABBER_STRIP, touchAction: "none" }}
      >
        <span
          aria-hidden
          className="mt-[6px] block h-[5px] w-[36px] rounded-full bg-[color-mix(in_srgb,var(--sf-secondary)_45%,transparent)]"
        />
      </div>
    </section>
  );
}

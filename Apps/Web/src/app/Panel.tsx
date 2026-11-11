import type { ReactNode } from "react";

/** The panel's size and place over the globe, after RegularHomeView (iPad) and the Mac's panel. */
export const PANEL_WIDTH = 402;
export const PANEL_INSET = 16;
export const PANEL_TOP = 8;
export const PANEL_RADIUS = 30;

/**
 * The wide window's panel: 402 px wide, 16 px from the left, 8 px below the top, down to the bottom edge,
 * rounded at the top only, in the sheet colour. The tab's screen and its cards live inside.
 */
export function Panel({ children }: { children: ReactNode }) {
  return (
    <section
      data-testid="panel"
      aria-label="Panel"
      className="absolute bottom-0 overflow-hidden bg-[var(--sf-background)]"
      style={{
        left: PANEL_INSET,
        top: PANEL_TOP,
        width: PANEL_WIDTH,
        borderTopLeftRadius: PANEL_RADIUS,
        borderTopRightRadius: PANEL_RADIUS,
        // Static, never animated: the Swift panel's rim and drop shadow.
        boxShadow: "0 6px 18px rgb(0 0 0 / 0.35)",
      }}
    >
      {children}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0 z-[100]"
        style={{
          borderTopLeftRadius: PANEL_RADIUS,
          borderTopRightRadius: PANEL_RADIUS,
          boxShadow: "inset 0 0 0 1px rgb(255 255 255 / 0.08)",
        }}
      />
    </section>
  );
}

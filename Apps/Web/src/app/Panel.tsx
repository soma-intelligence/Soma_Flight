import type { CSSProperties } from "react";

/** The panel's size and place over the globe, after RegularHomeView (iPad) and the Mac's panel. */
export const PANEL_WIDTH = 402;
export const PANEL_INSET = 16;
export const PANEL_TOP = 8;
export const PANEL_RADIUS = 30;

const radius = { borderTopLeftRadius: PANEL_RADIUS, borderTopRightRadius: PANEL_RADIUS };

/**
 * The wide window's panel: 402 px wide, 16 px from the left, 8 px below the top, down to the bottom edge,
 * rounded at the top only, in the sheet colour. Styles, not a wrapper, so the shell keeps its content at
 * one place in the tree when the window crosses 768 px.
 */
export const panelStyle: CSSProperties = {
  left: PANEL_INSET,
  top: PANEL_TOP,
  bottom: 0,
  width: PANEL_WIDTH,
  overflow: "hidden",
  ...radius,
  // Static, never animated: the Swift panel's drop shadow.
  boxShadow: "0 6px 18px rgb(0 0 0 / 0.35)",
};

/** The panel's content box: all of it. */
export const panelBoxStyle: CSSProperties = { height: "100%" };

/** The panel's rim (PanelChrome's white stroke at 0.08), drawn over the content. */
export function PanelRim() {
  return (
    <div
      aria-hidden
      className="pointer-events-none absolute inset-0 z-[100]"
      style={{ ...radius, boxShadow: "inset 0 0 0 1px rgb(255 255 255 / 0.08)" }}
    />
  );
}

/**
 * The card and sheet motion, after CardMotion in FlightKit (a 0.42 s critically damped spring). Only
 * `transform` and `opacity` animate: no shadow, mask or scale (smoothness rule, 2026-11-08).
 */
export const MOTION_MS = 420;
export const MOTION_EASE = "cubic-bezier(0.2, 0.9, 0.1, 1)";

/** The duration to use now: none for a visitor who asked for reduced motion. */
export function motionMs(): number {
  if (typeof window === "undefined" || !window.matchMedia) return MOTION_MS;
  return window.matchMedia("(prefers-reduced-motion: reduce)").matches ? 0 : MOTION_MS;
}

export function transition(property: "transform" | "opacity"): string {
  return `${property} ${motionMs()}ms ${MOTION_EASE}`;
}

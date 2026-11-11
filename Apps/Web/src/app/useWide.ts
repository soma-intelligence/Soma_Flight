import { useSyncExternalStore } from "react";

/** The width from which the window shows the panel instead of the bottom sheet. */
export const WIDE_QUERY = "(min-width: 768px)";

function subscribe(onChange: () => void): () => void {
  if (typeof window === "undefined" || !window.matchMedia) return () => {};
  const list = window.matchMedia(WIDE_QUERY);
  list.addEventListener("change", onChange);
  return () => list.removeEventListener("change", onChange);
}

function wide(): boolean {
  if (typeof window === "undefined" || !window.matchMedia) return true;
  return window.matchMedia(WIDE_QUERY).matches;
}

/** True while the window is 768 px or wider: the panel over the globe; false: the bottom sheet. */
export function useWide(): boolean {
  return useSyncExternalStore(subscribe, wide, () => true);
}

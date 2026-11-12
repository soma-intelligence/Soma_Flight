import { useLocation, useNavigate } from "react-router";

/** The three tabs of the pill, in its order. */
export type Tab = "flights" | "friends" | "passport";
export const TABS: readonly Tab[] = ["flights", "friends", "passport"];
export const TAB_PATH: Record<Tab, string> = { flights: "/", friends: "/friends", passport: "/passport" };

/** The tab a path is the root of, null for a card route. */
export function tabOf(pathname: string): Tab | null {
  const p = pathname.replace(/\/+$/, "") || "/";
  for (const t of TABS) if (TAB_PATH[t] === p) return t;
  return null;
}

/** What a card route carries in router state: the tab it was opened over. */
export type CardState = { tab?: Tab };

function isTab(v: unknown): v is Tab {
  return typeof v === "string" && (TABS as readonly string[]).includes(v);
}

/**
 * The shell's navigation: the current tab (a card keeps the one it was opened over), opening a card over
 * it, closing the top card, switching tab.
 */
export function useShellNav() {
  const location = useLocation();
  const navigate = useNavigate();
  const pathTab = tabOf(location.pathname);
  const stateTab = (location.state as CardState | null)?.tab;
  const tab: Tab = pathTab ?? (isTab(stateTab) ? stateTab : "flights");
  return {
    tab,
    isCard: pathTab === null,
    /** Opens a card over the current tab. */
    open(path: string) {
      navigate(path, { state: { tab } satisfies CardState });
    },
    /** Closes the top card: back in history, or to the tab when the card was the first page. */
    close() {
      if (location.key !== "default") navigate(-1);
      else navigate(TAB_PATH[tab], { replace: true });
    },
    showTab(t: Tab) {
      if (t !== tab || pathTab === null) navigate(TAB_PATH[t]);
    },
  };
}

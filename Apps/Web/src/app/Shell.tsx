import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { Friends } from "@/screens/friends/Friends";
import { MyFlights } from "@/screens/my-flights/MyFlights";
import { useLiveMyFlights, useMyFlights } from "@/screens/my-flights/useMyFlights";
import { Passport } from "@/screens/passport/Passport";
import { CardStack } from "./CardStack";
import { Globe } from "./globe/Globe";
import { useShellNav, type Tab } from "./nav";
import { FootContext } from "./foot";
import { PanelRim, panelBoxStyle, panelStyle } from "./Panel";
import { useSheet } from "./Sheet";
import type { Detent } from "./sheetGeometry";
import { TabRoot } from "./TabRoot";
import { useWide } from "./useWide";

const TAB_SCREENS: Record<Tab, () => ReactNode> = {
  flights: () => <MyFlights />,
  friends: () => <Friends />,
  passport: () => <Passport />,
};

/**
 * The signed-in app: the globe across the window (its slot, filled by Task 8), and over it the panel
 * (768 px and wider) or the bottom sheet, holding the tab's screen with the open cards over it. A card
 * route keeps the tab it was opened over (router state); Escape closes it, Command or Control K opens
 * Search. The sheet's detent is kept per tab for the session, as ShellModel.showTab does.
 */
export function Shell() {
  const wide = useWide();
  const nav = useShellNav();
  const { tab, isCard } = nav;

  const [detent, setDetent] = useState<Detent>("medium");
  const tabDetents = useRef<Partial<Record<Tab, Detent>>>({});
  const [shownTab, setShownTab] = useState(tab);
  if (shownTab !== tab) {
    tabDetents.current[shownTab] = detent;
    setShownTab(tab);
    setDetent(tabDetents.current[tab] ?? "medium");
  }
  // A card opening over a collapsed sheet raises it to medium (ShellModel.raiseIfCollapsed).
  const [shownCard, setShownCard] = useState(isCard);
  if (shownCard !== isCard) {
    setShownCard(isCard);
    if (isCard && detent === "collapsed") setDetent("medium");
  }

  const navRef = useRef(nav);
  navRef.current = nav;
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      const n = navRef.current;
      if (e.key === "Escape" && n.isCard) {
        e.preventDefault();
        n.close();
      } else if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        n.open("/search");
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  // The followed flights feed the globe on every tab, so the shell, not the list, keeps them live.
  const myFlights = useMyFlights().data;
  useLiveMyFlights(myFlights);
  const globeFlights = useMemo(() => (myFlights ?? []).map((x) => x.flight), [myFlights]);

  const sheet = useSheet(detent, setDetent, !wide);
  const content = <CardStack isCard={isCard} root={<TabRoot>{TAB_SCREENS[tab]()}</TabRoot>} />;

  return (
    <div className="fixed inset-0 overflow-hidden">
      {/* The globe's place: MapKit, or its dark fallback. */}
      <div data-globe-slot className="absolute inset-0">
        <Globe flights={globeFlights} />
      </div>
      {/* One container in both widths: only its chrome changes, so the tab, the cards and their
          scroll positions survive the window crossing 768 px. */}
      <section
        data-testid={wide ? "panel" : "sheet"}
        aria-label="Panel"
        className="absolute bg-[var(--sf-background)]"
        style={wide ? panelStyle : sheet.section}
      >
        <div className="relative overflow-hidden" style={wide ? panelBoxStyle : sheet.box}>
          <FootContext.Provider value={wide ? null : sheet.foot}>{content}</FootContext.Provider>
        </div>
        {wide ? <PanelRim /> : sheet.grabber}
      </section>
    </div>
  );
}

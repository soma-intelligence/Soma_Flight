import { IdCard, Plane, Search, Users } from "lucide-react";
import type { ComponentType } from "react";
import type { Tab } from "@/app/nav";
import { MOTION_EASE } from "@/app/motion";
import "./shell.css";

type IconProps = { size?: number; strokeWidth?: number; "aria-hidden"?: boolean };

/** The pill's tabs in order, with their English labels from Localizable.xcstrings. */
const ITEMS: { tab: Tab; title: string; icon: ComponentType<IconProps> }[] = [
  { tab: "flights", title: "My Flights", icon: Plane },
  { tab: "friends", title: "Friends", icon: Users },
  { tab: "passport", title: "Passport", icon: IdCard },
];

/**
 * The floating pill with the three tabs and the round search button beside it, after HomeTabPill:
 * 20 px from the sides, 8 px above, items 51 px tall in 4 px of padding, the button 59 px, 10 px apart.
 * The selection capsule slides between the tabs (transform only).
 */
export function TabPill({ tab, onTab, onSearch }: { tab: Tab; onTab: (t: Tab) => void; onSearch: () => void }) {
  const index = ITEMS.findIndex((i) => i.tab === tab);
  return (
    <div className="flex items-center gap-[10px] px-5 pt-2">
      <div className="sf-glass relative flex flex-1 rounded-full p-1">
        <span
          aria-hidden
          className="pointer-events-none absolute top-1 bottom-1 left-1 rounded-full bg-[color-mix(in_srgb,var(--sf-primary)_10%,transparent)]"
          style={{
            width: "calc((100% - 8px) / 3)",
            transform: `translateX(${Math.max(index, 0) * 100}%)`,
            transition: `transform 300ms ${MOTION_EASE}`,
          }}
        />
        {ITEMS.map(({ tab: t, title, icon: Icon }) => {
          const selected = t === tab;
          return (
            <button
              key={t}
              type="button"
              aria-pressed={selected}
              onClick={() => onTab(t)}
              className={`relative flex h-[51px] flex-1 flex-col items-center justify-center gap-[2px] rounded-full ${
                selected ? "text-[var(--sf-accent)]" : "text-[var(--sf-primary)]"
              }`}
            >
              <Icon size={21} strokeWidth={2} aria-hidden />
              <span className="text-[11px] leading-[13px] font-semibold">{title}</span>
            </button>
          );
        })}
      </div>
      <button
        type="button"
        aria-label="Search"
        onClick={onSearch}
        className="sf-glass flex size-[59px] shrink-0 items-center justify-center rounded-full text-[var(--sf-primary)]"
      >
        <Search size={22} strokeWidth={2.6} aria-hidden />
      </button>
    </div>
  );
}

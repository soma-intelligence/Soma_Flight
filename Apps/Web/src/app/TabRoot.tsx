import { User } from "lucide-react";
import type { ReactNode } from "react";
import { RoundButton } from "@/ui/RoundButton";
import { TabPill } from "@/ui/TabPill";
import { useFoot } from "./foot";
import { useShellNav } from "./nav";

/** The pill row's height: 8 px above, the 59 px pill, 20 px to the edge. */
export const PILL_BLOCK = 8 + 59 + 20;
/** How far above the pill the list starts to fade (PillFadeMask.fade). */
const FADE = 44;

/**
 * A tab's screen with the profile button at its top right and the pill at its foot, after HomeSheetBody
 * and the panel's listRoot: the list keeps room for the pill and fades out above it, from 44 px over the
 * pill to the pill's middle, so no row reads through the glass.
 */
export function TabRoot({ children }: { children: ReactNode }) {
  const nav = useShellNav();
  const foot = useFoot();
  const footHeight = FADE + PILL_BLOCK;
  // The fade: clear, 0.65 of the sheet colour at 55%, solid by the pill's middle, then solid down.
  const solidAt = FADE + 8 + 59 / 2;
  const fade = `linear-gradient(to bottom, transparent 0px, color-mix(in srgb, var(--sf-background) 65%, transparent) ${
    solidAt * 0.55
  }px, var(--sf-background) ${solidAt}px)`;
  return (
    <div className="absolute inset-0">
      <div className="h-full overflow-y-auto overscroll-contain" style={{ paddingBottom: PILL_BLOCK }}>
        {children}
      </div>
      <RoundButton
        icon={User}
        label="Settings and profile"
        onClick={() => nav.open("/settings")}
        className="absolute top-[19px] right-4"
      />
      <div
        className="pointer-events-none absolute right-0 left-0"
        style={
          foot
            ? { top: 0, height: footHeight, transform: `translateY(${foot.y - footHeight}px)`, transition: foot.transition }
            : { bottom: 0, height: footHeight }
        }
      >
        <div className="absolute inset-0" style={{ background: fade }} />
        <div className="pointer-events-auto absolute right-0 bottom-0 left-0 pb-5">
          <TabPill tab={nav.tab} onTab={nav.showTab} onSearch={() => nav.open("/search")} />
        </div>
      </div>
    </div>
  );
}

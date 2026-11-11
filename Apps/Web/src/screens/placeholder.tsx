import { X } from "lucide-react";
import type { ReactNode } from "react";
import { useShellNav } from "@/app/nav";
import { RoundButton } from "@/ui/RoundButton";

/** A tab screen's large title, 22 px from the top as the app's headers (SheetGeometry.headerHeight). */
export function TabTitle({ children }: { children: ReactNode }) {
  return <h1 className="px-5 pt-[22px] pb-3 text-[34px] leading-[40px] font-bold text-[var(--sf-primary)]">{children}</h1>;
}

/** A card's frame until its screen lands: the title and the round close X at the top right. */
export function CardFrame({ title, testId, children }: { title: string; testId?: string; children?: ReactNode }) {
  const nav = useShellNav();
  return (
    <div data-testid={testId} className="relative h-full overflow-y-auto">
      <h1 className="px-5 pt-[22px] pr-[76px] pb-3 text-[28px] leading-[34px] font-bold text-[var(--sf-primary)]">
        {title}
      </h1>
      {children}
      <RoundButton icon={X} label="Close" onClick={nav.close} className="absolute top-4 right-4" />
    </div>
  );
}

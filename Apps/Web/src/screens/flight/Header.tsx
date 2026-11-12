import { X } from "lucide-react";
import type { Flight } from "@/data/types";
import { AirlineMark } from "@/ui/AirlineMark";
import type { AirportInfo } from "@/ui/airports";
import { airlineCode, destinationCode, originCode } from "@/ui/format";
import { RoundButton } from "@/ui/RoundButton";
import { headerLine } from "./facts";

/**
 * The pinned top of the flight card, after DetailHeader: the airline's mark, "UA 990 · FRI, 30 OCT", the
 * route as the title and the close button, a hairline under it.
 */
export function Header({
  flight,
  origin,
  destination,
  onClose,
}: {
  flight: Flight;
  origin: AirportInfo | null;
  destination: AirportInfo | null;
  onClose: () => void;
}) {
  return (
    <header className="flex items-center gap-3 border-b border-[var(--sf-separator)] pt-4 pr-4 pb-3 pl-5">
      <AirlineMark code={airlineCode(flight)} size={40} />
      <div className="min-w-0 flex-1">
        <p className="truncate text-[13px] font-semibold text-[var(--sf-secondary)]">{headerLine(flight, origin?.tz)}</p>
        <h1 className="line-clamp-2 text-[20px] leading-[25px] font-bold text-[var(--sf-primary)]">
          {`${origin?.city ?? originCode(flight)} to ${destination?.city ?? destinationCode(flight)}`}
        </h1>
      </div>
      <RoundButton icon={X} label="Close" onClick={onClose} />
    </header>
  );
}

const TONE = { "on-time": "var(--sf-on-time)", "very-late": "var(--sf-very-late)" } as const;

/** The rounded card under the header (CountdownCard): "Departs in 1 day" and where the flight stands. */
export function CountdownCard({
  title,
  caption,
  tone,
}: {
  title: string;
  caption: string;
  tone: keyof typeof TONE | null;
}) {
  const c = tone ? TONE[tone] : null;
  return (
    <div
      data-testid="countdown-card"
      className="rounded-[18px] border px-4 py-[14px]"
      style={{
        background: c ? `color-mix(in srgb, ${c} 16%, transparent)` : "var(--sf-card)",
        borderColor: c ? `color-mix(in srgb, ${c} 35%, transparent)` : "var(--sf-separator)",
      }}
    >
      <p className="text-[18px] font-semibold" style={{ color: c ?? "var(--sf-primary)" }}>
        {title}
      </p>
      <p
        className={`mt-[3px] text-[15px] ${c ? "font-medium" : ""}`}
        style={{ color: c ? `color-mix(in srgb, ${c} 85%, transparent)` : "var(--sf-secondary)" }}
      >
        {caption}
      </p>
    </div>
  );
}

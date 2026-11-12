import type { Flight } from "@/data/types";
import { LEVEL_COLOR } from "@/ui/format";
import type { TimetableRow } from "./facts";

/** A detail card's frame (DetailCard): rounded 20, half the card colour, a hairline rim. */
export function DetailCard({ children, padded = true }: { children: React.ReactNode; padded?: boolean }) {
  return (
    <section
      className={`overflow-hidden rounded-[20px] border border-[var(--sf-separator)] bg-[color-mix(in_srgb,var(--sf-card)_50%,transparent)] ${
        padded ? "p-4" : ""
      }`}
    >
      {children}
    </section>
  );
}

/** Title and grey subtitle at the top of a card (CardTitle). */
export function CardTitle({ title, subtitle }: { title: string; subtitle?: string }) {
  return (
    <div>
      <h2 className="text-[22px] font-bold text-[var(--sf-primary)]">{title}</h2>
      {subtitle && <p className="mt-[3px] text-[15px] font-medium text-[var(--sf-secondary)]">{subtitle}</p>}
    </div>
  );
}

const SECTION_WORD = { depart: "Depart", arrive: "Arrive", totals: "Totals" } as const;

/** The timetable card (TimetableCard): DEPART, ARRIVE and TOTALS, each row with the schedule and the other time. */
export function TimetableCard({ rows }: { rows: TimetableRow[] }) {
  const groups = (["depart", "arrive", "totals"] as const)
    .map((s) => ({ section: s, rows: rows.filter((r) => r.section === s) }))
    .filter((g) => g.rows.length > 0);
  return (
    <DetailCard padded={false}>
      <div className="px-4 pt-5 pb-2">
        <CardTitle title="Detailed Timetable" subtitle="Scheduled, estimated and actual times" />
      </div>
      {groups.map((g, i) => (
        <div key={g.section} className={`px-4 pb-2.5 ${i > 0 ? "border-t border-[var(--sf-separator)]" : ""}`}>
          <h3 className="pt-4 pb-1 text-[14px] font-medium text-[color-mix(in_srgb,var(--sf-secondary)_70%,transparent)] uppercase">
            {SECTION_WORD[g.section]}
          </h3>
          {g.rows.map((r, j) => (
            <div
              key={j}
              className="flex flex-wrap items-center gap-x-3 gap-y-1.5 py-2.5"
              aria-label={`${r.title}: Scheduled ${r.scheduled}, ${r.otherLabel.toLowerCase()} ${r.other}`}
            >
              <span className="min-w-[110px] flex-1 text-[17px] text-[var(--sf-primary)]">{r.title}</span>
              <span className="flex gap-[18px]">
                <Cell label="Scheduled" value={r.scheduled} color={r.scheduled === "--" ? "var(--sf-secondary)" : undefined} />
                <Cell
                  label={r.otherLabel}
                  value={r.other}
                  color={r.level ? LEVEL_COLOR[r.level] : r.other === "--" ? "var(--sf-secondary)" : undefined}
                />
              </span>
            </div>
          ))}
        </div>
      ))}
    </DetailCard>
  );
}

function Cell({ label, value, color }: { label: string; value: string; color?: string }) {
  return (
    <span className="flex min-w-[82px] flex-col gap-0.5">
      <span className="text-[15px] text-[var(--sf-secondary)]">{label}</span>
      <span className="text-[19px] tabular-nums" style={{ color: color ?? "var(--sf-primary)" }}>
        {value}
      </span>
    </span>
  );
}

/** Gates and terminals at both ends, and the belt once known; "Gate --" until a gate is assigned. */
export function GatesCard({ flight }: { flight: Flight }) {
  const side = (word: string, gate: string | null, terminal: string | null, belt?: string | null) => (
    <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1 py-2.5">
      <span className="text-[17px] text-[var(--sf-primary)]">{word}</span>
      <span className="flex flex-wrap gap-x-4 text-[17px] tabular-nums">
        <span style={{ color: gate ? "var(--sf-primary)" : "var(--sf-secondary)" }}>{`Gate ${gate ?? "--"}`}</span>
        <span className="text-[var(--sf-secondary)]">{`Terminal ${terminal ?? "--"}`}</span>
        {belt && <span className="text-[var(--sf-secondary)]">{`Belt ${belt}`}</span>}
      </span>
    </div>
  );
  return (
    <DetailCard>
      <CardTitle title="Gates and Terminals" />
      <div className="pt-2">
        {side("Depart", flight.gateOrigin, flight.terminalOrigin)}
        <div className="border-t border-[var(--sf-separator)]" />
        {side("Arrive", flight.gateDestination, flight.terminalDestination, flight.baggageBelt)}
      </div>
    </DetailCard>
  );
}

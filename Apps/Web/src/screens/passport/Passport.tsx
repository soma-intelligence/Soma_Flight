import { useEffect, useMemo, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { computePassport, computePassportDetail, initCore, type PassportStats } from "@/core/flightcore";
import {
  addPastFlight,
  saveFailureCopy,
  deletePastFlight,
  downloadExport,
  fetchPastFlights,
  localYear,
  pastFlightsKey,
  toCore,
  type PastFlight,
} from "@/data/passport";
import { useAirports } from "@/ui/airports";
import { ErrorBanner } from "@/ui/ErrorBanner";
import { errorCode, errorCopy } from "@/ui/errorCopy";
import { JetIllustration } from "@/ui/JetIllustration";
import { duration } from "@/ui/format";
import { TabTitle } from "../placeholder";
import { AddPastFlight } from "./AddPastFlight";

const DELETE_FAILED = "Couldn't delete this flight. Try again later.";

/**
 * The travel record, after PassportView: year chips, the passport card with all-time or yearly totals
 * (the core's compute_passport), then every past flight newest first, with Add Past Flight, Delete (after
 * the app's confirmation) and the JSON and CSV export, built in the browser. The first cut: no import,
 * year in review or map.
 */
export function Passport() {
  const qc = useQueryClient();
  const airports = useAirports();
  const q = useQuery({ queryKey: pastFlightsKey, queryFn: fetchPastFlights });
  const [year, setYear] = useState<number | null>(null);
  const [adding, setAdding] = useState(false);
  const [confirming, setConfirming] = useState<PastFlight | null>(null);
  const [deleteFailed, setDeleteFailed] = useState(false);
  const [coreReady, setCoreReady] = useState(false);

  useEffect(() => {
    let live = true;
    initCore().then(
      () => live && setCoreReady(true),
      () => {},
    );
    return () => {
      live = false;
    };
  }, []);

  const all = useMemo(() => [...(q.data ?? [])].sort((a, b) => b.date.getTime() - a.date.getTime()), [q.data]);
  const years = useMemo(() => [...new Set(all.map((f) => localYear(f, airports)))].sort((a, b) => b - a), [all, airports]);
  const selected = year !== null && years.includes(year) ? year : null;
  const shown = useMemo(
    () => (selected === null ? all : all.filter((f) => localYear(f, airports) === selected)),
    [all, selected, airports],
  );
  // Totals and the country count both come from the core. "failed" shows a dash, never dots forever.
  const figures = useMemo<{ stats: PassportStats; countries: number } | "failed" | null>(() => {
    if (!coreReady || all.length === 0) return null;
    try {
      const rows = toCore(all, airports);
      return {
        stats: computePassport(rows, selected),
        countries: computePassportDetail(rows, selected).countries.length,
      };
    } catch {
      return "failed";
    }
  }, [coreReady, all, airports, selected]);

  const add = useMutation({
    mutationFn: (v: { ident: string; day: string; from: string; to: string }) => addPastFlight(v, airports),
    onSuccess: async () => {
      setAdding(false);
      await qc.invalidateQueries({ queryKey: pastFlightsKey });
    },
  });
  const del = useMutation({
    mutationFn: (id: string) => deletePastFlight(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: pastFlightsKey }),
    onError: () => setDeleteFailed(true),
  });

  function openAdd() {
    add.reset();
    setAdding(true);
  }

  return (
    <div>
      <TabTitle>Passport</TabTitle>
      {years.length > 0 && (
        <div role="group" aria-label="Year" className="flex gap-2 overflow-x-auto px-4 pb-3">
          {[null, ...years].map((y) => (
            <button
              key={y ?? "all"}
              type="button"
              aria-pressed={selected === y}
              onClick={() => setYear(y)}
              className={`shrink-0 rounded-full px-4 py-2 text-[15px] font-semibold ${
                selected === y ? "bg-[var(--sf-primary)] text-[var(--sf-background)]" : "bg-[var(--sf-pill)] text-[var(--sf-primary)]"
              }`}
            >
              {y ?? "All-Time"}
            </button>
          ))}
        </div>
      )}
      <div className="px-4 pb-8">
        {q.error && (
          <div className="pb-3">
            <ErrorBanner message={errorCopy(errorCode(q.error))} onRetry={() => void q.refetch()} />
          </div>
        )}
        {deleteFailed && (
          <div className="pb-3">
            <ErrorBanner message={DELETE_FAILED} />
          </div>
        )}
        {all.length === 0 ? (
          q.isPending || (q.error && q.isFetching) ? (
            <div role="status" aria-label="Loading your passport" className="flex min-h-[200px] items-center justify-center">
              <span className="size-6 animate-spin rounded-full border-2 border-[var(--sf-separator)] border-t-[var(--sf-secondary)]" />
            </div>
          ) : q.error ? null : (
            <EmptyPassport onAdd={openAdd} />
          )
        ) : (
          <>
            <PassportCard year={selected} figures={figures} />
            <section aria-label="Past flights section" className="pt-5">
              <div className="flex flex-wrap items-center justify-between gap-2 pb-2.5">
                <h2 className="text-[13px] text-[var(--sf-secondary)] uppercase">
                  Past flights <span>{shown.length}</span>
                </h2>
                <div className="flex gap-2">
                  <Pill onClick={openAdd}>Add Past Flight</Pill>
                  <Pill onClick={() => downloadExport("csv", all)}>Export CSV</Pill>
                  <Pill onClick={() => downloadExport("json", all)}>Export JSON</Pill>
                </div>
              </div>
              <ul aria-label="Past flights" className="overflow-hidden rounded-[18px] bg-[var(--sf-card)]">
                {shown.map((f) => (
                  <PastRow
                    key={f.id}
                    f={f}
                    airport={airports}
                    onDelete={() => {
                      setDeleteFailed(false);
                      setConfirming(f);
                    }}
                  />
                ))}
              </ul>
            </section>
          </>
        )}
      </div>
      {adding && (
        <AddPastFlight
          airports={airports}
          saving={add.isPending}
          failure={add.isError ? saveFailureCopy(add.error) : null}
          onClose={() => setAdding(false)}
          onSave={(v) => add.mutate(v)}
        />
      )}
      {confirming && (
        <ConfirmDelete
          onCancel={() => setConfirming(null)}
          onConfirm={() => {
            const id = confirming.id;
            setConfirming(null);
            del.mutate(id);
          }}
        />
      )}
    </div>
  );
}

function Pill({ onClick, children }: { onClick: () => void; children: string }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className="rounded-full bg-[var(--sf-pill)] px-3.5 py-1.5 text-[14px] font-semibold text-[var(--sf-primary)]"
    >
      {children}
    </button>
  );
}

function Figure({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <p className="text-[12px] font-medium tracking-wide text-[rgba(204,209,255,0.78)] uppercase">{label}</p>
      <p className="text-[28px] leading-[34px] font-semibold text-white tabular-nums">{value}</p>
    </div>
  );
}

/** "21,720 km" (the app also offers miles; units follow Settings once it lands). */
const km = (n: number) => `${n.toLocaleString("en-US")} km`;

/** The passport card: totals and countries from the core; "..." while it loads, "-" when it fails. */
function PassportCard({
  year,
  figures,
}: {
  year: number | null;
  figures: { stats: PassportStats; countries: number } | "failed" | null;
}) {
  const v = (f: (x: { stats: PassportStats; countries: number }) => string) =>
    figures === "failed" ? "-" : figures ? f(figures) : "...";
  return (
    <section
      aria-label="Passport"
      className="rounded-[20px] bg-gradient-to-br from-[#1b2150] to-[#0d1030] p-5 text-white"
    >
      <h2 className="text-[20px] font-medium tracking-wide uppercase">{year ?? "All-Time"} Soma Flight Passport</h2>
      <div className="grid grid-cols-2 gap-x-3.5 gap-y-4 pt-5">
        <Figure label="Flights" value={v((x) => String(x.stats.flights))} />
        <Figure label="Distance" value={v((x) => km(x.stats.distanceKm))} />
        <Figure label="Flight time" value={v((x) => duration(x.stats.flightMinutes))} />
        <Figure label="Airports" value={v((x) => String(x.stats.airports))} />
        <Figure label="Countries" value={v((x) => String(x.countries))} />
      </div>
    </section>
  );
}

function PastRow({ f, airport, onDelete }: { f: PastFlight; airport: ReturnType<typeof useAirports>; onDelete: () => void }) {
  const o = airport(f.originIcao);
  const d = airport(f.destinationIcao);
  const name = f.ident || "Private flight";
  const day = (() => {
    try {
      return new Intl.DateTimeFormat("en-US", {
        month: "short",
        day: "numeric",
        year: "numeric",
        timeZone: f.originTz ?? o?.tz ?? "UTC",
      }).format(f.date);
    } catch {
      return f.date.toISOString().slice(0, 10);
    }
  })();
  return (
    <li data-ident={f.ident} className="flex items-center gap-3 border-b border-[var(--sf-separator)] px-4 py-3 last:border-b-0">
      <div className="min-w-0 flex-1">
        <p className="text-[17px] font-semibold text-[var(--sf-primary)]">
          {o?.iata ?? f.originIcao} to {d?.iata ?? f.destinationIcao}
        </p>
        <p className="truncate text-[14px] text-[var(--sf-secondary)]">
          {name}
          {" · "}
          {day}
          {f.distanceKm > 0 ? ` · ${km(f.distanceKm)}` : ""}
          {f.status !== "completed" ? ` · ${f.status === "canceled" ? "Canceled" : "Diverted"}` : ""}
        </p>
      </div>
      <button
        type="button"
        aria-label={`Delete ${name} ${f.originIcao} to ${f.destinationIcao}`}
        onClick={onDelete}
        className="shrink-0 rounded-full px-3 py-1.5 text-[14px] font-semibold text-[var(--sf-very-late)]"
      >
        Delete
      </button>
    </li>
  );
}

/** The app's confirmation: "Delete this flight from your history?" with Delete Flight and Cancel. */
function ConfirmDelete({ onCancel, onConfirm }: { onCancel: () => void; onConfirm: () => void }) {
  useEffect(() => {
    const esc = (e: KeyboardEvent) => e.key === "Escape" && onCancel();
    window.addEventListener("keydown", esc);
    return () => window.removeEventListener("keydown", esc);
  }, [onCancel]);
  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/40 p-4 sm:items-center" onClick={onCancel}>
      <div
        role="alertdialog"
        aria-modal="true"
        aria-label="Delete this flight from your history?"
        onClick={(e) => e.stopPropagation()}
        className="w-full max-w-[340px] rounded-[20px] bg-[var(--sf-card)] p-5 text-center"
      >
        <p className="text-[17px] font-semibold text-[var(--sf-primary)]">Delete this flight from your history?</p>
        <button
          type="button"
          onClick={onConfirm}
          className="mt-4 h-11 w-full rounded-full bg-[var(--sf-very-late)] text-[17px] font-semibold text-white"
        >
          Delete Flight
        </button>
        <button
          type="button"
          onClick={onCancel}
          className="mt-2 h-11 w-full rounded-full bg-[var(--sf-pill)] text-[17px] font-semibold text-[var(--sf-primary)]"
        >
          Cancel
        </button>
      </div>
    </div>
  );
}

function EmptyPassport({ onAdd }: { onAdd: () => void }) {
  return (
    <div className="flex min-h-[200px] flex-col items-center gap-1.5 py-6 text-center">
      <div className="w-full py-3 pb-[22px]">
        <JetIllustration width={240} />
      </div>
      <h2 className="text-[20px] font-semibold text-[var(--sf-primary)]">Your passport starts here</h2>
      <p className="text-[15px] text-[var(--sf-secondary)]">Past flights you add or import collect stamps here.</p>
      <div className="pt-4">
        <Pill onClick={onAdd}>Add Past Flight</Pill>
      </div>
    </div>
  );
}

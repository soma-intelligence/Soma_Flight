import { useEffect, useId, useRef, useState } from "react";
import { validateNewFlight, type NewFlightProblem } from "@/data/passport";
import type { AirportDirectory } from "@/ui/airports";

/** Today as YYYY-MM-DD in the browser's zone: the latest day the picker offers. */
function today(now: Date = new Date()): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())}`;
}

export type AddInput = { ident: string; day: string; from: string; to: string };

/**
 * The Add Past Flight sheet, minimal: flight number (optional), day, from and to (PastFlightEditorSheet).
 * Each field that does not read shows the app's line under it and nothing is saved. `onSave` rejects with
 * the failure to show; the sheet stays open until it resolves.
 */
export function AddPastFlight({
  airports,
  onSave,
  onClose,
  saving,
  failure,
}: {
  airports: AirportDirectory;
  onSave: (input: AddInput) => void;
  onClose: () => void;
  saving: boolean;
  failure: string | null;
}) {
  const [ident, setIdent] = useState("");
  const [day, setDay] = useState(() => today());
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");
  const [errors, setErrors] = useState<Partial<Record<NewFlightProblem, string>>>({});
  const titleId = useId();
  const first = useRef<HTMLInputElement>(null);

  useEffect(() => {
    first.current?.focus();
    const esc = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", esc);
    return () => window.removeEventListener("keydown", esc);
  }, [onClose]);

  function submit(e: { preventDefault: () => void }) {
    e.preventDefault();
    if (saving) return;
    const r = validateNewFlight({ ident, day, from, to }, airports);
    if (!r.ok) {
      setErrors(r.errors);
      return;
    }
    setErrors({});
    onSave({ ident, day, from, to });
  }

  const field = (label: string, value: string, set: (v: string) => void, problem: NewFlightProblem | NewFlightProblem[], extra: { placeholder?: string; type?: string; max?: string; ref?: boolean } = {}) => {
    const keys = Array.isArray(problem) ? problem : [problem];
    const msg = keys.map((k) => errors[k]).find(Boolean);
    return (
      <label className="block pt-4">
        <span className="text-[13px] text-[var(--sf-secondary)] uppercase">{label}</span>
        <input
          ref={extra.ref ? first : undefined}
          value={value}
          type={extra.type ?? "text"}
          max={extra.max}
          placeholder={extra.placeholder}
          autoCapitalize="characters"
          autoComplete="off"
          aria-invalid={msg ? true : undefined}
          onChange={(e) => set(e.target.value)}
          className="mt-1.5 block h-11 w-full rounded-[12px] bg-[var(--sf-pill)] px-3 text-[17px] text-[var(--sf-primary)] outline-none focus-visible:ring-2 focus-visible:ring-[var(--sf-accent)]"
        />
        {msg && <span className="mt-1 block text-[13px] text-[var(--sf-very-late)]">{msg}</span>}
      </label>
    );
  };

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/40 sm:items-center" onClick={onClose}>
      <form
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        onSubmit={submit}
        onClick={(e) => e.stopPropagation()}
        noValidate
        className="max-h-full w-full max-w-[420px] overflow-y-auto rounded-t-[24px] bg-[var(--sf-card)] p-5 sm:rounded-[24px]"
      >
        <h2 id={titleId} className="text-[20px] font-semibold text-[var(--sf-primary)]">
          Add Past Flight
        </h2>
        {failure && (
          <p role="alert" className="pt-3 text-[15px] text-[var(--sf-very-late)]">
            {failure}
          </p>
        )}
        {field("Day", day, setDay, "date", { type: "date", max: today(), ref: true })}
        {field("From", from, setFrom, "origin", { placeholder: "Code, like SFO" })}
        {field("To", to, setTo, ["destination", "sameAirports"], { placeholder: "Code, like JFK" })}
        {field("Flight number", ident, setIdent, "ident", { placeholder: "Optional, like UA990" })}
        <div className="flex gap-3 pt-6">
          <button
            type="button"
            onClick={onClose}
            className="h-11 flex-1 rounded-full bg-[var(--sf-pill)] text-[17px] font-semibold text-[var(--sf-primary)]"
          >
            Cancel
          </button>
          <button
            type="submit"
            disabled={saving}
            className="h-11 flex-1 rounded-full bg-[var(--sf-accent)] text-[17px] font-semibold text-white disabled:opacity-60"
          >
            Save
          </button>
        </div>
      </form>
    </div>
  );
}

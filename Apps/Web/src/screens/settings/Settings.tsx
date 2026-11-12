import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState, type ReactNode } from "react";
import { useNavigate } from "react-router";
import { signOut, useSession } from "@/app/session";
import { fetchFriendsMe, friendsMeKey, type FriendsMe } from "@/data/friends";
import { useFakes } from "@/data/flights";
import {
  deleteAccount,
  fetchNotificationPrefs,
  notificationPrefsKey,
  readAppearance,
  readUnits,
  saveDisplayName,
  setNotificationPref,
  writeAppearance,
  writeUnits,
  type Appearance,
  type NotificationColumn,
  type NotificationPrefs,
  type Units,
} from "@/data/settings";
import { errorCode, errorCopy } from "@/ui/errorCopy";
import { CardFrame } from "../placeholder";

const DELETE_TITLE = "Delete your account?";
const DELETE_MESSAGE = "Your followed flights and flight history will be removed. This can't be undone.";

/** The alert categories, in the app's order, with its titles and grey lines (NotificationPreferences.Category). */
const CATEGORIES: { column: NotificationColumn; title: string; detail: string }[] = [
  {
    column: "delays",
    title: "Delays",
    detail: "New delays, back on time, schedule changes, a late inbound plane, FAA ground stops",
  },
  { column: "gates", title: "Gates and Terminals", detail: "Your gate, gate changes and terminal changes" },
  {
    column: "takeoff_landing",
    title: "Take-off and Landing",
    detail: "Left the gate, took off, landed, arrived at the gate",
  },
  { column: "boarding", title: "Boarding", detail: "Boarding has started, boarding time changes" },
  {
    column: "aircraft",
    title: "Aircraft Changes",
    detail: "A different aircraft type or tail number before you leave",
  },
  { column: "baggage", title: "Baggage", detail: "The belt your bags come out on" },
  {
    column: "cancellations",
    title: "Cancellations and Diversions",
    detail: "Canceled, back on the schedule, diverted",
  },
  {
    column: "favorite_airports",
    title: "Favorite Airports",
    detail: "Ground stops, delay programs and closures at airports you follow",
  },
];

/** The app's line for a failed write: a refused value says why, anything else the usual copy. */
function failureText(e: unknown): string {
  const m = (e as { message?: string; code?: string }) ?? {};
  return m.code === "invalid_request" && m.message ? m.message : errorCopy(errorCode(e));
}

/**
 * Settings, after SettingsView: profile, units, notifications, appearance, then the account (Sign Out and
 * Delete Account). Units and appearance are kept in this browser only; the notification switches are the
 * `notification_preferences` row.
 */
export function Settings() {
  const navigate = useNavigate();
  const qc = useQueryClient();
  const fakes = useFakes();
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [confirming, setConfirming] = useState(false);
  const [units, setUnits] = useState<Units>(readUnits);
  const [appearance, setAppearance] = useState<Appearance>(readAppearance);
  const [draft, setDraft] = useState<string | null>(null);

  const me = useQuery({ queryKey: friendsMeKey, queryFn: fetchFriendsMe });
  const prefs = useQuery({ queryKey: notificationPrefsKey, queryFn: fetchNotificationPrefs });

  const toggle = useMutation({
    mutationKey: ["notificationPref"],
    mutationFn: ({ column, on }: { column: NotificationColumn; on: boolean }) => setNotificationPref(column, on),
    onMutate: ({ column, on }) => {
      setMessage(null);
      qc.setQueryData<NotificationPrefs>(notificationPrefsKey, (old) => (old ? { ...old, [column]: on } : old));
    },
    onError: (e) => setMessage(failureText(e)),
    // The server's row is the truth: read it back once the last write settles (no stale snapshot to restore).
    onSettled: () => {
      if (qc.isMutating({ mutationKey: ["notificationPref"] }) <= 1)
        void qc.invalidateQueries({ queryKey: notificationPrefsKey });
    },
  });

  const rename = useMutation({
    mutationFn: (name: string) => saveDisplayName(name),
    onSuccess: (_d, name) => {
      qc.setQueryData<FriendsMe>(friendsMeKey, (old) => (old ? { ...old, displayName: name.trim() } : old));
      setDraft(null);
    },
    onError: (e) => setMessage(failureText(e)),
  });

  const name = draft ?? me.data?.displayName ?? "";
  // The database keeps 1 to 40 characters after trimming, so an empty draft cannot be saved.
  const nameChanged = draft !== null && draft.trim() !== "" && draft.trim() !== (me.data?.displayName ?? "");

  async function out() {
    setBusy(true);
    setMessage(null);
    try {
      await signOut();
    } catch (e) {
      // Development fakes have no session to end; anywhere else the failure shows.
      if (!fakes) {
        console.error(e);
        setBusy(false);
        setMessage("That did not work. Try again.");
        return;
      }
    }
    setBusy(false);
    navigate("/", { replace: true });
  }

  /** The confirmed deletion: the function, then sign out. Fakes have no account, so they only sign out. */
  async function remove() {
    setConfirming(false);
    setBusy(true);
    setMessage(null);
    if (!fakes) {
      try {
        await deleteAccount();
      } catch (e) {
        setBusy(false);
        setMessage(`${errorCopy(errorCode(e))} You're still signed in.`);
        return;
      }
    }
    try {
      await signOut();
    } catch {
      // The account is gone (or there is no session to end): leave all the same.
    }
    setBusy(false);
    navigate("/", { replace: true });
  }

  return (
    <CardFrame title="Settings" testId="settings-card">
      <div className="flex flex-col gap-1 px-4 pb-10">
        <Group title="Profile">
          <div className="flex flex-col gap-3 px-4 py-3">
            <label className="flex flex-col gap-1 text-[13px] text-[var(--sf-secondary)]">
              Name
              <span className="flex items-center gap-2">
                <input
                  value={name}
                  onChange={(e) => setDraft(e.target.value)}
                  maxLength={40}
                  placeholder="Shown to your friends"
                  className="h-10 min-w-0 flex-1 rounded-[10px] bg-[var(--sf-background)] px-3 text-[17px] text-[var(--sf-primary)] placeholder:text-[var(--sf-secondary)]"
                />
                {nameChanged && (
                  <button
                    type="button"
                    onClick={() => rename.mutate(draft ?? "")}
                    disabled={rename.isPending}
                    className="h-10 rounded-full bg-[var(--sf-accent)] px-4 text-[15px] font-semibold text-white disabled:opacity-60"
                  >
                    Save
                  </button>
                )}
              </span>
            </label>
            <div className="flex flex-col gap-0.5 text-[13px] text-[var(--sf-secondary)]">
              Email
              {fakes && import.meta.env.DEV ? (
                <span className="text-[17px] text-[var(--sf-primary)]">demo@example.com</span>
              ) : (
                <Email />
              )}
            </div>
          </div>
        </Group>

        <Group title="Units" footer="Kept in this browser.">
          <Choice
            label="Distance"
            value={units.distance}
            options={[
              ["km", "Kilometers"],
              ["mi", "Miles"],
            ]}
            onChange={(distance) => {
              const next = { ...units, distance };
              setUnits(next);
              writeUnits(next);
            }}
          />
          <Choice
            label="Time"
            value={units.clock}
            options={[
              ["h24", "24-Hour"],
              ["h12", "12-Hour"],
            ]}
            onChange={(clock) => {
              const next = { ...units, clock };
              setUnits(next);
              writeUnits(next);
            }}
          />
        </Group>

        <section aria-label="Notifications" className="pt-4">
          <h2 className="px-4 pb-1.5 text-[13px] text-[var(--sf-secondary)] uppercase">Notifications</h2>
          <p className="px-4 text-[15px] text-[var(--sf-secondary)]">
            Alerts arrive on your phone, through the Soma Flight app. These switches count for every flight on your
            account.
          </p>
        </section>
        {[
          { title: "Flight Alerts", items: CATEGORIES.slice(0, 7) },
          { title: "Airports", items: CATEGORIES.slice(7) },
        ].map((g) => (
          <Group key={g.title} title={g.title}>
            {g.items.map((c, i) => (
              <Switch
                key={c.column}
                title={c.title}
                detail={c.detail}
                checked={prefs.data?.[c.column] ?? true}
                disabled={!prefs.data}
                last={i === g.items.length - 1}
                onChange={(on) => toggle.mutate({ column: c.column, on })}
              />
            ))}
          </Group>
        ))}

        <Group title="Appearance" footer="Kept in this browser.">
          <Choice
            label="Theme"
            value={appearance}
            options={[
              ["system", "System"],
              ["light", "Light"],
              ["dark", "Dark"],
            ]}
            onChange={(a) => {
              setAppearance(a);
              writeAppearance(a);
            }}
          />
        </Group>

        <Group title="Account">
          <button
            type="button"
            onClick={out}
            disabled={busy}
            className="h-[50px] w-full border-b border-[var(--sf-separator)] px-4 text-left text-[17px] text-[var(--sf-primary)] disabled:opacity-50"
          >
            Sign Out
          </button>
          <button
            type="button"
            onClick={() => setConfirming(true)}
            disabled={busy}
            className="h-[50px] w-full px-4 text-left text-[17px] text-[var(--sf-very-late)] disabled:opacity-50"
          >
            Delete Account
          </button>
        </Group>

        {message && (
          <p role="alert" className="px-1 pt-2 text-[13px] text-[var(--sf-very-late)]">
            {message}
          </p>
        )}
      </div>
      {confirming && <Confirm onCancel={() => setConfirming(false)} onConfirm={() => void remove()} />}
    </CardFrame>
  );
}

function Email() {
  const { session } = useSession();
  return <span className="text-[17px] text-[var(--sf-primary)]">{session?.user.email ?? ""}</span>;
}

function Group({ title, footer, children }: { title: string; footer?: string; children: ReactNode }) {
  return (
    <section aria-label={title} className="pt-4">
      <h2 className="px-4 pb-1.5 text-[13px] text-[var(--sf-secondary)] uppercase">{title}</h2>
      <div className="overflow-hidden rounded-[14px] bg-[var(--sf-card)]">{children}</div>
      {footer && <p className="px-4 pt-1.5 text-[13px] text-[var(--sf-secondary)]">{footer}</p>}
    </section>
  );
}

/** One choice among a few, as a radio group of pills. */
function Choice<T extends string>({
  label,
  value,
  options,
  onChange,
}: {
  label: string;
  value: T;
  options: [T, string][];
  onChange: (v: T) => void;
}) {
  return (
    <div className="flex flex-col gap-2 px-4 py-3">
      <span className="text-[13px] text-[var(--sf-secondary)]">{label}</span>
      <div role="radiogroup" aria-label={label} className="flex flex-wrap gap-2">
        {options.map(([v, text]) => (
          <button
            key={v}
            type="button"
            role="radio"
            aria-checked={v === value}
            onClick={() => onChange(v)}
            className={`rounded-full px-4 py-2 text-[15px] font-medium ${
              v === value ? "bg-[var(--sf-accent)] text-white" : "bg-[var(--sf-pill)] text-[var(--sf-primary)]"
            }`}
          >
            {text}
          </button>
        ))}
      </div>
    </div>
  );
}

function Switch({
  title,
  detail,
  checked,
  disabled,
  last,
  onChange,
}: {
  title: string;
  detail: string;
  checked: boolean;
  disabled: boolean;
  last: boolean;
  onChange: (on: boolean) => void;
}) {
  return (
    <div className={`flex items-center gap-3 px-4 py-3 ${last ? "" : "border-b border-[var(--sf-separator)]"}`}>
      <div className="min-w-0 flex-1">
        <p className="text-[17px] text-[var(--sf-primary)]">{title}</p>
        <p className="text-[13px] text-[var(--sf-secondary)]">{detail}</p>
      </div>
      <button
        type="button"
        role="switch"
        aria-checked={checked}
        aria-label={`${title}. ${detail}`}
        disabled={disabled}
        onClick={() => onChange(!checked)}
        className={`relative h-[31px] w-[51px] shrink-0 rounded-full transition-colors disabled:opacity-50 ${
          checked ? "bg-[var(--sf-accent)]" : "bg-[var(--sf-tick-off)]"
        }`}
      >
        <span
          aria-hidden
          className={`absolute top-[2px] left-[2px] size-[27px] rounded-full bg-white shadow transition-transform ${
            checked ? "translate-x-5" : ""
          }`}
        />
      </button>
    </div>
  );
}

/** The deletion's confirmation, with the app's copy. Cancel has focus. */
function Confirm({ onCancel, onConfirm }: { onCancel: () => void; onConfirm: () => void }) {
  useEffect(() => {
    const key = (e: KeyboardEvent) => e.key === "Escape" && onCancel();
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [onCancel]);
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-6">
      <div
        role="alertdialog"
        aria-modal="true"
        aria-labelledby="delete-title"
        aria-describedby="delete-message"
        className="w-full max-w-[320px] rounded-[20px] bg-[var(--sf-card)] p-5 text-center"
      >
        <h2 id="delete-title" className="text-[17px] font-semibold text-[var(--sf-primary)]">
          {DELETE_TITLE}
        </h2>
        <p id="delete-message" className="pt-1.5 pb-4 text-[15px] text-[var(--sf-secondary)]">
          {DELETE_MESSAGE}
        </p>
        <div className="flex flex-col gap-2">
          <button
            type="button"
            onClick={onConfirm}
            className="h-11 rounded-full bg-[var(--sf-very-late)] text-[17px] font-semibold text-white"
          >
            Delete Account
          </button>
          <button
            type="button"
            autoFocus
            onClick={onCancel}
            className="h-11 rounded-full bg-[var(--sf-pill)] text-[17px] font-semibold text-[var(--sf-primary)]"
          >
            Cancel
          </button>
        </div>
      </div>
    </div>
  );
}

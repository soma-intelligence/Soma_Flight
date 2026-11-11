import { useState } from "react";
import { useNavigate } from "react-router";
import { signOut } from "@/app/session";
import { CardFrame } from "../placeholder";

/** Placeholder until the Settings task, with a working Sign Out. */
export function Settings() {
  const navigate = useNavigate();
  const [busy, setBusy] = useState(false);
  async function out() {
    setBusy(true);
    try {
      await signOut();
    } catch {
      /* no session to end (development fakes): going home is enough */
    }
    setBusy(false);
    navigate("/", { replace: true });
  }
  return (
    <CardFrame title="Settings" testId="settings-card">
      <div className="px-4 pt-2">
        <button
          type="button"
          onClick={out}
          disabled={busy}
          className="h-[50px] w-full rounded-[14px] bg-[var(--sf-card)] text-[17px] text-[var(--sf-very-late)] disabled:opacity-50"
        >
          Sign Out
        </button>
      </div>
    </CardFrame>
  );
}

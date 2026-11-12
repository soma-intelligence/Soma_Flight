import { useState } from "react";
import { useNavigate } from "react-router";
import { signOut } from "@/app/session";
import { useFakes } from "@/data/flights";
import { CardFrame } from "../placeholder";

/** Placeholder until the Settings task, with a working Sign Out. */
export function Settings() {
  const navigate = useNavigate();
  const fakes = useFakes();
  const [busy, setBusy] = useState(false);
  const [failed, setFailed] = useState(false);
  async function out() {
    setBusy(true);
    setFailed(false);
    try {
      await signOut();
    } catch (e) {
      // Development fakes have no session to end; anywhere else the failure shows.
      if (!fakes) {
        console.error(e);
        setBusy(false);
        setFailed(true);
        return;
      }
    }
    setBusy(false);
    navigate("/", { replace: true });
  }
  return (
    <CardFrame title="Settings" testId="settings-card">
      <div className="flex flex-col gap-2 px-4 pt-2">
        <button
          type="button"
          onClick={out}
          disabled={busy}
          className="h-[50px] w-full rounded-[14px] bg-[var(--sf-card)] text-[17px] text-[var(--sf-very-late)] disabled:opacity-50"
        >
          Sign Out
        </button>
        {failed && (
          <p role="alert" className="px-1 text-[13px] text-[var(--sf-very-late)]">
            That did not work. Try again.
          </p>
        )}
      </div>
    </CardFrame>
  );
}

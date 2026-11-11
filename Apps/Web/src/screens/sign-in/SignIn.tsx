import { useState, type FormEvent } from "react";
import { getSupabase } from "@/data/client";

type State = { kind: "idle" } | { kind: "sending" } | { kind: "sent"; address: string } | { kind: "failed" };

const VALID = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

/** Sign in by email link. `notice` shows a line above the form (an expired link, say). */
export function SignIn({ notice }: { notice?: string }) {
  const [email, setEmail] = useState("");
  const [state, setState] = useState<State>({ kind: "idle" });
  const address = email.trim();
  const canSend = VALID.test(address) && state.kind !== "sending";

  async function send(e: FormEvent) {
    e.preventDefault();
    if (!canSend) return;
    setState({ kind: "sending" });
    try {
      const { error } = await getSupabase().auth.signInWithOtp({
        email: address,
        options: { emailRedirectTo: `${window.location.origin}/auth/callback` },
      });
      setState(error ? { kind: "failed" } : { kind: "sent", address });
    } catch {
      setState({ kind: "failed" });
    }
  }

  return (
    <main className="mx-auto flex min-h-screen max-w-[480px] flex-col justify-center gap-6 px-5 py-10 text-center">
      <header className="flex flex-col gap-3">
        <h1 className="text-[34px] font-bold text-[var(--sf-primary)]">Soma Flight</h1>
        <p className="text-[17px] text-[var(--sf-secondary)]">
          Live status for the flights you follow, delays explained, and a record of everywhere you've flown.
        </p>
      </header>
      {notice && (
        <p role="alert" className="text-[15px] text-[var(--sf-very-late)]">
          {notice}
        </p>
      )}
      {state.kind === "sent" ? (
        <section className="flex flex-col gap-2 rounded-[14px] bg-[var(--sf-pill)] p-4">
          <h2 className="text-[17px] font-semibold text-[var(--sf-primary)]">Check your email</h2>
          <p className="text-[15px] text-[var(--sf-secondary)]">
            We sent a sign-in link to {state.address}. Open it on this device.
          </p>
          <button
            type="button"
            className="text-[15px] font-semibold text-[var(--sf-accent)]"
            onClick={() => setState({ kind: "idle" })}
          >
            Use a different email
          </button>
        </section>
      ) : (
        <form onSubmit={send} className="flex flex-col gap-3">
          <input
            type="email"
            autoComplete="email"
            aria-label="Email address"
            placeholder="Email address"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            className="h-[54px] rounded-[14px] bg-[var(--sf-pill)] px-3.5 text-[17px] text-[var(--sf-primary)] placeholder:text-[var(--sf-secondary)]"
          />
          {state.kind === "failed" && (
            <p role="alert" className="text-left text-[13px] text-[var(--sf-very-late)]">
              The link didn't go out. Check the address and try again.
            </p>
          )}
          <button
            type="submit"
            disabled={!canSend}
            className="h-[54px] rounded-[14px] bg-[var(--sf-accent)] text-[17px] font-semibold text-white disabled:bg-[var(--sf-pill)] disabled:text-[var(--sf-secondary)]"
          >
            Email Me a Sign-In Link
          </button>
          <p className="text-[13px] text-[var(--sf-secondary)]">We only use your email to sign you in.</p>
        </form>
      )}
    </main>
  );
}

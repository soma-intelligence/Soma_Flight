import { useEffect, useState } from "react";
import type { QueryClient } from "@tanstack/react-query";
import type { Session, SupabaseClient } from "@supabase/supabase-js";
import { getSupabase } from "@/data/client";

export type SessionState = { session: Session | null; loading: boolean };

/** The current Supabase session. `loading` is true until the stored session has been read. */
export function useSession(): SessionState {
  const [state, setState] = useState<SessionState>({ session: null, loading: true });
  useEffect(() => {
    const auth = getSupabase().auth;
    let live = true;
    void auth.getSession().then(({ data }) => {
      if (live) setState({ session: data.session, loading: false });
    });
    const { data } = auth.onAuthStateChange((_event, session) => {
      if (live) setState({ session, loading: false });
    });
    return () => {
      live = false;
      data.subscription.unsubscribe();
    };
  }, []);
  return state;
}

/**
 * The one place the cache is emptied: on SIGNED_OUT (Sign Out, account deletion, a session ended in
 * another tab), every cached query goes, so the next account never sees the last one's flights.
 * Returns the unsubscribe.
 */
export function clearCacheOnSignOut(
  queryClient: QueryClient,
  auth: Pick<SupabaseClient["auth"], "onAuthStateChange"> = getSupabase().auth,
): () => void {
  const { data } = auth.onAuthStateChange((event) => {
    if (event === "SIGNED_OUT") queryClient.clear();
  });
  return () => data.subscription.unsubscribe();
}

export async function signOut(): Promise<void> {
  await getSupabase().auth.signOut();
}

/** Where AuthGate saved the wanted path before sending a visitor to sign in. */
export const RETURN_KEY = "sf.return";

export function saveReturn(path: string): void {
  try {
    sessionStorage.setItem(RETURN_KEY, path);
  } catch {
    /* storage blocked: the visitor lands on the home screen instead */
  }
}

/** Takes the saved path (once). Only same-origin absolute paths are honoured. */
export function takeReturn(): string {
  let path: string | null = null;
  try {
    path = sessionStorage.getItem(RETURN_KEY);
    sessionStorage.removeItem(RETURN_KEY);
  } catch {
    /* ignore */
  }
  return path && path.startsWith("/") && !path.startsWith("//") ? path : "/";
}

import { useEffect, useState } from "react";
import { useNavigate, useSearchParams } from "react-router";
import { getSupabase } from "@/data/client";
import { SignIn } from "@/screens/sign-in/SignIn";
import { takeReturn } from "./session";

export const EXPIRED = "This link has expired. Send a new one.";

/**
 * The email link lands here with `?code=`. A missing code, or one that cannot be exchanged (expired, or
 * opened where the PKCE verifier is gone), shows the sign-in form with the expired line. A `#access_token`
 * fragment is ignored, as the apps do.
 */
export function AuthCallback() {
  const [params] = useSearchParams();
  const navigate = useNavigate();
  const code = params.get("code");
  const [failed, setFailed] = useState(!code);

  useEffect(() => {
    if (!code) return;
    let live = true;
    void (async () => {
      const auth = getSupabase().auth;
      let ok = false;
      try {
        const { error } = await auth.exchangeCodeForSession(code);
        // The client may already have exchanged this code on load; a stored session is success.
        ok = !error || !!(await auth.getSession()).data.session;
      } catch {
        ok = false;
      }
      if (!live) return;
      if (ok) navigate(takeReturn(), { replace: true });
      else setFailed(true);
    })();
    return () => {
      live = false;
    };
  }, [code, navigate]);

  if (failed) return <SignIn notice={EXPIRED} />;
  return <p role="status">Signing in</p>;
}

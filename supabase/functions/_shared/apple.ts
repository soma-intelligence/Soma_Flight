// Sign in with Apple token revocation, required by App Review when an account is deleted. The app sends
// a fresh authorization code from Apple at deletion; it is exchanged for a refresh token, which is then
// revoked (https://developer.apple.com/documentation/sign_in_with_apple/revoke_tokens). Nothing from
// Apple is stored.
import { importPKCS8, SignJWT } from "npm:jose@5";
import { ApiError } from "./errors.ts";

export const APPLE_ID_HOST = "https://appleid.apple.com";
/** Apple accepts a client secret valid for up to six months; five minutes is all one deletion needs. */
const SECRET_TTL_S = 5 * 60;

export interface AppleConfig {
  teamId: string;
  keyId: string;
  /** The Sign in with Apple key (.p8), PKCS#8 PEM. */
  privateKey: string;
  /** The app's bundle id: the client the authorization code was issued to. */
  clientId: string;
}

/** Revokes the user's Apple tokens from an authorization code the app just got from Apple. */
export interface AppleRevoker {
  revoke(authorizationCode: string): Promise<void>;
}

/** The config from the function's secrets, or null when any is missing. */
export function appleConfigFromEnv(
  env: (name: string) => string | undefined = (n) => Deno.env.get(n),
): AppleConfig | null {
  const teamId = env("APPLE_TEAM_ID");
  const keyId = env("APPLE_SIGNIN_KEY_ID");
  const privateKey = env("APPLE_SIGNIN_PRIVATE_KEY");
  const clientId = env("APPLE_CLIENT_ID") || "me.somalabs.flight";
  if (!teamId || !keyId || !privateKey) return null;
  return {
    teamId,
    keyId,
    privateKey: privateKey.replaceAll("\\n", "\n"),
    clientId,
  };
}

/** The client secret: an ES256 JWT signed with the Sign in with Apple key. `now` is in seconds. */
export async function appleClientSecret(
  c: AppleConfig,
  now: number,
): Promise<string> {
  const key = await importPKCS8(c.privateKey, "ES256");
  return await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: c.keyId })
    .setIssuer(c.teamId)
    .setIssuedAt(now)
    .setExpirationTime(now + SECRET_TTL_S)
    .setAudience(APPLE_ID_HOST)
    .setSubject(c.clientId)
    .sign(key);
}

export function appleRevoker(
  c: AppleConfig,
  fetcher: typeof fetch = fetch,
  clock: () => number = () => Math.floor(Date.now() / 1000),
): AppleRevoker {
  return {
    async revoke(code: string): Promise<void> {
      const secret = await appleClientSecret(c, clock());
      const form = (fields: Record<string, string>) =>
        new URLSearchParams({
          client_id: c.clientId,
          client_secret: secret,
          ...fields,
        });

      const tokenRes = await fetcher(`${APPLE_ID_HOST}/auth/token`, {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: form({ grant_type: "authorization_code", code }),
      });
      const body = await tokenRes.json().catch(() => ({})) as Record<
        string,
        unknown
      >;
      if (!tokenRes.ok) {
        // invalid_grant: the code expired (five minutes), was used already or belongs to another app.
        if (body.error === "invalid_grant") {
          throw new ApiError(
            "invalid_request",
            400,
            "Apple sign-in expired. Try again.",
          );
        }
        console.error(
          "apple token exchange failed",
          tokenRes.status,
          body.error,
        );
        throw new ApiError(
          "provider_unavailable",
          502,
          "Apple didn't answer. Try again.",
        );
      }
      const refresh = typeof body.refresh_token === "string"
        ? body.refresh_token
        : null;
      const access = typeof body.access_token === "string"
        ? body.access_token
        : null;
      const token = refresh ?? access;
      if (!token) {
        throw new ApiError(
          "provider_unavailable",
          502,
          "Apple didn't answer. Try again.",
        );
      }

      const revokeRes = await fetcher(`${APPLE_ID_HOST}/auth/revoke`, {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: form({
          token,
          token_type_hint: refresh ? "refresh_token" : "access_token",
        }),
      });
      if (!revokeRes.ok) {
        console.error("apple revoke failed", revokeRes.status);
        throw new ApiError(
          "provider_unavailable",
          502,
          "Apple didn't answer. Try again.",
        );
      }
    },
  };
}

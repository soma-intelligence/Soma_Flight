// GET /mapkit-token -> { token, expiresAt }
// A short-lived MapKit JS token (ES256 JWT signed with the Apple Maps key) for the web app's globe.
// Needs the user JWT, rate limited to 30 per hour per user. When the request carries an Origin it
// must be one of WEB_ORIGINS, and the token is bound to it (the `origin` claim), so a token is
// never minted for another site.
import { importPKCS8, SignJWT } from "npm:jose@5";
import { requireUser, type TokenVerifier } from "../_shared/auth.ts";
import { webOrigins } from "../_shared/cors.ts";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";
import type { checkRate } from "../_shared/limits.ts";

export const TOKEN_TTL_SECONDS = 1800;

export interface MapkitSecrets {
  keyId: string;
  teamId: string;
  privateKey: string;
}

export interface Deps {
  verify: TokenVerifier;
  rate: typeof checkRate;
  now: () => Date;
  secrets: MapkitSecrets | null;
}

export async function handler(req: Request, deps: Deps): Promise<Response> {
  try {
    if (req.method !== "GET") {
      throw new ApiError("invalid_request", 400, "Use GET");
    }
    const { userId } = await requireUser(req, deps.verify);
    await deps.rate(userId, "mapkit-token", 30, 60);
    const origin = req.headers.get("origin");
    if (origin !== null && !webOrigins().includes(origin)) {
      throw new ApiError("invalid_request", 400, "Origin not allowed");
    }
    const { secrets } = deps;
    if (!secrets) {
      console.error("mapkit-token: MapKit secrets are not configured");
      throw new ApiError(
        "provider_unavailable",
        503,
        "MapKit is not configured",
      );
    }
    const iat = Math.floor(deps.now().getTime() / 1000);
    const exp = iat + TOKEN_TTL_SECONDS;
    const key = await importPKCS8(secrets.privateKey, "ES256");
    const token = await new SignJWT(origin === null ? {} : { origin })
      .setProtectedHeader({ alg: "ES256", kid: secrets.keyId, typ: "JWT" })
      .setIssuer(secrets.teamId)
      .setIssuedAt(iat)
      .setExpirationTime(exp)
      .sign(key);
    return json({ token, expiresAt: new Date(exp * 1000).toISOString() });
  } catch (e) {
    return errorResponse(e);
  }
}

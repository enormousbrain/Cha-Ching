import { createRemoteJWKSet, importPKCS8, jwtVerify, SignJWT } from "https://esm.sh/jose@5.9.6";

const appleKeys = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"));

// Native sign-in does not persist an Apple refresh token. Exchange a fresh code at deletion.
export async function revokeAppleSignIn(code: string | undefined, subject: string | undefined): Promise<boolean> {
  const key = Deno.env.get("APPLE_SIGN_IN_PRIVATE_KEY");
  const keyID = Deno.env.get("APPLE_SIGN_IN_KEY_ID");
  const teamID = Deno.env.get("APPLE_SIGN_IN_TEAM_ID");
  const clientID = Deno.env.get("APPLE_SIGN_IN_CLIENT_ID");
  if (!code || !subject || !key || !keyID || !teamID || !clientID) return false;
  try {
    const secret = await new SignJWT({}).setProtectedHeader({ alg: "ES256", kid: keyID })
      .setIssuer(teamID).setSubject(clientID).setAudience("https://appleid.apple.com")
      .setIssuedAt().setExpirationTime("5m")
      .sign(await importPKCS8(key.replace(/\\n/g, "\n"), "ES256"));
    const tokenResponse = await fetch("https://appleid.apple.com/auth/token", {
      method: "POST", signal: AbortSignal.timeout(10000),
      body: new URLSearchParams({ client_id: clientID, client_secret: secret, code, grant_type: "authorization_code" }),
    });
    if (!tokenResponse.ok) return false;
    const tokens = await tokenResponse.json();
    const { payload } = await jwtVerify(tokens.id_token, appleKeys, { issuer: "https://appleid.apple.com", audience: clientID });
    if (payload.sub !== subject || !tokens.refresh_token) return false;
    const result = await fetch("https://appleid.apple.com/auth/revoke", {
      method: "POST", signal: AbortSignal.timeout(10000),
      body: new URLSearchParams({ client_id: clientID, client_secret: secret, token: tokens.refresh_token, token_type_hint: "refresh_token" }),
    });
    return result.ok;
  } catch {
    return false;
  }
}

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { drainPrivacyCleanup } from "../_shared/privacy-cleanup.ts";
import { revokeAppleSignIn } from "../_shared/apple-revocation.ts";

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const token = request.headers.get("Authorization")?.replace(/^Bearer\s+/i, "");
  if (!token) return json({ error: "authentication_required" }, 401);
  const client = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });
  const { data: { user }, error } = await client.auth.getUser(token);
  if (error || !user) return json({ error: "authentication_required" }, 401);
  const body = await request.json().catch(() => null);
  if (body?.confirmation !== "DELETE") return json({ error: "confirmation_required" }, 400);
  const appleIdentity = user.identities?.find((identity) => identity.provider === "apple");
  const appleRevoked = appleIdentity ? await revokeAppleSignIn(
    typeof body.appleAuthorizationCode === "string" ? body.appleAuthorizationCode : undefined,
    appleIdentity.identity_data?.sub,
  ) : true;

  const { error: prepareError } = await client.rpc("prepare_account_deletion", { target_user_id: user.id });
  if (prepareError) {
    console.error("Account deletion preparation failed", prepareError.code);
    return json({ error: "deletion_failed_try_again" }, 500);
  }
  // Memberships and child linkage are already gone. Revoke refresh tokens too.
  await client.auth.admin.signOut(token, "global");
  await client.auth.admin.updateUserById(user.id, { ban_duration: "876000h" });
  try {
    await drainPrivacyCleanup(client);
  } catch {
    // The scheduled worker resumes the durable request; the user need not retry.
    console.error("Account deletion queued for retry");
  }
  return json({ accepted: true, appleRevoked });
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

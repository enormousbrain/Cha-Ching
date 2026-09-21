import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { importPKCS8, SignJWT } from "npm:jose";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const functionSecret = Deno.env.get("PARENT_ALERTS_FUNCTION_SECRET");
const apnsKey = Deno.env.get("APNS_KEY_P8");
const apnsKeyId = Deno.env.get("APNS_KEY_ID");
const teamId = Deno.env.get("APNS_TEAM_ID");
const bundleId = Deno.env.get("APNS_BUNDLE_ID") ?? "com.artofsullivan.chaching";

const db = createClient(supabaseUrl, serviceKey);

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

async function providerToken() {
  if (!apnsKey || !apnsKeyId || !teamId) throw new Error("APNs secrets are incomplete");
  const pem = apnsKey.replace(/\\n/g, "\n");
  const key = await importPKCS8(pem, "ES256");
  return new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: apnsKeyId })
    .setIssuer(teamId)
    .setIssuedAt()
    .sign(key);
}

async function send(token: string, environment: string, title: string, body: string, occurrenceId: string) {
  const host = environment === "sandbox" ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
  const jwt = await providerToken();
  return fetch(`${host}/3/device/${token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": bundleId,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      aps: { alert: { title, body }, sound: "default" },
      kind: "parent_overdue_alert",
      task_occurrence_id: occurrenceId,
    }),
  });
}

Deno.serve(async (request) => {
  if (functionSecret && request.headers.get("x-function-secret") !== functionSecret) return json({ error: "unauthorized" }, 401);
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  try {
    await db.rpc("queue_parent_overdue_alerts");
    const { data: alerts, error } = await db
      .from("parent_overdue_alerts")
      .select("id, family_id, message, task_occurrence_id, chore_definitions(title)")
      .eq("status", "pending")
      .order("created_at")
      .limit(100);
    if (error) throw error;

    let sent = 0;
    for (const alert of alerts ?? []) {
      const { data: members, error: memberError } = await db
        .from("family_members")
        .select("user_id")
        .eq("family_id", alert.family_id)
        .eq("role", "parent");
      if (memberError) throw memberError;
      const parentIds = (members ?? []).map((member) => member.user_id);
      const { data: devices, error: deviceError } = await db
        .from("apns_device_tokens")
        .select("id, token, environment")
        .in("user_id", parentIds);
      if (deviceError) throw deviceError;

      let delivered = false;
      for (const device of devices ?? []) {
        const chore = Array.isArray(alert.chore_definitions) ? alert.chore_definitions[0] : alert.chore_definitions;
        const response = await send(device.token, device.environment, "Chore alert", `${chore?.title ?? "A chore"}: ${alert.message}`, alert.task_occurrence_id);
        if (response.ok) delivered = true;
        if (response.status === 400 || response.status === 410) await db.from("apns_device_tokens").delete().eq("id", device.id);
      }
      if (delivered) {
        await db.from("parent_overdue_alerts").update({ status: "sent", sent_at: new Date().toISOString() }).eq("id", alert.id);
        sent++;
      }
    }
    return json({ processed: alerts?.length ?? 0, sent });
  } catch (error) {
    console.error(error);
    return json({ error: String(error) }, 500);
  }
});

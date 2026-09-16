import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  deleteSubmissionEvidence,
  EvidenceDeletionError,
  loadSubmissionFamilyId,
} from "../_shared/evidence-deletion.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type DeleteRequest = {
  submission_id?: string;
};

Deno.serve(async (request) => {
  try {
    return await handleRequest(request);
  } catch (error) {
    if (error instanceof EvidenceDeletionError) {
      return json({ error: error.code }, error.status);
    }

    console.error(error);
    return json({ error: "evidence_delete_failed" }, 500);
  }
});

async function handleRequest(request: Request): Promise<Response> {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (request.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const authHeader = request.headers.get("Authorization");
  if (!authHeader) {
    return json({ error: "missing_authorization" }, 401);
  }

  const body = await request.json().catch(() => null) as DeleteRequest | null;
  const submissionId = body?.submission_id?.trim();
  if (!submissionId) {
    return json({ error: "missing_submission_id" }, 400);
  }

  const supabaseUrl = getEnv("SUPABASE_URL");
  const anonKey = getEnv("SUPABASE_ANON_KEY");
  const serviceRoleKey = getEnv("SUPABASE_SERVICE_ROLE_KEY");
  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData.user) {
    return json({ error: "invalid_authorization" }, 401);
  }

  const serviceClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });
  const familyId = await loadSubmissionFamilyId(serviceClient, submissionId);
  const { data: membership, error: membershipError } = await serviceClient
    .from("family_members")
    .select("role")
    .eq("family_id", familyId)
    .eq("user_id", userData.user.id)
    .maybeSingle();

  if (membershipError) {
    console.error(membershipError);
    return json({ error: "membership_lookup_failed" }, 500);
  }
  if (membership?.role !== "parent") {
    return json({ error: "not_family_parent" }, 403);
  }

  const result = await deleteSubmissionEvidence(serviceClient, submissionId);
  return json({
    submission_id: result.submissionId,
    deleted_object_count: result.deletedObjectCount,
    already_deleted: result.alreadyDeleted,
    deleted_at: result.deletedAt,
  });
}

function getEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing ${name}`);
  return value;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
    },
  });
}

import {
  createClient,
  type SupabaseClient,
} from "https://esm.sh/@supabase/supabase-js@2";
import {
  deleteSubmissionEvidence,
  EvidenceDeletionError,
} from "../_shared/evidence-deletion.ts";
import { drainPrivacyCleanup } from "../_shared/privacy-cleanup.ts";

const defaultBatchSize = 25;
const maxBatchSize = 100;

// deno-lint-ignore no-explicit-any
type SupabaseClientLike = SupabaseClient<any, "public", "public", any, any>;

Deno.serve(async (request) => {
  try {
    return await handleRequest(request);
  } catch (error) {
    console.error(error);
    return json({ error: "retention_cleanup_failed" }, 500);
  }
});

async function handleRequest(request: Request): Promise<Response> {
  if (request.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const suppliedSecret = request.headers.get("x-cleanup-secret") ?? "";
  const cleanupSecret = getEnv("EVIDENCE_CLEANUP_SECRET");
  if (!(await secretsMatch(suppliedSecret, cleanupSecret))) {
    return json({ error: "invalid_cleanup_secret" }, 401);
  }

  const now = new Date();
  const serviceClient = createClient(
    getEnv("SUPABASE_URL"),
    getEnv("SUPABASE_SERVICE_ROLE_KEY"),
    { auth: { persistSession: false } },
  );
  const batchSize = parseBatchSize(Deno.env.get("EVIDENCE_CLEANUP_BATCH_SIZE"));
  const { error: orphanError } = await serviceClient.rpc("queue_orphaned_evidence", { batch_size: batchSize });
  if (orphanError) throw new Error("orphan_evidence_lookup_failed");
  const privacyCleanup = await drainPrivacyCleanup(serviceClient, batchSize);
  const { data: dueSubmissions, error: dueError } = await serviceClient
    .from("chore_submissions")
    .select("id")
    .eq("evidence_status", "pending_delete")
    .lte("evidence_delete_after", now.toISOString())
    .order("evidence_delete_after", { ascending: true })
    .limit(batchSize);

  if (dueError) {
    console.error(dueError);
    return json({ error: "due_evidence_lookup_failed" }, 500);
  }

  const deletedSubmissionIds: string[] = [];
  const failedSubmissions: Array<{ id: string; error: string }> = [];
  for (const submission of dueSubmissions ?? []) {
    try {
      await deleteSubmissionEvidence(serviceClient, submission.id, now);
      deletedSubmissionIds.push(submission.id);
    } catch (error) {
      const code = error instanceof EvidenceDeletionError
        ? error.code
        : "unexpected_delete_failure";
      console.error(`Evidence cleanup failed for ${submission.id}: ${code}`);
      failedSubmissions.push({ id: submission.id, error: code });
    }
  }

  const expiredChildInvites = await expireInvites(
    serviceClient,
    "child_invites",
    now,
  );
  const expiredParentInvites = await expireInvites(
    serviceClient,
    "parent_invites",
    now,
  );

  const response = {
    privacy_cleanup: privacyCleanup,
    attempted_evidence_count: dueSubmissions?.length ?? 0,
    deleted_evidence_count: deletedSubmissionIds.length,
    deleted_submission_ids: deletedSubmissionIds,
    failed_submissions: failedSubmissions,
    expired_child_invite_count: expiredChildInvites,
    expired_parent_invite_count: expiredParentInvites,
    more_evidence_may_be_due: (dueSubmissions?.length ?? 0) === batchSize,
  };

  return json(response, failedSubmissions.length > 0 || privacyCleanup.failedEvidence > 0 ? 500 : 200);
}

async function expireInvites(
  client: SupabaseClientLike,
  table: "child_invites" | "parent_invites",
  now: Date,
): Promise<number> {
  const { data, error } = await client
    .from(table)
    .update({ status: "expired", token_hash: null })
    .eq("status", "pending")
    .lt("expires_at", now.toISOString())
    .select("id");

  if (error) {
    console.error(error);
    throw new Error(`${table}_expiration_failed`);
  }

  return data?.length ?? 0;
}

function parseBatchSize(value: string | undefined): number {
  const parsed = Number.parseInt(value ?? "", 10);
  if (!Number.isFinite(parsed) || parsed < 1) return defaultBatchSize;
  return Math.min(parsed, maxBatchSize);
}

async function secretsMatch(left: string, right: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const [leftHash, rightHash] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(left)),
    crypto.subtle.digest("SHA-256", encoder.encode(right)),
  ]);
  const leftBytes = new Uint8Array(leftHash);
  const rightBytes = new Uint8Array(rightHash);
  let difference = 0;
  for (let index = 0; index < leftBytes.length; index += 1) {
    difference |= leftBytes[index] ^ rightBytes[index];
  }
  return difference === 0 && left.length === right.length;
}

function getEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing ${name}`);
  return value;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

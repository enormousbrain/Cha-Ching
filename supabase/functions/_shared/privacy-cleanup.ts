import { type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

// Durable queue entries are removed only after Storage confirms deletion.
export async function drainPrivacyCleanup(client: SupabaseClient, limit = 100) {
  const { data: paths, error } = await client.from("evidence_removal_queue")
    .select("path").order("attempted_at", { nullsFirst: true }).order("queued_at").limit(limit);
  if (error) throw new Error("privacy_queue_lookup_failed");
  let removed = 0;
  for (const { path } of paths ?? []) {
    const { error: attemptError } = await client.from("evidence_removal_queue")
      .update({ attempted_at: new Date().toISOString() }).eq("path", path);
    if (attemptError) continue;
    const { error: storageError } = await client.storage.from("chore-evidence").remove([path]);
    if (storageError) continue;
    // An uploaded object can outlive its author in a retained family.
    const { error: imageError } = await client.from("chore_submissions").update({
      image_path: null, thumbnail_path: null, evidence_status: "deleted",
      evidence_deleted_at: new Date().toISOString(), evidence_delete_reason: "account_deletion",
    }).eq("image_path", path);
    const { error: thumbError } = await client.from("chore_submissions")
      .update({ thumbnail_path: null }).eq("thumbnail_path", path);
    if (imageError || thumbError) continue;
    const { error: queueError } = await client.from("evidence_removal_queue").delete().eq("path", path);
    if (!queueError) removed += 1;
  }
  const { data: requests, error: requestError } = await client.from("account_deletion_requests")
    .select("user_id").order("attempted_at", { nullsFirst: true }).order("requested_at").limit(25);
  if (requestError) throw new Error("account_deletion_lookup_failed");
  let deletedAccounts = 0;
  for (const { user_id } of requests ?? []) {
    await client.from("account_deletion_requests").update({ attempted_at: new Date().toISOString() }).eq("user_id", user_id);
    const { count, error: pendingError } = await client.from("evidence_removal_queue")
      .select("path", { count: "exact", head: true }).eq("deletion_user_id", user_id);
    if (pendingError || count !== 0) continue;
    const { error: deletionError } = await client.auth.admin.deleteUser(user_id);
    if (deletionError && deletionError.code !== "user_not_found") continue;
    const { error: completionError } = await client.from("account_deletion_requests").delete().eq("user_id", user_id);
    if (!completionError) deletedAccounts += 1;
  }
  return { removed, deletedAccounts, failedEvidence: (paths?.length ?? 0) - removed };
}

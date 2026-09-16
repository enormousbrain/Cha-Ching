import { type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  evidencePathsForFamily,
  isEvidenceDeletionDue,
} from "./evidence-deletion-policy.ts";

const evidenceBucket = "chore-evidence";

// deno-lint-ignore no-explicit-any
type SupabaseClientLike = SupabaseClient<any, "public", "public", any, any>;

type ChoreSubmission = {
  id: string;
  task_occurrence_id: string;
  image_path: string | null;
  thumbnail_path: string | null;
  evidence_status: string;
  evidence_delete_after: string | null;
  evidence_deleted_at: string | null;
};

type TaskOccurrence = {
  id: string;
  week_id: string;
};

type Week = {
  id: string;
  family_id: string;
};

export type EvidenceDeletionResult = {
  submissionId: string;
  familyId: string;
  deletedObjectCount: number;
  alreadyDeleted: boolean;
  deletedAt: string | null;
};

export class EvidenceDeletionError extends Error {
  constructor(
    public readonly code: string,
    public readonly status: number,
  ) {
    super(code);
  }
}

export async function loadSubmissionFamilyId(
  client: SupabaseClientLike,
  submissionId: string,
): Promise<string> {
  const submission = await loadSubmission(client, submissionId);
  if (!submission) {
    throw new EvidenceDeletionError("submission_not_found", 404);
  }

  return await loadFamilyId(client, submission.task_occurrence_id);
}

export async function deleteSubmissionEvidence(
  client: SupabaseClientLike,
  submissionId: string,
  now = new Date(),
): Promise<EvidenceDeletionResult> {
  const submission = await loadSubmission(client, submissionId);
  if (!submission) {
    throw new EvidenceDeletionError("submission_not_found", 404);
  }

  const familyId = await loadFamilyId(client, submission.task_occurrence_id);

  if (submission.evidence_status === "deleted") {
    return {
      submissionId,
      familyId,
      deletedObjectCount: 0,
      alreadyDeleted: true,
      deletedAt: submission.evidence_deleted_at,
    };
  }

  if (
    !isEvidenceDeletionDue(
      submission.evidence_status,
      submission.evidence_delete_after,
      now,
    )
  ) {
    throw new EvidenceDeletionError("evidence_deletion_not_due", 409);
  }

  let paths: string[];
  try {
    paths = evidencePathsForFamily(
      familyId,
      submission.image_path,
      submission.thumbnail_path,
    );
  } catch {
    throw new EvidenceDeletionError("evidence_path_family_mismatch", 409);
  }

  if (paths.length > 0) {
    const { error: storageError } = await client.storage
      .from(evidenceBucket)
      .remove(paths);

    if (storageError) {
      console.error(storageError);
      throw new EvidenceDeletionError("evidence_storage_delete_failed", 502);
    }
  }

  const deletedAt = now.toISOString();
  const { error: updateError } = await client
    .from("chore_submissions")
    .update({
      image_path: null,
      thumbnail_path: null,
      evidence_status: "deleted",
      evidence_deleted_at: deletedAt,
    })
    .eq("id", submissionId);

  if (updateError) {
    console.error(updateError);
    throw new EvidenceDeletionError("evidence_audit_update_failed", 500);
  }

  return {
    submissionId,
    familyId,
    deletedObjectCount: paths.length,
    alreadyDeleted: false,
    deletedAt,
  };
}

async function loadSubmission(
  client: SupabaseClientLike,
  submissionId: string,
): Promise<ChoreSubmission | null> {
  const { data, error } = await client
    .from("chore_submissions")
    .select(
      "id,task_occurrence_id,image_path,thumbnail_path,evidence_status,evidence_delete_after,evidence_deleted_at",
    )
    .eq("id", submissionId)
    .maybeSingle();

  if (error) {
    console.error(error);
    throw new EvidenceDeletionError("submission_lookup_failed", 500);
  }

  return data as ChoreSubmission | null;
}

async function loadFamilyId(
  client: SupabaseClientLike,
  occurrenceId: string,
): Promise<string> {
  const { data: occurrenceData, error: occurrenceError } = await client
    .from("task_occurrences")
    .select("id,week_id")
    .eq("id", occurrenceId)
    .maybeSingle();

  if (occurrenceError) {
    console.error(occurrenceError);
    throw new EvidenceDeletionError("occurrence_lookup_failed", 500);
  }

  const occurrence = occurrenceData as TaskOccurrence | null;
  if (!occurrence) {
    throw new EvidenceDeletionError("occurrence_not_found", 404);
  }

  const { data: weekData, error: weekError } = await client
    .from("weeks")
    .select("id,family_id")
    .eq("id", occurrence.week_id)
    .maybeSingle();

  if (weekError) {
    console.error(weekError);
    throw new EvidenceDeletionError("week_lookup_failed", 500);
  }

  const week = weekData as Week | null;
  if (!week) {
    throw new EvidenceDeletionError("week_not_found", 404);
  }

  return week.family_id;
}

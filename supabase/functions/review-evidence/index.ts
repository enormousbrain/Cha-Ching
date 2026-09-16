import {
  createClient,
  type SupabaseClient,
} from "https://esm.sh/@supabase/supabase-js@2";

const evidenceBucket = "chore-evidence";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type ReviewRequest = {
  submission_id?: string;
};

type ChoreSubmission = {
  id: string;
  task_occurrence_id: string;
  child_id: string;
  image_path: string;
  submitted_at: string;
};

type TaskOccurrence = {
  id: string;
  chore_definition_id: string;
  child_id: string;
  week_id: string;
  status: string;
  scheduled_at: string;
  due_at: string;
};

type ChoreDefinition = {
  id: string;
  family_id: string;
  title: string;
  short_title: string;
  description: string | null;
  instructions: string | null;
  expected_evidence: string | null;
  verification_mode: string;
};

type Week = {
  id: string;
  family_id: string;
};

type FamilyMembership = {
  role: "parent" | "child";
};

type ChildProfile = {
  id: string;
  family_id: string;
  linked_user_id: string | null;
};

type ModelReviewResult = {
  completed: boolean | null;
  confidence: number;
  reason: string;
  retakeSuggested: boolean;
  retakeInstruction: string | null;
  parentReviewPriority: "normal" | "high";
};

type StoredReviewResult = ModelReviewResult & {
  modelName: string;
  reviewVersion: string;
  reviewedAt: string;
};

// deno-lint-ignore no-explicit-any
type SupabaseClientLike = SupabaseClient<any, "public", "public", any, any>;

const reviewSchema = {
  type: "object",
  additionalProperties: false,
  properties: {
    completed: {
      type: ["boolean", "null"],
      description:
        "Whether the photo shows the chore is complete. Use null when the image is too unclear or ambiguous.",
    },
    confidence: {
      type: "number",
      minimum: 0,
      maximum: 1,
      description: "Confidence from 0 to 1.",
    },
    reason: {
      type: "string",
      maxLength: 280,
      description:
        "Short parent-facing explanation of what the image appears to show.",
    },
    retakeSuggested: {
      type: "boolean",
      description: "Whether the child should be asked for a clearer photo.",
    },
    retakeInstruction: {
      type: ["string", "null"],
      maxLength: 160,
      description: "One short, kid-friendly retake instruction, or null.",
    },
    parentReviewPriority: {
      type: "string",
      enum: ["normal", "high"],
      description:
        "Use high when the evidence is unclear, contradictory, or likely incomplete.",
    },
  },
  required: [
    "completed",
    "confidence",
    "reason",
    "retakeSuggested",
    "retakeInstruction",
    "parentReviewPriority",
  ],
};

Deno.serve(async (request) => {
  try {
    return await handleRequest(request);
  } catch (error) {
    console.error(error);
    return json({ error: "review_failed" }, 500);
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

  const body = await request.json().catch(() => null) as ReviewRequest | null;
  const submissionId = body?.submission_id?.trim();
  if (!submissionId) {
    return json({ error: "missing_submission_id" }, 400);
  }

  const supabaseUrl = getEnv("SUPABASE_URL");
  const anonKey = getEnv("SUPABASE_ANON_KEY");
  const serviceRoleKey = getEnv("SUPABASE_SERVICE_ROLE_KEY");
  const openAIKey = getEnv("OPENAI_API_KEY");

  const modelName = Deno.env.get("OPENAI_REVIEW_MODEL")?.trim() || "gpt-5.6";
  const reviewVersion = Deno.env.get("OPENAI_REVIEW_PROMPT_VERSION")?.trim() ||
    "2026-07-18.1";
  const imageDetail = parseImageDetail(
    Deno.env.get("OPENAI_REVIEW_IMAGE_DETAIL"),
  );

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

  const submission = await loadSubmission(serviceClient, submissionId);
  if (!submission) {
    return json({ error: "submission_not_found" }, 404);
  }

  const occurrence = await loadOccurrence(
    serviceClient,
    submission.task_occurrence_id,
  );
  if (!occurrence) {
    return json({ error: "occurrence_not_found" }, 404);
  }

  const chore = await loadChore(serviceClient, occurrence.chore_definition_id);
  if (!chore) {
    return json({ error: "chore_not_found" }, 404);
  }

  const week = await loadWeek(serviceClient, occurrence.week_id);
  if (!week) {
    return json({ error: "week_not_found" }, 404);
  }

  const familyId = week.family_id || chore.family_id;
  if (familyId !== chore.family_id) {
    return json({ error: "family_mismatch" }, 409);
  }

  const membership = await loadMembership(
    serviceClient,
    familyId,
    userData.user.id,
  );
  if (!membership) {
    return json({ error: "not_family_member" }, 403);
  }

  if (membership.role === "child") {
    const childProfile = await loadChildProfile(
      serviceClient,
      submission.child_id,
    );
    if (
      !childProfile || childProfile.family_id !== familyId ||
      childProfile.linked_user_id !== userData.user.id
    ) {
      return json({ error: "not_submission_owner" }, 403);
    }
  }

  if (!submission.image_path.toLowerCase().startsWith(`${familyId}/`)) {
    return json({ error: "image_path_family_mismatch" }, 409);
  }

  const { data: imageBlob, error: downloadError } = await serviceClient.storage
    .from(evidenceBucket)
    .download(submission.image_path);

  if (downloadError || !imageBlob) {
    console.error(downloadError);
    return json({ error: "image_download_failed" }, 500);
  }

  const mimeType = detectMimeType(imageBlob, submission.image_path);
  if (!isSupportedImageMimeType(mimeType)) {
    return json({ error: "unsupported_image_type", mime_type: mimeType }, 415);
  }

  const base64Image = base64FromArrayBuffer(await imageBlob.arrayBuffer());

  if (["upcoming", "due"].includes(occurrence.status)) {
    const { error: submittedStatusError } = await serviceClient
      .from("task_occurrences")
      .update({ status: "submitted", submission_id: submission.id })
      .eq("id", occurrence.id)
      .in("status", ["upcoming", "due"]);

    if (submittedStatusError) {
      console.error(submittedStatusError);
      return json({ error: "submission_status_update_failed" }, 500);
    }
  }

  let aiResult: StoredReviewResult;
  try {
    aiResult = await reviewEvidenceWithOpenAI({
      apiKey: openAIKey,
      modelName,
      reviewVersion,
      imageDetail,
      mimeType,
      base64Image,
      submission,
      occurrence,
      chore,
      userId: userData.user.id,
    });
  } catch (error) {
    console.error(error);
    aiResult = unavailableReviewResult(modelName, reviewVersion);
  }

  const { error: submissionUpdateError } = await serviceClient
    .from("chore_submissions")
    .update({ ai_result: aiResult })
    .eq("id", submission.id);

  if (submissionUpdateError) {
    console.error(submissionUpdateError);
    return json({ error: "submission_update_failed" }, 500);
  }

  const { error: occurrenceUpdateError } = await serviceClient
    .from("task_occurrences")
    .update({
      status: "ai_reviewed",
      submission_id: submission.id,
    })
    .eq("id", occurrence.id)
    .in("status", ["upcoming", "due", "submitted", "ai_reviewed"]);

  if (occurrenceUpdateError) {
    console.error(occurrenceUpdateError);
    return json({ error: "occurrence_update_failed" }, 500);
  }

  return json({
    submission_id: submission.id,
    task_occurrence_id: occurrence.id,
    ai_result: aiResult,
  });
}

async function loadSubmission(
  client: SupabaseClientLike,
  id: string,
): Promise<ChoreSubmission | null> {
  const { data, error } = await client
    .from("chore_submissions")
    .select("id,task_occurrence_id,child_id,image_path,submitted_at")
    .eq("id", id)
    .maybeSingle();

  if (error) {
    console.error(error);
    throw new Error("submission_lookup_failed");
  }

  return data as ChoreSubmission | null;
}

async function loadOccurrence(
  client: SupabaseClientLike,
  id: string,
): Promise<TaskOccurrence | null> {
  const { data, error } = await client
    .from("task_occurrences")
    .select(
      "id,chore_definition_id,child_id,week_id,status,scheduled_at,due_at",
    )
    .eq("id", id)
    .maybeSingle();

  if (error) {
    console.error(error);
    throw new Error("occurrence_lookup_failed");
  }

  return data as TaskOccurrence | null;
}

async function loadChore(
  client: SupabaseClientLike,
  id: string,
): Promise<ChoreDefinition | null> {
  const { data, error } = await client
    .from("chore_definitions")
    .select(
      "id,family_id,title,short_title,description,instructions,expected_evidence,verification_mode",
    )
    .eq("id", id)
    .maybeSingle();

  if (error) {
    console.error(error);
    throw new Error("chore_lookup_failed");
  }

  return data as ChoreDefinition | null;
}

async function loadWeek(
  client: SupabaseClientLike,
  id: string,
): Promise<Week | null> {
  const { data, error } = await client
    .from("weeks")
    .select("id,family_id")
    .eq("id", id)
    .maybeSingle();

  if (error) {
    console.error(error);
    throw new Error("week_lookup_failed");
  }

  return data as Week | null;
}

async function loadMembership(
  client: SupabaseClientLike,
  familyId: string,
  userId: string,
): Promise<FamilyMembership | null> {
  const { data, error } = await client
    .from("family_members")
    .select("role")
    .eq("family_id", familyId)
    .eq("user_id", userId)
    .maybeSingle();

  if (error) {
    console.error(error);
    throw new Error("membership_lookup_failed");
  }

  return data as FamilyMembership | null;
}

async function loadChildProfile(
  client: SupabaseClientLike,
  id: string,
): Promise<ChildProfile | null> {
  const { data, error } = await client
    .from("child_profiles")
    .select("id,family_id,linked_user_id")
    .eq("id", id)
    .maybeSingle();

  if (error) {
    console.error(error);
    throw new Error("child_profile_lookup_failed");
  }

  return data as ChildProfile | null;
}

async function reviewEvidenceWithOpenAI(input: {
  apiKey: string;
  modelName: string;
  reviewVersion: string;
  imageDetail: "low" | "high" | "original" | "auto";
  mimeType: string;
  base64Image: string;
  submission: ChoreSubmission;
  occurrence: TaskOccurrence;
  chore: ChoreDefinition;
  userId: string;
}): Promise<StoredReviewResult> {
  const response = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${input.apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: input.modelName,
      store: false,
      max_output_tokens: 500,
      safety_identifier: await sha256Hex(input.userId),
      instructions: [
        "You review chore evidence photos for a family allowance app.",
        "You are advisory only; a parent makes the final decision.",
        "Judge only whether the submitted photo appears to satisfy the expected chore evidence.",
        "Be conservative when the evidence is unclear, cropped, staged, contradictory, or does not show the requested task.",
        "Never identify people in the photo. Do not infer sensitive traits.",
        "Return JSON that matches the schema.",
      ].join(" "),
      input: [
        {
          role: "user",
          content: [
            {
              type: "input_text",
              text: buildReviewPrompt(
                input.submission,
                input.occurrence,
                input.chore,
              ),
            },
            {
              type: "input_image",
              image_url: `data:${input.mimeType};base64,${input.base64Image}`,
              detail: input.imageDetail,
            },
          ],
        },
      ],
      text: {
        format: {
          type: "json_schema",
          name: "chore_evidence_review",
          strict: true,
          schema: reviewSchema,
        },
      },
    }),
    signal: AbortSignal.timeout(45_000),
  });

  const responseBody = await response.json().catch(() => null);
  if (!response.ok) {
    console.error(responseBody);
    throw new Error("openai_review_failed");
  }

  const refusal = extractRefusal(responseBody);
  if (refusal) {
    return {
      completed: null,
      confidence: 0,
      reason:
        "The AI reviewer could not evaluate this photo. A parent should review it directly.",
      retakeSuggested: false,
      retakeInstruction: null,
      parentReviewPriority: "high",
      modelName: input.modelName,
      reviewVersion: input.reviewVersion,
      reviewedAt: new Date().toISOString(),
    };
  }

  const outputText = extractOutputText(responseBody);
  if (!outputText) {
    console.error(responseBody);
    throw new Error("missing_openai_output");
  }

  const parsed = JSON.parse(outputText) as Partial<ModelReviewResult>;
  const validated = validateModelReview(parsed);
  return {
    ...validated,
    modelName: input.modelName,
    reviewVersion: input.reviewVersion,
    reviewedAt: new Date().toISOString(),
  };
}

function unavailableReviewResult(
  modelName: string,
  reviewVersion: string,
): StoredReviewResult {
  return {
    completed: null,
    confidence: 0,
    reason:
      "The AI check is unavailable right now. The photo was saved for a parent to review directly.",
    retakeSuggested: false,
    retakeInstruction: null,
    parentReviewPriority: "high",
    modelName,
    reviewVersion,
    reviewedAt: new Date().toISOString(),
  };
}

function buildReviewPrompt(
  submission: ChoreSubmission,
  occurrence: TaskOccurrence,
  chore: ChoreDefinition,
): string {
  return [
    "Review this chore evidence photo.",
    `Chore title: ${chore.title}`,
    `Short title: ${chore.short_title}`,
    `Description: ${chore.description || "None provided"}`,
    `Instructions: ${chore.instructions || "None provided"}`,
    `Expected evidence: ${
      chore.expected_evidence || "A clear photo showing the completed chore"
    }`,
    `Verification mode: ${chore.verification_mode}`,
    `Scheduled at: ${occurrence.scheduled_at}`,
    `Due at: ${occurrence.due_at}`,
    `Submitted at: ${submission.submitted_at}`,
    "If the photo does not clearly show the expected evidence, set completed to null or false and explain briefly.",
    "Use retakeSuggested only when a clearer photo would likely resolve the uncertainty.",
  ].join("\n");
}

function extractOutputText(responseBody: unknown): string | null {
  if (typeof responseBody !== "object" || responseBody === null) {
    return null;
  }

  const maybeOutputText =
    (responseBody as { output_text?: unknown }).output_text;
  if (typeof maybeOutputText === "string" && maybeOutputText.trim()) {
    return maybeOutputText;
  }

  const output = (responseBody as { output?: unknown }).output;
  if (!Array.isArray(output)) {
    return null;
  }

  const parts: string[] = [];
  for (const item of output) {
    if (!isRecord(item)) {
      continue;
    }

    const content = item.content;
    if (!Array.isArray(content)) {
      continue;
    }

    for (const contentItem of content) {
      if (!isRecord(contentItem)) {
        continue;
      }

      if (typeof contentItem.text === "string") {
        parts.push(contentItem.text);
      }
    }
  }

  const joined = parts.join("").trim();
  return joined || null;
}

function extractRefusal(responseBody: unknown): string | null {
  if (!isRecord(responseBody) || !Array.isArray(responseBody.output)) {
    return null;
  }

  for (const item of responseBody.output) {
    if (!isRecord(item) || !Array.isArray(item.content)) {
      continue;
    }

    for (const contentItem of item.content) {
      if (isRecord(contentItem) && typeof contentItem.refusal === "string") {
        return contentItem.refusal;
      }
    }
  }

  return null;
}

function validateModelReview(
  value: Partial<ModelReviewResult>,
): ModelReviewResult {
  const completed = value.completed;
  if (!(completed === true || completed === false || completed === null)) {
    throw new Error("invalid_completed");
  }

  if (
    typeof value.confidence !== "number" || value.confidence < 0 ||
    value.confidence > 1
  ) {
    throw new Error("invalid_confidence");
  }

  if (typeof value.reason !== "string" || !value.reason.trim()) {
    throw new Error("invalid_reason");
  }

  if (typeof value.retakeSuggested !== "boolean") {
    throw new Error("invalid_retake_suggested");
  }

  if (
    !(typeof value.retakeInstruction === "string" ||
      value.retakeInstruction === null)
  ) {
    throw new Error("invalid_retake_instruction");
  }

  if (
    !(value.parentReviewPriority === "normal" ||
      value.parentReviewPriority === "high")
  ) {
    throw new Error("invalid_parent_review_priority");
  }

  return {
    completed,
    confidence: value.confidence,
    reason: value.reason.trim(),
    retakeSuggested: value.retakeSuggested,
    retakeInstruction: value.retakeInstruction?.trim() || null,
    parentReviewPriority: value.parentReviewPriority,
  };
}

function detectMimeType(blob: Blob, imagePath: string): string {
  const blobType = blob.type.trim().toLowerCase();
  if (blobType === "image/jpg") {
    return "image/jpeg";
  }
  if (blobType) {
    return blobType;
  }

  const lowerPath = imagePath.toLowerCase();
  if (lowerPath.endsWith(".png")) return "image/png";
  if (lowerPath.endsWith(".webp")) return "image/webp";
  if (lowerPath.endsWith(".gif")) return "image/gif";
  if (lowerPath.endsWith(".heic")) return "image/heic";
  if (lowerPath.endsWith(".jpeg") || lowerPath.endsWith(".jpg")) {
    return "image/jpeg";
  }
  return "image/jpeg";
}

function isSupportedImageMimeType(mimeType: string): boolean {
  return ["image/jpeg", "image/png", "image/webp", "image/gif"].includes(
    mimeType,
  );
}

function parseImageDetail(
  value: string | undefined,
): "low" | "high" | "original" | "auto" {
  if (value === "high" || value === "original" || value === "auto") {
    return value;
  }
  return "low";
}

function base64FromArrayBuffer(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  const chunkSize = 0x8000;
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    binary += String.fromCharCode(
      ...bytes.subarray(offset, offset + chunkSize),
    );
  }
  return btoa(binary);
}

async function sha256Hex(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(hash))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function getEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) {
    throw new Error(`Missing ${name}`);
  }
  return value;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
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

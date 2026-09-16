import {
  evidencePathsForFamily,
  isEvidenceDeletionDue,
} from "./evidence-deletion-policy.ts";

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function assertEquals<T>(actual: T, expected: T): void {
  assert(
    JSON.stringify(actual) === JSON.stringify(expected),
    `Expected ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`,
  );
}

Deno.test("evidence is due only after a pending deletion deadline", () => {
  const now = new Date("2026-07-18T12:00:00.000Z");

  assert(
    isEvidenceDeletionDue("pending_delete", now.toISOString(), now),
    "due",
  );
  assert(
    !isEvidenceDeletionDue(
      "pending_delete",
      "2026-07-18T12:00:01.000Z",
      now,
    ),
    "future deadline",
  );
  assert(
    !isEvidenceDeletionDue("available", now.toISOString(), now),
    "available evidence",
  );
  assert(
    !isEvidenceDeletionDue("pending_delete", "not-a-date", now),
    "invalid deadline",
  );
});

Deno.test("evidence paths are family-scoped and deduplicated", () => {
  assertEquals(
    evidencePathsForFamily(
      "family-1",
      "family-1/occurrence/original.jpg",
      "family-1/occurrence/original.jpg",
    ),
    ["family-1/occurrence/original.jpg"],
  );

  let error: Error | null = null;
  try {
    evidencePathsForFamily(
      "family-1",
      "family-2/occurrence/original.jpg",
      null,
    );
  } catch (caught) {
    error = caught as Error;
  }

  assertEquals(error?.message, "evidence_path_family_mismatch");
});

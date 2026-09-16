export function isEvidenceDeletionDue(
  status: string,
  deleteAfter: string | null,
  now: Date,
): boolean {
  if (status !== "pending_delete" || !deleteAfter) {
    return false;
  }

  const deadline = Date.parse(deleteAfter);
  return Number.isFinite(deadline) && deadline <= now.getTime();
}

export function evidencePathsForFamily(
  familyId: string,
  imagePath: string | null,
  thumbnailPath: string | null,
): string[] {
  const prefix = `${familyId}/`;
  const paths = [imagePath, thumbnailPath].filter(
    (path): path is string => Boolean(path),
  );

  if (paths.some((path) => !path.startsWith(prefix))) {
    throw new Error("evidence_path_family_mismatch");
  }

  return [...new Set(paths)];
}

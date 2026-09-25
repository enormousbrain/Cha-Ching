import { type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { drainPrivacyCleanup } from "./privacy-cleanup.ts";
import { revokeAppleSignIn } from "./apple-revocation.ts";

function fixture() {
  const state = {
    tables: {
      evidence_removal_queue: [{ path: "family/photo.jpg", deletion_user_id: "user" }],
      account_deletion_requests: [{ user_id: "user" }],
      chore_submissions: [{ image_path: "family/photo.jpg", thumbnail_path: null }],
    } as Record<string, Record<string, unknown>[]>,
    failStorage: false, failAuth: false, failMetadata: false,
    deletedUsers: [] as string[], removedPaths: [] as string[],
  };
  const client = {
    from(table: string) {
      let operation = "select";
      let values: Record<string, unknown> = {};
      const filters: [string, unknown][] = [];
      const query = {
        select(..._args: unknown[]) { return query; },
        order(..._args: unknown[]) { return query; },
        limit(..._args: unknown[]) { return query; },
        eq(key: string, value: unknown) { filters.push([key, value]); return query; },
        update(update: Record<string, unknown>) { operation = "update"; values = update; return query; },
        delete() { operation = "delete"; return query; },
        then(resolve: (value: unknown) => unknown) {
          const rows = state.tables[table] ?? [];
          const matched = rows.filter((row) => filters.every(([key, value]) => row[key] === value));
          const failed = state.failMetadata && table === "chore_submissions" && operation === "update";
          if (!failed && operation === "update") matched.forEach((row) => Object.assign(row, values));
          if (operation === "delete") state.tables[table] = rows.filter((row) => !matched.includes(row));
          return Promise.resolve(resolve({ data: matched, count: matched.length, error: failed ? { code: "offline" } : null }));
        },
      };
      return query;
    },
    storage: { from() { return { remove(paths: string[]) {
      if (!state.failStorage) state.removedPaths.push(...paths);
      return Promise.resolve({ error: state.failStorage ? { code: "offline" } : null });
    } }; } },
    auth: { admin: { deleteUser(id: string) {
      if (!state.failAuth) state.deletedUsers.push(id);
      return Promise.resolve({ error: state.failAuth ? { code: "offline" } : null });
    } } },
  } as unknown as SupabaseClient;
  return { state, client };
}

function assert(value: unknown, message: string) { if (!value) throw new Error(message); }

Deno.test("storage failure keeps the durable request and blocks auth deletion; retry completes", async () => {
  const { client, state } = fixture();
  state.failStorage = true;
  const first = await drainPrivacyCleanup(client);
  assert(first.failedEvidence === 1 && state.deletedUsers.length === 0, "account deleted before photo");
  assert(state.tables.evidence_removal_queue.length === 1, "retry path lost");
  state.failStorage = false;
  await drainPrivacyCleanup(client);
  assert(state.deletedUsers.length === 1 && state.tables.account_deletion_requests.length === 0, "retry did not complete");
  assert(state.tables.chore_submissions[0].image_path === null, "image reference retained");
});

Deno.test("database update failure preserves a photo cleanup retry after Storage succeeds", async () => {
  const { client, state } = fixture();
  state.failMetadata = true;
  await drainPrivacyCleanup(client);
  assert(state.removedPaths.length === 1 && state.tables.evidence_removal_queue.length === 1, "durable retry lost");
  assert(state.deletedUsers.length === 0, "account deleted while cleanup incomplete");
  state.failMetadata = false;
  await drainPrivacyCleanup(client);
  assert(state.deletedUsers.length === 1, "idempotent retry failed");
});

Deno.test("auth deletion failure is retried after photos are gone", async () => {
  const { client, state } = fixture();
  state.failAuth = true;
  await drainPrivacyCleanup(client);
  assert(state.tables.evidence_removal_queue.length === 0 && state.tables.account_deletion_requests.length === 1, "auth retry lost");
  state.failAuth = false;
  await drainPrivacyCleanup(client);
  assert(state.deletedUsers.length === 1, "auth retry failed");
});

Deno.test("missing Apple authorization code leaves a manual revocation path", async () => {
  assert(await revokeAppleSignIn(undefined, undefined) === false, "must not claim Apple revocation");
});

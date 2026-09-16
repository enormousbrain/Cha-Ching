#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_REF="${SUPABASE_PROJECT_REF:-pjvgtmxyxrfhabyuefne}"
PROJECT_URL="${SUPABASE_URL:-https://${PROJECT_REF}.supabase.co}"
DB_HOST="${SUPABASE_DB_HOST:-db.${PROJECT_REF}.supabase.co}"
KEYCHAIN_SERVICE="${SUPABASE_DB_KEYCHAIN_SERVICE:-ChaChing Supabase DB Password}"
KEYCHAIN_ACCOUNT="${SUPABASE_DB_KEYCHAIN_ACCOUNT:-postgres@${PROJECT_REF}}"

for command in openssl psql supabase; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Missing required command: $command"
    exit 1
  fi
done

DB_PASSWORD="${SUPABASE_DB_PASSWORD:-}"
if [ -z "$DB_PASSWORD" ] && command -v security >/dev/null 2>&1; then
  DB_PASSWORD="$(
    security find-generic-password \
      -a "$KEYCHAIN_ACCOUNT" \
      -s "$KEYCHAIN_SERVICE" \
      -w 2>/dev/null || true
  )"
fi

if [ -z "$DB_PASSWORD" ]; then
  echo "Missing database password. Set SUPABASE_DB_PASSWORD or add it to Keychain:"
  echo "  service: $KEYCHAIN_SERVICE"
  echo "  account: $KEYCHAIN_ACCOUNT"
  exit 1
fi

CLEANUP_SECRET="${EVIDENCE_CLEANUP_SECRET:-$(openssl rand -hex 32)}"
SECRET_FILE="$(mktemp)"
trap 'rm -f "$SECRET_FILE"' EXIT
chmod 600 "$SECRET_FILE"
printf 'EVIDENCE_CLEANUP_SECRET=%s\n' "$CLEANUP_SECRET" > "$SECRET_FILE"

echo "Applying retention cleanup schema..."
PGPASSWORD="$DB_PASSWORD" psql \
  "host=$DB_HOST port=5432 user=postgres dbname=postgres sslmode=require" \
  -v ON_ERROR_STOP=1 \
  -f "$ROOT_DIR/supabase/migrations/0013_retention_cleanup.sql"

echo "Uploading the cleanup secret..."
supabase secrets set \
  --project-ref "$PROJECT_REF" \
  --env-file "$SECRET_FILE"

echo "Deploying evidence cleanup functions..."
supabase functions deploy delete-submission-evidence \
  --project-ref "$PROJECT_REF"
supabase functions deploy retention-cleanup \
  --project-ref "$PROJECT_REF" \
  --no-verify-jwt

echo "Configuring the 15-minute cleanup schedule..."
PGPASSWORD="$DB_PASSWORD" psql \
  "host=$DB_HOST port=5432 user=postgres dbname=postgres sslmode=require" \
  -v ON_ERROR_STOP=1 \
  -v cleanup_secret="$CLEANUP_SECRET" \
  -v project_url="$PROJECT_URL" <<'SQL'
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;
create extension if not exists supabase_vault with schema vault;

select vault.create_secret(
  :'cleanup_secret',
  'chaching_evidence_cleanup_secret',
  'Authenticates the scheduled evidence retention Edge Function'
)
where not exists (
  select 1 from vault.secrets
  where name = 'chaching_evidence_cleanup_secret'
);

select vault.update_secret(
  id,
  new_secret := :'cleanup_secret',
  new_description := 'Authenticates the scheduled evidence retention Edge Function'
)
from vault.secrets
where name = 'chaching_evidence_cleanup_secret';

select cron.unschedule(jobid)
from cron.job
where jobname = 'chaching-retention-cleanup';

select cron.schedule(
  'chaching-retention-cleanup',
  '*/15 * * * *',
  format(
    $job$
      select net.http_post(
        url := %L,
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-cleanup-secret', (
            select decrypted_secret
            from vault.decrypted_secrets
            where name = 'chaching_evidence_cleanup_secret'
          )
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 10000
      );
    $job$,
    :'project_url' || '/functions/v1/retention-cleanup'
  )
);
SQL

echo "Evidence cleanup is deployed and scheduled every 15 minutes."

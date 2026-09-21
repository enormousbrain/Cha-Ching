create extension if not exists pg_net;

do $$
declare
  existing_job_id bigint;
begin
  for existing_job_id in
    select jobid from cron.job where jobname = 'chaching-parent-overdue-alerts'
  loop
    perform cron.unschedule(existing_job_id);
  end loop;
end;
$$;

select cron.schedule(
  'chaching-parent-overdue-alerts',
  '*/5 * * * *',
  $$
  select net.http_post(
    url := 'https://pjvgtmxyxrfhabyuefne.supabase.co/functions/v1/send-parent-overdue-alerts',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-function-secret', (
        select decrypted_secret
        from vault.decrypted_secrets
        where name = 'ChaChing parent alert function secret'
        limit 1
      )
    ),
    body := '{}'::jsonb
  );
  $$
);

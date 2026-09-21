alter table public.chore_definitions
  add column if not exists location_name text,
  add column if not exists location_latitude double precision,
  add column if not exists location_longitude double precision,
  add column if not exists location_radius_meters double precision default 200,
  add column if not exists location_leave_reminder_minutes integer default 30;

alter table public.chore_definitions
  drop constraint if exists chore_definitions_location_bounds;

alter table public.chore_definitions
  add constraint chore_definitions_location_bounds check (
    (location_name is null and location_latitude is null and location_longitude is null)
    or (
      nullif(trim(location_name), '') is not null
      and location_latitude between -90 and 90
      and location_longitude between -180 and 180
      and coalesce(location_radius_meters, 200) between 100 and 1000
      and coalesce(location_leave_reminder_minutes, 30) between 0 and 180
    )
  );

comment on column public.chore_definitions.location_name is
  'Optional chore destination label. Raw device location is never stored here.';
comment on column public.chore_definitions.location_radius_meters is
  'Arrival geofence radius used on the child device.';

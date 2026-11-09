-- Step 3 of the gpro-dev database sync, run by sanitize.sh with
-- --single-transaction from inside WORK_DIR, so any error rolls everything back.
-- psql variables: keep_count, swk_count, cron_count.
-- preserved.sql sets search_path to '', so everything below is schema-qualified.

-- 1. Drop production-only state.
TRUNCATE public.refresh_token, public.password_reset_token,
         public.cron_job_run_log, public.cron_job_schedule,
         public.service_worker_api_key
  RESTART IDENTITY;

-- 2. Restore dev's own service-worker keys and cron schedules.
\i preserved.sql
SELECT pg_catalog.setval(
  pg_catalog.pg_get_serial_sequence('public.service_worker_api_key', 'id'),
  COALESCE((SELECT max(id) FROM public.service_worker_api_key), 0) + 1, false);
SELECT pg_catalog.setval(
  pg_catalog.pg_get_serial_sequence('public.cron_job_schedule', 'id'),
  COALESCE((SELECT max(id) FROM public.cron_job_schedule), 0) + 1, false);

-- 3. Only users enabled in dev before the sync stay enabled; nobody else keeps an API key.
CREATE TEMP TABLE keep_ids (gpro_manager_id integer PRIMARY KEY) ON COMMIT DROP;
\copy pg_temp.keep_ids FROM 'enabled_ids.txt'
UPDATE public."user"
   SET enabled = false, api_key = NULL
 WHERE gpro_manager_id IS NULL
    OR gpro_manager_id NOT IN (SELECT gpro_manager_id FROM pg_temp.keep_ids);
UPDATE public."user"
   SET enabled = true
 WHERE gpro_manager_id IN (SELECT gpro_manager_id FROM pg_temp.keep_ids);

-- 4. Assertions. DO blocks cannot see psql variables, so pass them via settings.
SELECT pg_catalog.set_config('dbsync.keep_count', :'keep_count', true),
       pg_catalog.set_config('dbsync.swk_count', :'swk_count', true),
       pg_catalog.set_config('dbsync.cron_count', :'cron_count', true);

DO $$
DECLARE
  n bigint;
BEGIN
  SELECT count(*) INTO n FROM public."user" WHERE enabled;
  IF n > current_setting('dbsync.keep_count')::bigint THEN
    RAISE EXCEPTION 'sanitize: % users enabled, expected at most %',
      n, current_setting('dbsync.keep_count');
  END IF;

  SELECT count(*) INTO n FROM public."user" WHERE NOT enabled AND api_key IS NOT NULL;
  IF n > 0 THEN
    RAISE EXCEPTION 'sanitize: % disabled users still have an API key', n;
  END IF;

  SELECT count(*) INTO n FROM public.service_worker_api_key;
  IF n <> current_setting('dbsync.swk_count')::bigint THEN
    RAISE EXCEPTION 'sanitize: % service-worker keys, expected %',
      n, current_setting('dbsync.swk_count');
  END IF;

  SELECT count(*) INTO n FROM public.cron_job_schedule;
  IF n <> current_setting('dbsync.cron_count')::bigint THEN
    RAISE EXCEPTION 'sanitize: % cron schedules, expected %',
      n, current_setting('dbsync.cron_count');
  END IF;

  IF EXISTS (SELECT 1 FROM public.refresh_token)
     OR EXISTS (SELECT 1 FROM public.password_reset_token) THEN
    RAISE EXCEPTION 'sanitize: token tables are not empty';
  END IF;
END
$$;

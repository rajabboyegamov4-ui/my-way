-- =====================================================================
--  MY WAY: har soatlik eslatma (Cron)
--  Oldin: Database > Extensions bo'limida pg_cron va pg_net ni yoqing.
--  CRON_SECRET_NI_SHU_YERGA o'rniga Edge Functions secretlariga
--  yozgan CRON_SECRET qiymatingizni qo'ying. Keyin Run.
-- =====================================================================
select cron.schedule(
  'myway-telegram-remind',
  '0 * * * *',
  $$
  select net.http_post(
    url     := 'https://gapngwdqujphpqwnwmwe.supabase.co/functions/v1/super-service',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', 'CRON_SECRET_NI_SHU_YERGA'),
    body    := '{}'::jsonb
  );
  $$
);

-- Tekshirish:  select * from cron.job;
-- O'chirish:   select cron.unschedule('myway-telegram-remind');

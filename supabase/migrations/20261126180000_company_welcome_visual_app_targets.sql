ALTER TABLE public.company_settings
  ADD COLUMN IF NOT EXISTS company_welcome_visual_targets text[] NOT NULL
  DEFAULT ARRAY['customer','worker','driver','large_driver']::text[];

COMMENT ON COLUMN public.company_settings.company_welcome_visual_targets IS
  'App variants that display the company welcome visual on the launch splash only.';

GRANT SELECT (company_welcome_visual_targets)
  ON public.company_settings TO anon, authenticated;

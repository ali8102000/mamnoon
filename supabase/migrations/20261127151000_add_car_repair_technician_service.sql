-- Add the car repair technician profession to the shared worker/customer service catalog.
BEGIN;

INSERT INTO public.services (slug, name_ar, name_en, icon, sort_order)
VALUES ('car_repair', 'مصلّح سيارات', 'Car Mechanic', 'wrench', 23)
ON CONFLICT (slug) DO UPDATE
SET name_ar = EXCLUDED.name_ar,
    name_en = EXCLUDED.name_en,
    icon = EXCLUDED.icon,
    sort_order = EXCLUDED.sort_order;

COMMIT;

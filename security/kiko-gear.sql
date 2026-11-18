-- Kiko: highest-priced cosmetic in the main Locker, not Career currency.
BEGIN;
SELECT pg_advisory_xact_lock(738401216);
DO $$BEGIN
 IF to_regprocedure('bu_private.outfit_v3(jsonb,jsonb,boolean)') IS NULL THEN RAISE EXCEPTION 'Install economy security v3 first';END IF;
 IF EXISTS(SELECT 1 FROM public.bu_shop_items WHERE id<>'a:kiko' AND price>=5000) THEN RAISE EXCEPTION 'Another item costs 5000 or more. Review Kiko price before installation.';END IF;
END;$$;
INSERT INTO public.bu_shop_items(id,price) VALUES('a:kiko',5000)
ON CONFLICT(id) DO UPDATE SET price=EXCLUDED.price;
COMMIT;
SELECT 'Kiko installed: Locker > Gear, 5000 coins.' AS result;

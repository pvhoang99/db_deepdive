\set a random(1, 20)
\set b random(1, 20)
BEGIN;
SELECT cv_lock(:a, :b, 10) WHERE :a <> :b;
COMMIT;

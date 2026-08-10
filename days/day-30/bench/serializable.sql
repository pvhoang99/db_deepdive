\set a random(1, 20)
\set b random(1, 20)
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT cv_plain(:a, :b, 10) WHERE :a <> :b;
COMMIT;

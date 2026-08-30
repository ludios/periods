-- Model-output: Claude Fable 5
-- Control: single-row update on a table with no periods machinery.
\set id random(1, 10000)
UPDATE bench.plain SET value = value + 1 WHERE id = :id;

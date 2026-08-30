-- Model-output: Claude Fable 5
-- Portion update splitting a [0,1000) row into three at [400,600), rolled
-- back so every transaction splits a pristine row again.
\set id random(1, 5000)
BEGIN;
UPDATE bench.portion__for_portion_of_valid_time
   SET value = value + 1, valid_from = 400, valid_to = 600
 WHERE id = :id;
ROLLBACK;

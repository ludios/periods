-- Model-output: Claude Fable 5
-- Control: single-row insert into a table with no periods machinery.
\set v random(1, 1000000000)
INSERT INTO bench.plain (id, value, note) VALUES (nextval('bench.plain_id'), :v, 'x');

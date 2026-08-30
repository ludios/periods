-- Model-output: Claude Fable 5
-- Single-row insert into the versioned table: generated_always BEFORE +
-- write_history AFTER fire; no history row is written on the insert path.
INSERT INTO bench.versioned (id, value, note) VALUES (nextval('bench.v_id'), 0, 'x');

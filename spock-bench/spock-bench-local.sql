\set bid (random(1, :scale / 3) - 1) * 3 + :branch
\set aid random(1, 100000) + 100000 * (:bid - 1)
\set tid random(1, 10) + 10 * (:bid - 1)
\set delta random(-5000, 5000)
\set trandom random(0,999)
\set arandom random(0,999)
BEGIN;
UPDATE pgbench_accounts SET abalance = abalance + :delta, arandom = :arandom, alastts = CURRENT_TIMESTAMP WHERE aid = :aid;
SELECT abalance FROM pgbench_accounts WHERE aid = :aid;
UPDATE pgbench_tellers SET tbalance = tbalance + :delta, trandom = :trandom, tlastts = CURRENT_TIMESTAMP WHERE tid = :tid;
UPDATE pgbench_branches SET bbalance = bbalance + :delta WHERE bid = :bid;
INSERT INTO pgbench_history (tid, bid, aid, delta, mtime) VALUES (:tid, :bid, :aid, :delta, CURRENT_TIMESTAMP);
END;

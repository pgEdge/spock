-- like bt_index_check('spock.sequence_state', true)
CREATE FUNCTION heapallindexed() RETURNS void AS $$
DECLARE
	count_seqscan int;
	count_idxscan int;
BEGIN
	count_seqscan := (SELECT count(*) FROM spock.sequence_state);
	SET enable_seqscan = off;
	count_idxscan := (SELECT count(*) FROM spock.sequence_state);
	RESET enable_seqscan;
	IF count_seqscan <> count_idxscan THEN
		RAISE 'seqscan found % rows, but idxscan found % rows',
			count_seqscan, count_idxscan;
	END IF;
END
$$ LANGUAGE plpgsql;

-- Replicate one sequence.
CREATE SEQUENCE stress;
SELECT * FROM spock.repset_create('stress_seq');
SELECT * FROM spock.repset_add_seq('stress_seq', 'stress');
SELECT spock.sync_seq('stress');
SELECT heapallindexed();

-- Sync it 400 times in one transaction, to cross a spock.sequence_state
-- page boundary and get a non-HOT update.
DO $$
BEGIN
  FOR i IN 1..400 LOOP
    PERFORM spock.sync_seq('stress');
  END LOOP;
END;
$$;
SELECT heapallindexed();

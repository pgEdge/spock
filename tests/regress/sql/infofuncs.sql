CREATE EXTENSION spock;

SELECT spock.spock_max_proto_version();

SELECT spock.spock_min_proto_version();

-- test extension version
SELECT spock.spock_version() = extversion
FROM pg_extension
WHERE extname = 'spock';

-- Check that security label is cleaned up on the extension drop
CREATE TABLE slabel (x money, y text PRIMARY KEY);
SELECT spock.delta_apply('slabel', 'x', false);
SELECT objname, label FROM pg_seclabels;

DROP EXTENSION spock;

SELECT objname, label FROM pg_seclabels;
DROP TABLE slabel;

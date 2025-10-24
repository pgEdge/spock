CREATE EXTENSION spock;

SELECT spock.spock_max_proto_version();

SELECT spock.spock_min_proto_version();

-- test extension version
SELECT spock.spock_version() = extversion
FROM pg_extension
WHERE extname = 'spock';

DROP EXTENSION spock;

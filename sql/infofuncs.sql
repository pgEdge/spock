DO $$
BEGIN
	IF (SELECT setting::integer/100 FROM pg_settings WHERE name = 'server_version_num') = 904 THEN
		CREATE EXTENSION IF NOT EXISTS spock_origin;
	END IF;
END;$$;
CREATE EXTENSION spock;

SELECT spock.spock_max_proto_version();

SELECT spock.spock_min_proto_version();

-- test extension version
SELECT spock.spock_version() = extversion
FROM pg_extension
WHERE extname = 'spock';

DROP EXTENSION spock;

-- test upgrades
DO $$
BEGIN
        IF version() ~ 'Postgres-XL' THEN
                CREATE EXTENSION IF NOT EXISTS spock;
        ELSE
                CREATE EXTENSION IF NOT EXISTS spock VERSION '3.1';
        END IF;
END;
$$;
ALTER EXTENSION spock UPDATE;

SELECT spock.spock_version() = extversion
FROM pg_extension
WHERE extname = 'spock';

DROP EXTENSION spock;

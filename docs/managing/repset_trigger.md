
## Automatically Assigning Tables to Replication Sets

Automatic DDL replication is a great alternative to using a trigger to manage replication sets, but if you do need to dynamically modify replication rules, column or row filters, or partition filters, this trigger might be useful. This trigger does not replicate the DDL statements across nodes, but automatically adds newly created tables to a replication set on the node on which the trigger fires.

Before using the trigger, you should modify this trigger to account for all flavors of `CREATE TABLE` statements you might run. Since the trigger executes in a transaction, if the code in the trigger fails, the transaction is rolled back, including any `CREATE TABLE` statements that caused the trigger to fire. This means that statements like `CREATE UNLOGGED TABLE` will fail if the trigger fails.

Please note that you must ensure that while using the trigger, automatic replication of DDL commands is disabled.  You can use the following commands on the PSQL command line to disable Auto DDL functionality:

```sql
ALTER SYSTEM SET spock.enable_ddl_replication=off;
ALTER SYSTEM SET spock.include_ddl_repset=off;
ALTER SYSTEM SET spock.allow_ddl_from_functions=off;
SELECT pg_reload_conf(); 
```

You can use the event trigger facility to describe rules that define replication sets for newly created tables. For example:

```sql
    CREATE OR REPLACE FUNCTION spock_assign_repset()
    RETURNS event_trigger AS $$
    DECLARE obj record;
    BEGIN
        FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands()
        LOOP
            IF obj.object_type = 'table' THEN
                IF obj.schema_name = 'config' THEN
                    PERFORM spock.repset_add_table('configuration', obj.objid);
                ELSIF NOT obj.in_extension THEN
                    PERFORM spock.repset_add_table('default', obj.objid);
                END IF;
            END IF;
        END LOOP;
    END;
    $$ LANGUAGE plpgsql;

    CREATE EVENT TRIGGER spock_assign_repset_trg
        ON ddl_command_end
        WHEN TAG IN ('CREATE TABLE', 'CREATE TABLE AS')
        EXECUTE PROCEDURE spock_assign_repset();
```

The code snippet shown above adds any new table created in the `config` schema into
a replication set named `configuration`, and adds all other new tables (which are not created by extensions) to the `default` replication set.



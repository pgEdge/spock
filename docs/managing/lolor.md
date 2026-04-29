# Using LOLOR to Manage Large objects

PostgreSQL's logical decoding facility does not support decoding changes to
[large objects](https://www.postgresql.org/docs/current/largeobjects.html);
we recommend instead using the
[LOLOR extension](https://github.com/pgEdge/lolor) to manage large objects.

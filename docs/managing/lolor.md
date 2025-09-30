# Using LOLOR to Manage Large objects

PostgreSQL's logical decoding facility does not support decoding changes
to [large objects](https://www.postgresql.org/docs/current/largeobjects.html); we recommend instead using the [LOLOR extension](https://github.com/pgEdge/lolor) to manage large objects.

If you're using pgEdge Platform, you'll also find more information about using LOLOR with your distributed cluster [here](https://docs.pgedge.com/platform/lolor).
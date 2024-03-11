Run pgEdge in a docker container
==

Test environment of **pgEdge Platform** running in two Docker containers, deployed using `docker compose`.

Intention of how this should run:
---

```
docker compose build
docker compose up
```

Once the networking is finished, this will install pgEdge Platform
with a database called `demo`. It will install the `spock` extension, 
create a `foobar` table, and configure replication for that table. 
A successful run will show out of 

```
SELECT * FROM spock.node;
```

with two records, one for each node, showing on both nodes


To reset:
---
``
docker compose down
docker compose rm
``


# spock.sub_disable

The `spock.sub_disable()` function disables a subscription and disconnects
from the provider.

## Synopsis

```sql
spock.sub_disable(subscription_name name, immediate boolean DEFAULT false)
```

## Arguments

The function accepts the following arguments:

- `subscription_name` - The name of an existing subscription.
- `immediate` - If `true`, the subscription is disabled immediately; otherwise
  it is disabled at the end of the current transaction. The default is `false`.

## Example

In the following example, the `spock.sub_disable()` function disables a
subscription named `sub_n1_n2`:

```sql
SELECT spock.sub_disable('sub_n1_n2');
 sub_disable
-------------
 t
(1 row)
```

--FOREIGN KEY
SELECT * FROM spock_regress_variables()
\gset


\c :provider_dsn

SELECT spock.replicate_ddl($$
CREATE TABLE public.f1k_products (
    product_no integer PRIMARY KEY,
    product_id integer,
    name text,
    price numeric
);

CREATE TABLE public.f1k_orders (
    order_id integer,
    product_no integer REFERENCES public.f1k_products (product_no),
    quantity integer
);
--pass
$$);

SELECT * FROM spock.repset_add_table('default', 'f1k_products');
SELECT * FROM spock.repset_add_table('default_insert_only', 'f1k_orders');

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

INSERT into public.f1k_products VALUES (1, 1, 'product1', 1.20);
INSERT into public.f1k_products VALUES (2, 2, 'product2', 2.40);

INSERT into public.f1k_orders VALUES (300, 1, 4);
INSERT into public.f1k_orders VALUES (22, 2, 14);
INSERT into public.f1k_orders VALUES (23, 2, 24);
INSERT into public.f1k_orders VALUES (24, 2, 40);

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn

SELECT * FROM public.f1k_products;
SELECT * FROM public.f1k_orders;


\c :provider_dsn
\set VERBOSITY terse
SELECT spock.replicate_ddl($$
	DROP TABLE public.f1k_orders CASCADE;
	DROP TABLE public.f1k_products CASCADE;
$$);

/*-------------------------------------------------------------------------
 *
 * spock_apply_spi.h
 * 		spock apply functions using SPI
 *
 * Copyright (c) 2015, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *		spock_apply_spi.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef SPOCK_APPLY_SPI_H
#define SPOCK_APPLY_SPI_H

#include "spock_relcache.h"
#include "spock_proto_native.h"

extern void spock_apply_spi_begin(void);
extern void spock_apply_spi_commit(void);

extern void spock_apply_spi_insert(SpockRelation *rel,
									   SpockTupleData *newtup);
extern void spock_apply_spi_update(SpockRelation *rel,
									   SpockTupleData *oldtup,
									   SpockTupleData *newtup);
extern void spock_apply_spi_delete(SpockRelation *rel,
									   SpockTupleData *oldtup);

extern bool spock_apply_spi_can_mi(SpockRelation *rel);
extern void spock_apply_spi_mi_add_tuple(SpockRelation *rel,
											 SpockTupleData *tup);
extern void spock_apply_spi_mi_finish(SpockRelation *rel);

#endif /* SPOCK_APPLY_SPI_H */

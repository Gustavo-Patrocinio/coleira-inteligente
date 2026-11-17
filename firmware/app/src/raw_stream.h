/*
 * Raw dump mode (ADR 0014): the app firmware also serves the logger's raw data service
 * (ADR 0010, contract 4.4 packets), so dataset collection works without reflashing.
 * Streaming runs only while a client is subscribed; recognition keeps running meanwhile.
 */
#ifndef COLLAR_RAW_STREAM_H_
#define COLLAR_RAW_STREAM_H_

#include <stdbool.h>

#include "imu.h"

void raw_stream_init(void);

/* Called by the sampler for every 20 ms sample; cheap no-op when nobody is subscribed. */
void raw_stream_push(const struct imu_sample *s);

bool raw_stream_active(void);

#endif /* COLLAR_RAW_STREAM_H_ */

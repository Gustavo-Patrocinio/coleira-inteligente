/*
 * Raw BLE data packet, contract 4.4 (little-endian):
 *   0  uint8   version (=1)
 *   1  uint8   type (0x01 = raw)
 *   2  uint16  seq (wraps around)
 *   4  uint32  device_ms (uptime of the first sample)
 *   8  int16 x 6 x 10  samples (ax, ay, az, gx, gy, gz)
 * The Python side (ml/src/coleira_ml/raw_packet.py) mirrors this and is unit-tested.
 */
#ifndef COLLAR_PACKET_H_
#define COLLAR_PACKET_H_

#include <stddef.h>
#include <stdint.h>

#define RAW_PKT_VERSION     1
#define RAW_PKT_TYPE_RAW    0x01
#define RAW_PKT_CHANNELS    6
#define RAW_PKT_SAMPLES     10
#define RAW_PKT_HEADER_SIZE 8
#define RAW_PKT_SIZE        (RAW_PKT_HEADER_SIZE + RAW_PKT_SAMPLES * RAW_PKT_CHANNELS * 2)

struct raw_sample {
	int16_t v[RAW_PKT_CHANNELS]; /* ax, ay, az, gx, gy, gz (raw, contract full scale) */
};

/* Writes exactly RAW_PKT_SIZE bytes into buf. */
void raw_packet_pack(uint8_t buf[RAW_PKT_SIZE], uint16_t seq, uint32_t device_ms,
		     const struct raw_sample samples[RAW_PKT_SAMPLES]);

#endif /* COLLAR_PACKET_H_ */

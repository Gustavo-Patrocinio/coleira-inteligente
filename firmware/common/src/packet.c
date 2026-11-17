#include "packet.h"

#include <zephyr/sys/byteorder.h>

void raw_packet_pack(uint8_t buf[RAW_PKT_SIZE], uint16_t seq, uint32_t device_ms,
		     const struct imu_sample samples[RAW_PKT_SAMPLES])
{
	buf[0] = RAW_PKT_VERSION;
	buf[1] = RAW_PKT_TYPE_RAW;
	sys_put_le16(seq, &buf[2]);
	sys_put_le32(device_ms, &buf[4]);

	uint8_t *p = &buf[RAW_PKT_HEADER_SIZE];

	for (size_t i = 0; i < RAW_PKT_SAMPLES; i++) {
		for (size_t c = 0; c < RAW_PKT_CHANNELS; c++) {
			sys_put_le16((uint16_t)samples[i].v[c], p);
			p += 2;
		}
	}
}

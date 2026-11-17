/*
 * Collar logger (Phase 1): samples the IMU at 50 Hz while a client is subscribed and
 * streams contract 4.4 packets (10 samples each, 5 packets/s) over BLE.
 *
 *   sampler thread:  20 ms timer → imu_read → 10 samples → packet → queue
 *   sender thread:   queue → BLE notify (retries briefly when the stack is busy)
 *
 * `seq` counts every packet created, so drops on the collar (full queue) show up as gaps
 * on the receiving side exactly like radio losses (ADR 0010).
 */
#include <errno.h>
#include <string.h>

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/atomic.h>

#include "ble_raw.h"
#include "imu.h"
#include "packet.h"

LOG_MODULE_REGISTER(main, LOG_LEVEL_INF);

#define SAMPLE_PERIOD   K_MSEC(20)
#define QUEUE_PACKETS   50 /* 10 s of data buffered while the link is busy */
#define SEND_RETRIES    20
#define SEND_RETRY_WAIT K_MSEC(5)

K_MSGQ_DEFINE(pkt_q, RAW_PKT_SIZE, QUEUE_PACKETS, 4);
K_SEM_DEFINE(stream_sem, 0, 1);
static atomic_t streaming;

static void on_stream(bool enabled)
{
	atomic_set(&streaming, enabled);
	if (enabled) {
		k_sem_give(&stream_sem);
	}
}

static void enqueue(const uint8_t *pkt)
{
	if (k_msgq_put(&pkt_q, pkt, K_NO_WAIT) != 0) {
		uint8_t dropped[RAW_PKT_SIZE];

		/* Queue full: drop the OLDEST packet so the stream stays as fresh as possible. */
		(void)k_msgq_get(&pkt_q, dropped, K_NO_WAIT);
		(void)k_msgq_put(&pkt_q, pkt, K_NO_WAIT);
	}
}

static void sampler_thread(void *a, void *b, void *c)
{
	ARG_UNUSED(a);
	ARG_UNUSED(b);
	ARG_UNUSED(c);

	static struct raw_sample samples[RAW_PKT_SAMPLES];
	static uint8_t pkt[RAW_PKT_SIZE];
	struct k_timer timer;
	uint16_t seq = 0;
	uint32_t errors = 0;

	k_timer_init(&timer, NULL, NULL);

	for (;;) {
		k_sem_take(&stream_sem, K_FOREVER);
		LOG_INF("streaming started");
		k_msgq_purge(&pkt_q);
		k_timer_start(&timer, SAMPLE_PERIOD, SAMPLE_PERIOD);

		size_t n = 0;
		uint32_t first_ms = 0;

		while (atomic_get(&streaming)) {
			k_timer_status_sync(&timer);
			if (n == 0) {
				first_ms = k_uptime_get_32();
			}
			if (imu_read(&samples[n]) != 0) {
				/* Keep timing intact: repeat the previous sample and count the error. */
				samples[n] = samples[n > 0 ? n - 1 : 0];
				errors++;
			}
			if (++n == RAW_PKT_SAMPLES) {
				raw_packet_pack(pkt, seq++, first_ms, samples);
				enqueue(pkt);
				n = 0;
			}
		}
		k_timer_stop(&timer);
		LOG_INF("streaming stopped (seq=%u, imu errors=%u)", seq, errors);
	}
}

static void sender_thread(void *a, void *b, void *c)
{
	ARG_UNUSED(a);
	ARG_UNUSED(b);
	ARG_UNUSED(c);

	static uint8_t pkt[RAW_PKT_SIZE];
	uint32_t sent = 0, dropped = 0;

	for (;;) {
		k_msgq_get(&pkt_q, pkt, K_FOREVER);

		int err = -ENOMEM;

		for (int i = 0; i < SEND_RETRIES && err == -ENOMEM; i++) {
			err = ble_raw_send(pkt, sizeof(pkt));
			if (err == -ENOMEM) {
				k_sleep(SEND_RETRY_WAIT);
			}
		}
		if (err == 0) {
			sent++;
		} else {
			dropped++;
			if (err == -EMSGSIZE) {
				LOG_WRN("MTU too small for %u-byte packets", (unsigned)sizeof(pkt));
			}
		}
		if ((sent + dropped) % 300 == 0) { /* once a minute at 5 packets/s */
			LOG_INF("packets sent=%u dropped=%u", sent, dropped);
		}
	}
}

K_THREAD_DEFINE(sampler, 1536, sampler_thread, NULL, NULL, NULL, 3, 0, 0);
K_THREAD_DEFINE(sender, 1536, sender_thread, NULL, NULL, NULL, 5, 0, 0);

int main(void)
{
	int err = imu_init();

	if (err) {
		LOG_ERR("IMU init failed (%d); check the board is the Sense variant", err);
		return err;
	}
	err = ble_raw_init(on_stream);
	if (err) {
		return err;
	}
	LOG_INF("collar logger ready");
	return 0;
}

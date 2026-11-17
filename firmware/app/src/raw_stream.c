/*
 * Raw dump mode (ADR 0014): same GATT service and packets as firmware/logger (ADR 0010):
 *   service c01a0000-7e3b-4c5e-9d2a-5f1e8b6a2c10
 *   notify  c01a0001-7e3b-4c5e-9d2a-5f1e8b6a2c10  (contract 4.4, 10 samples, 5 packets/s)
 * The sampler packs packets; a low-priority sender thread notifies them, so a busy radio
 * never delays sampling or inference. Drops are visible as `seq` gaps (ADR 0010).
 */
#include "raw_stream.h"

#include <errno.h>

#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/atomic.h>

#include "packet.h"

LOG_MODULE_REGISTER(raw_stream, LOG_LEVEL_INF);

#define RAW_SVC_UUID_VAL  BT_UUID_128_ENCODE(0xc01a0000, 0x7e3b, 0x4c5e, 0x9d2a, 0x5f1e8b6a2c10)
#define RAW_CHAR_UUID_VAL BT_UUID_128_ENCODE(0xc01a0001, 0x7e3b, 0x4c5e, 0x9d2a, 0x5f1e8b6a2c10)
#define QUEUE_PACKETS     25 /* 5 s buffered while the link is busy */
#define SEND_RETRIES      20

static struct bt_uuid_128 raw_svc_uuid = BT_UUID_INIT_128(RAW_SVC_UUID_VAL);
static struct bt_uuid_128 raw_char_uuid = BT_UUID_INIT_128(RAW_CHAR_UUID_VAL);

K_MSGQ_DEFINE(raw_q, RAW_PKT_SIZE, QUEUE_PACKETS, 4);
static atomic_t active;
static struct bt_conn *conn;

static void ccc_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
	ARG_UNUSED(attr);
	bool on = value == BT_GATT_CCC_NOTIFY;

	atomic_set(&active, on);
	LOG_INF("raw dump %s", on ? "on" : "off");
}

BT_GATT_SERVICE_DEFINE(raw_svc,
	BT_GATT_PRIMARY_SERVICE(&raw_svc_uuid),
	BT_GATT_CHARACTERISTIC(&raw_char_uuid.uuid, BT_GATT_CHRC_NOTIFY, BT_GATT_PERM_NONE,
			       NULL, NULL, NULL),
	BT_GATT_CCC(ccc_changed, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
);

static void connected(struct bt_conn *c, uint8_t err)
{
	if (!err) {
		conn = bt_conn_ref(c);
	}
}

static void disconnected(struct bt_conn *c, uint8_t reason)
{
	ARG_UNUSED(c);
	ARG_UNUSED(reason);
	atomic_set(&active, false);
	if (conn) {
		bt_conn_unref(conn);
		conn = NULL;
	}
}

BT_CONN_CB_DEFINE(raw_conn_cb) = {
	.connected = connected,
	.disconnected = disconnected,
};

bool raw_stream_active(void)
{
	return atomic_get(&active);
}

void raw_stream_push(const struct imu_sample *s)
{
	static struct imu_sample samples[RAW_PKT_SAMPLES];
	static uint8_t pkt[RAW_PKT_SIZE];
	static size_t n;
	static uint32_t first_ms;
	static uint16_t seq;

	if (!atomic_get(&active)) {
		n = 0; /* the next stream starts on a fresh packet */
		return;
	}
	if (n == 0) {
		first_ms = k_uptime_get_32();
	}
	samples[n] = *s;
	if (++n < RAW_PKT_SAMPLES) {
		return;
	}
	n = 0;
	raw_packet_pack(pkt, seq++, first_ms, samples);
	if (k_msgq_put(&raw_q, pkt, K_NO_WAIT) != 0) {
		uint8_t old[RAW_PKT_SIZE];

		/* full: drop the oldest so the stream stays fresh */
		(void)k_msgq_get(&raw_q, old, K_NO_WAIT);
		(void)k_msgq_put(&raw_q, pkt, K_NO_WAIT);
	}
}

static void sender_thread(void *a, void *b, void *c)
{
	ARG_UNUSED(a);
	ARG_UNUSED(b);
	ARG_UNUSED(c);
	static uint8_t pkt[RAW_PKT_SIZE];

	for (;;) {
		k_msgq_get(&raw_q, pkt, K_FOREVER);
		int err = -ENOMEM;

		for (int i = 0; i < SEND_RETRIES && err == -ENOMEM && conn; i++) {
			err = bt_gatt_notify(conn, &raw_svc.attrs[1], pkt, sizeof(pkt));
			if (err == -ENOMEM) {
				k_sleep(K_MSEC(5));
			}
		}
	}
}

/* lowest priority of the app threads: never delays sampling (3) or inference (6) */
K_THREAD_DEFINE(raw_sender, 1024, sender_thread, NULL, NULL, NULL, 8, 0, 0);

void raw_stream_init(void)
{
	k_msgq_purge(&raw_q);
}

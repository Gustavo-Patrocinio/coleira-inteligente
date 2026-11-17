/*
 * Summary sync service (contract 4.8 / ADR 0013):
 *   c01a0100  service
 *   c01a0101  Time     write   uint32 epoch_s
 *   c01a0102  Control  write   0x01 + uint32 since_minute_ts  |  0x02 (status)
 *   c01a0103  Data     notify  k × 15-byte records
 *   c01a0104  Status   read/notify  16 bytes
 * Sending runs on a work item so the BT thread is never blocked by flash reads.
 */
#include <stdbool.h>
#include <string.h>

#include "ble_sync.h"
#include "summary_store.h"

#include <errno.h>

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/byteorder.h>

LOG_MODULE_REGISTER(ble_sync, LOG_LEVEL_INF);

#define UUID_(n) BT_UUID_128_ENCODE(0xc01a0100 + (n), 0x7e3b, 0x4c5e, 0x9d2a, 0x5f1e8b6a2c10)

static struct bt_uuid_128 svc_uuid = BT_UUID_INIT_128(UUID_(0));
static struct bt_uuid_128 time_uuid = BT_UUID_INIT_128(UUID_(1));
static struct bt_uuid_128 ctrl_uuid = BT_UUID_INIT_128(UUID_(2));
static struct bt_uuid_128 data_uuid = BT_UUID_INIT_128(UUID_(3));
static struct bt_uuid_128 status_uuid = BT_UUID_INIT_128(UUID_(4));

#define STATUS_SIZE      16
#define MAX_PER_NOTIFY   16
#define KIND_INFO        0x80
#define KIND_SYNC_DONE   0x81
#define OP_SEND_SINCE    0x01
#define OP_STATUS        0x02

static struct bt_conn *conn;
static ble_time_cb time_cb;
static uint8_t battery;
static bool clock_ok;
static uint32_t since_ts;
static uint8_t status_buf[STATUS_SIZE];

static void build_status(uint8_t kind, uint32_t count)
{
	struct store_stats s = store_stats();

	status_buf[0] = kind;
	status_buf[1] = clock_ok;
	status_buf[2] = battery;
	status_buf[3] = 0;
	sys_put_le32(kind == KIND_INFO ? s.count : count, &status_buf[4]);
	sys_put_le32(s.oldest_minute_ts, &status_buf[8]);
	sys_put_le32(s.newest_minute_ts, &status_buf[12]);
}

static ssize_t read_status(struct bt_conn *c, const struct bt_gatt_attr *attr, void *buf,
			   uint16_t len, uint16_t offset)
{
	build_status(KIND_INFO, 0);
	return bt_gatt_attr_read(c, attr, buf, len, offset, status_buf, sizeof(status_buf));
}

static struct k_work send_work;
static struct k_work status_work;

static ssize_t write_time(struct bt_conn *c, const struct bt_gatt_attr *attr, const void *buf,
			  uint16_t len, uint16_t offset, uint8_t flags)
{
	if (offset != 0 || len != 4) {
		return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
	}
	uint32_t epoch = sys_get_le32(buf);

	if (time_cb) {
		time_cb(epoch);
	}
	clock_ok = true;
	LOG_INF("clock set to %u", epoch);
	return len;
}

static ssize_t write_ctrl(struct bt_conn *c, const struct bt_gatt_attr *attr, const void *buf,
			  uint16_t len, uint16_t offset, uint8_t flags)
{
	const uint8_t *b = buf;

	if (offset != 0 || len < 1) {
		return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
	}
	if (b[0] == OP_SEND_SINCE && len == 5) {
		since_ts = sys_get_le32(&b[1]);
		k_work_submit(&send_work);
	} else if (b[0] == OP_STATUS && len == 1) {
		k_work_submit(&status_work);
	} else {
		return BT_GATT_ERR(BT_ATT_ERR_VALUE_NOT_ALLOWED);
	}
	return len;
}

BT_GATT_SERVICE_DEFINE(sync_svc,
	BT_GATT_PRIMARY_SERVICE(&svc_uuid),
	BT_GATT_CHARACTERISTIC(&time_uuid.uuid, BT_GATT_CHRC_WRITE, BT_GATT_PERM_WRITE, NULL,
			       write_time, NULL),
	BT_GATT_CHARACTERISTIC(&ctrl_uuid.uuid, BT_GATT_CHRC_WRITE, BT_GATT_PERM_WRITE, NULL,
			       write_ctrl, NULL),
	BT_GATT_CHARACTERISTIC(&data_uuid.uuid, BT_GATT_CHRC_NOTIFY, BT_GATT_PERM_NONE, NULL, NULL,
			       NULL),
	BT_GATT_CCC(NULL, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
	BT_GATT_CHARACTERISTIC(&status_uuid.uuid, BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY,
			       BT_GATT_PERM_READ, read_status, NULL, NULL),
	BT_GATT_CCC(NULL, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
);

/* attribute indices: 0 svc, 1-2 time, 3-4 ctrl, 5-6 data, 7 ccc, 8-9 status, 10 ccc */
#define ATTR_DATA   (&sync_svc.attrs[5])
#define ATTR_STATUS (&sync_svc.attrs[8])

struct batch {
	uint8_t buf[MAX_PER_NOTIFY * SB_RECORD_SIZE];
	int per_notify;
	int n;
	uint32_t sent;
	int err;
};

static int flush_batch(struct batch *b)
{
	if (b->n == 0) {
		return 0;
	}
	int err;

	/* the stack may be out of buffers for a moment: retry briefly */
	for (int i = 0; i < 50; i++) {
		err = bt_gatt_notify(conn, ATTR_DATA, b->buf, b->n * SB_RECORD_SIZE);
		if (err != -ENOMEM) {
			break;
		}
		k_sleep(K_MSEC(5));
	}
	if (err == 0) {
		b->sent += b->n;
	}
	b->n = 0;
	return err;
}

static int add_record(const uint8_t record[SB_RECORD_SIZE], void *user)
{
	struct batch *b = user;

	memcpy(&b->buf[b->n * SB_RECORD_SIZE], record, SB_RECORD_SIZE);
	if (++b->n == b->per_notify) {
		b->err = flush_batch(b);
	}
	return b->err; /* non-zero stops the walk (e.g. disconnected) */
}

static void send_fn(struct k_work *w)
{
	ARG_UNUSED(w);
	if (!conn) {
		return;
	}
	static struct batch b;
	int mtu_records = (bt_gatt_get_mtu(conn) - 3) / SB_RECORD_SIZE;

	b = (struct batch){.per_notify = CLAMP(mtu_records, 1, MAX_PER_NOTIFY)};
	store_walk_since(since_ts, add_record, &b);
	if (b.err == 0) {
		b.err = flush_batch(&b);
	}
	build_status(KIND_SYNC_DONE, b.sent);
	bt_gatt_notify(conn, ATTR_STATUS, status_buf, sizeof(status_buf));
	LOG_INF("sync since %u: %u records sent (err %d)", since_ts, b.sent, b.err);
}

static void status_fn(struct k_work *w)
{
	ARG_UNUSED(w);
	if (conn) {
		build_status(KIND_INFO, 0);
		bt_gatt_notify(conn, ATTR_STATUS, status_buf, sizeof(status_buf));
	}
}

/* ---------------------------------------------------------------- advertising */

static const struct bt_data ad[] = {
	BT_DATA_BYTES(BT_DATA_FLAGS, (BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR)),
	BT_DATA(BT_DATA_NAME_COMPLETE, CONFIG_BT_DEVICE_NAME, sizeof(CONFIG_BT_DEVICE_NAME) - 1),
};
static const struct bt_data sd[] = {
	BT_DATA_BYTES(BT_DATA_UUID128_ALL, UUID_(0)),
};

static void adv_fn(struct k_work *w)
{
	ARG_UNUSED(w);
	struct bt_le_adv_param p = BT_LE_ADV_PARAM_INIT(
		BT_LE_ADV_OPT_CONNECTABLE, BT_GAP_ADV_SLOW_INT_MIN, BT_GAP_ADV_SLOW_INT_MAX, NULL);
	int err = bt_le_adv_start(&p, ad, ARRAY_SIZE(ad), sd, ARRAY_SIZE(sd));

	if (err && err != -EALREADY) {
		LOG_ERR("advertising failed (%d)", err);
	}
}

static K_WORK_DEFINE(adv_work, adv_fn);

static void connected(struct bt_conn *c, uint8_t err)
{
	if (err) {
		return;
	}
	conn = bt_conn_ref(c);
	static struct bt_gatt_exchange_params mtu = {0};

	(void)bt_gatt_exchange_mtu(c, &mtu);
	(void)bt_conn_le_data_len_update(c, BT_LE_DATA_LEN_PARAM_MAX);
	LOG_INF("client connected");
}

static void disconnected(struct bt_conn *c, uint8_t reason)
{
	if (conn) {
		bt_conn_unref(conn);
		conn = NULL;
	}
	LOG_INF("client disconnected (0x%02x)", reason);
}

static void recycled(void)
{
	k_work_submit(&adv_work);
}

BT_CONN_CB_DEFINE(sync_conn_cb) = {
	.connected = connected,
	.disconnected = disconnected,
	.recycled = recycled,
};

int ble_sync_init(ble_time_cb on_time)
{
	time_cb = on_time;
	k_work_init(&send_work, send_fn);
	k_work_init(&status_work, status_fn);
	int err = bt_enable(NULL);

	if (err) {
		return err;
	}
	k_work_submit(&adv_work);
	return 0;
}

void ble_sync_set_state(uint8_t battery_pct, bool clock_set)
{
	battery = battery_pct;
	clock_ok = clock_set;
}

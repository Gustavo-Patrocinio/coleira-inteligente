/*
 * BLE peripheral with the raw data service (ADR 0010):
 *   service c01a0000-7e3b-4c5e-9d2a-5f1e8b6a2c10
 *   notify  c01a0001-7e3b-4c5e-9d2a-5f1e8b6a2c10  (contract 4.4 packets)
 */
#include "ble_raw.h"

#include <errno.h>

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/atomic.h>

LOG_MODULE_REGISTER(ble_raw, LOG_LEVEL_INF);

#define RAW_SVC_UUID_VAL  BT_UUID_128_ENCODE(0xc01a0000, 0x7e3b, 0x4c5e, 0x9d2a, 0x5f1e8b6a2c10)
#define RAW_CHAR_UUID_VAL BT_UUID_128_ENCODE(0xc01a0001, 0x7e3b, 0x4c5e, 0x9d2a, 0x5f1e8b6a2c10)

static struct bt_uuid_128 raw_svc_uuid = BT_UUID_INIT_128(RAW_SVC_UUID_VAL);
static struct bt_uuid_128 raw_char_uuid = BT_UUID_INIT_128(RAW_CHAR_UUID_VAL);

static struct bt_conn *current_conn;
static atomic_t notify_enabled;
static ble_raw_stream_cb stream_cb;

static void raw_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
	bool on = (value == BT_GATT_CCC_NOTIFY);

	atomic_set(&notify_enabled, on);
	LOG_INF("raw notifications %s", on ? "on" : "off");
	if (stream_cb) {
		stream_cb(on);
	}
}

BT_GATT_SERVICE_DEFINE(raw_svc,
	BT_GATT_PRIMARY_SERVICE(&raw_svc_uuid),
	BT_GATT_CHARACTERISTIC(&raw_char_uuid.uuid, BT_GATT_CHRC_NOTIFY, BT_GATT_PERM_NONE,
			       NULL, NULL, NULL),
	BT_GATT_CCC(raw_ccc_changed, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
);

/* ---------------------------------------------------------------- advertising */

static const struct bt_data ad[] = {
	BT_DATA_BYTES(BT_DATA_FLAGS, (BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR)),
	BT_DATA(BT_DATA_NAME_COMPLETE, CONFIG_BT_DEVICE_NAME, sizeof(CONFIG_BT_DEVICE_NAME) - 1),
};

static const struct bt_data sd[] = {
	BT_DATA_BYTES(BT_DATA_UUID128_ALL, RAW_SVC_UUID_VAL),
};

static void adv_start(struct k_work *work)
{
	ARG_UNUSED(work);
	struct bt_le_adv_param param = BT_LE_ADV_PARAM_INIT(
		BT_LE_ADV_OPT_CONNECTABLE, BT_GAP_ADV_FAST_INT_MIN_2, BT_GAP_ADV_FAST_INT_MAX_2,
		NULL);
	int err = bt_le_adv_start(&param, ad, ARRAY_SIZE(ad), sd, ARRAY_SIZE(sd));

	if (err && err != -EALREADY) {
		LOG_ERR("advertising failed (%d)", err);
		return;
	}
	LOG_INF("advertising as \"%s\"", CONFIG_BT_DEVICE_NAME);
}

static K_WORK_DEFINE(adv_work, adv_start);

/* ---------------------------------------------------------------- connection */

static void mtu_exchanged(struct bt_conn *conn, uint8_t err,
			  struct bt_gatt_exchange_params *params)
{
	ARG_UNUSED(params);
	LOG_INF("MTU exchange %s, MTU %u", err ? "failed" : "done", bt_gatt_get_mtu(conn));
}

static struct bt_gatt_exchange_params mtu_params = {.func = mtu_exchanged};

static void connected(struct bt_conn *conn, uint8_t err)
{
	if (err) {
		LOG_WRN("connection failed (0x%02x)", err);
		return;
	}
	current_conn = bt_conn_ref(conn);
	LOG_INF("connected");

	/* Ask for what a 128-byte packet stream needs (ADR 0010); the central may refuse. */
	(void)bt_gatt_exchange_mtu(conn, &mtu_params);
	(void)bt_conn_le_data_len_update(conn, BT_LE_DATA_LEN_PARAM_MAX);
	(void)bt_conn_le_phy_update(conn, BT_CONN_LE_PHY_PARAM_2M);

	struct bt_le_conn_param cp = BT_LE_CONN_PARAM_INIT(12, 24, 0, 400); /* 15–30 ms */

	(void)bt_conn_le_param_update(conn, &cp);
}

static void disconnected(struct bt_conn *conn, uint8_t reason)
{
	LOG_INF("disconnected (0x%02x)", reason);
	atomic_set(&notify_enabled, false);
	if (stream_cb) {
		stream_cb(false);
	}
	if (current_conn) {
		bt_conn_unref(current_conn);
		current_conn = NULL;
	}
}

static void recycled(void)
{
	k_work_submit(&adv_work); /* connection object freed: advertise again */
}

BT_CONN_CB_DEFINE(conn_callbacks) = {
	.connected = connected,
	.disconnected = disconnected,
	.recycled = recycled,
};

/* ---------------------------------------------------------------- public API */

int ble_raw_init(ble_raw_stream_cb cb)
{
	stream_cb = cb;

	int err = bt_enable(NULL);

	if (err) {
		LOG_ERR("bt_enable failed (%d)", err);
		return err;
	}
	k_work_submit(&adv_work);
	return 0;
}

int ble_raw_send(const uint8_t *buf, size_t len)
{
	struct bt_conn *conn = current_conn;

	if (!conn || !atomic_get(&notify_enabled)) {
		return -ENOTCONN;
	}
	if (bt_gatt_get_mtu(conn) < len + 3) {
		return -EMSGSIZE;
	}
	/* attrs[1] is the characteristic declaration; the stack notifies its value. */
	return bt_gatt_notify(conn, &raw_svc.attrs[1], buf, len);
}

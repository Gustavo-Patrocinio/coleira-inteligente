#ifndef COLLAR_BLE_RAW_H_
#define COLLAR_BLE_RAW_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Called from the BT thread when a client enables/disables raw notifications. */
typedef void (*ble_raw_stream_cb)(bool enabled);

int ble_raw_init(ble_raw_stream_cb cb);

/* Sends one contract 4.4 packet. Returns 0, -ENOTCONN (no subscriber), -EMSGSIZE
 * (MTU too small) or -ENOMEM (stack buffers full, try again shortly). */
int ble_raw_send(const uint8_t *buf, size_t len);

#endif /* COLLAR_BLE_RAW_H_ */

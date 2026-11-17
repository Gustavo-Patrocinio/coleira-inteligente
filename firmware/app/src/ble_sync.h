/* BLE peripheral with the summary sync service (contract 4.8 / ADR 0013). */
#ifndef COLLAR_BLE_SYNC_H_
#define COLLAR_BLE_SYNC_H_

#include <stdbool.h>
#include <stdint.h>

/* Called (from the BT thread) when a client writes the current epoch time. */
typedef void (*ble_time_cb)(uint32_t epoch_s);

int ble_sync_init(ble_time_cb on_time);

/* Battery and clock state reported in the Status characteristic. */
void ble_sync_set_state(uint8_t battery_pct, bool clock_set);

#endif /* COLLAR_BLE_SYNC_H_ */

/* OTA health check (ADR 0015): a freshly updated image runs in MCUboot's "test" state and is
 * reverted on the next reset unless it confirms itself. main() calls ota_confirm_later() only
 * after the IMU, storage, BLE and model all came up, so an image that cannot even start goes
 * back to the previous one. No-op in builds without MCUboot (the UF2 variant). */
#pragma once

#include <zephyr/kernel.h>

#ifdef CONFIG_BOOTLOADER_MCUBOOT
void ota_confirm_later(k_timeout_t delay);
#else
static inline void ota_confirm_later(k_timeout_t delay)
{
	ARG_UNUSED(delay);
}
#endif

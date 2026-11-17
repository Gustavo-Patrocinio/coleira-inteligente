#include "ota.h"

#include <zephyr/dfu/mcuboot.h>
#include <zephyr/logging/log.h>

LOG_MODULE_REGISTER(ota, LOG_LEVEL_INF);

static void confirm_work_fn(struct k_work *work)
{
	ARG_UNUSED(work);
	if (boot_is_img_confirmed()) {
		return;
	}
	int err = boot_write_img_confirmed();

	if (err) {
		LOG_ERR("could not confirm the new image (%d); it reverts on the next reset", err);
	} else {
		LOG_INF("new image confirmed");
	}
}

static K_WORK_DELAYABLE_DEFINE(confirm_work, confirm_work_fn);

void ota_confirm_later(k_timeout_t delay)
{
	/* the delay lets the sampler and inference threads run for a while first */
	k_work_schedule(&confirm_work, delay);
}

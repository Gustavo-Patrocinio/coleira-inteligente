/*
 * IMU access through Zephyr's generic sensor API (ADR 0010): values come in m/s² and rad/s
 * and are converted back to int16 at the contract's full scale. Swapping the IMU (Phase 5)
 * only changes the devicetree node and Kconfig, not this conversion.
 */
#include "imu.h"

#include <errno.h>
#include <math.h>

#include <zephyr/device.h>
#include <zephyr/drivers/sensor.h>
#include <zephyr/logging/log.h>

LOG_MODULE_REGISTER(imu, LOG_LEVEL_INF);

#define STANDARD_GRAVITY 9.80665f
#define RAD_TO_DEG       57.29577951f

static const struct device *const imu = DEVICE_DT_GET_ONE(st_lsm6dsl);

static float to_float(const struct sensor_value *v)
{
	return (float)v->val1 + (float)v->val2 / 1000000.0f;
}

static int16_t to_raw(float value, float full_scale)
{
	float r = roundf(value / full_scale * 32768.0f);

	if (r > 32767.0f) {
		return INT16_MAX;
	}
	if (r < -32768.0f) {
		return INT16_MIN;
	}
	return (int16_t)r;
}

int imu_init(void)
{
	if (!device_is_ready(imu)) {
		LOG_ERR("IMU %s not ready", imu->name);
		return -ENODEV;
	}
	LOG_INF("IMU %s ready (accel ±%d g, gyro ±%d dps)", imu->name, (int)IMU_ACCEL_FS_G,
		(int)IMU_GYRO_FS_DPS);
	return 0;
}

int imu_read(struct raw_sample *out)
{
	struct sensor_value a[3], g[3];
	int err = sensor_sample_fetch(imu);

	if (err) {
		return err;
	}
	err = sensor_channel_get(imu, SENSOR_CHAN_ACCEL_XYZ, a);
	if (err) {
		return err;
	}
	err = sensor_channel_get(imu, SENSOR_CHAN_GYRO_XYZ, g);
	if (err) {
		return err;
	}
	for (int i = 0; i < 3; i++) {
		out->v[i] = to_raw(to_float(&a[i]) / STANDARD_GRAVITY, IMU_ACCEL_FS_G);
		out->v[3 + i] = to_raw(to_float(&g[i]) * RAD_TO_DEG, IMU_GYRO_FS_DPS);
	}
	return 0;
}

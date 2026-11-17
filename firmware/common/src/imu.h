/* IMU access shared by the logger and the app firmware (ADR 0010). */
#ifndef COLLAR_IMU_H_
#define COLLAR_IMU_H_

#include <stdint.h>

/* Full scale of the raw int16 values (contract 4.2 / ADR 0005). */
#define IMU_ACCEL_FS_G  16.0f
#define IMU_GYRO_FS_DPS 2000.0f
#define IMU_CHANNELS    6

struct imu_sample {
	int16_t v[IMU_CHANNELS]; /* ax, ay, az, gx, gy, gz (raw, contract full scale) */
};

int imu_init(void);

/* Reads the latest accel + gyro sample and converts it to raw int16 at the contract's
 * full scale. Returns 0 on success, a negative errno otherwise. */
int imu_read(struct imu_sample *out);

#endif /* COLLAR_IMU_H_ */

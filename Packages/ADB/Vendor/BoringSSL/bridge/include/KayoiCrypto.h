#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
int kayoi_android_public_key(const uint8_t *der, size_t der_size, uint8_t *output, size_t output_size);
#ifdef __cplusplus
}
#endif

#include "KayoiSPAKE.h"

#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
void *diskit_spake_new(int server);
void diskit_spake_free(void *context);
int diskit_spake_message(void *context, const uint8_t *password, size_t password_size,
                        uint8_t *output, size_t *output_size, size_t capacity);
int diskit_spake_key(void *context, const uint8_t *peer, size_t peer_size,
                    uint8_t *output, size_t *output_size, size_t capacity);
#ifdef __cplusplus
}
#endif

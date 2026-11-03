#include "include/KayoiSPAKE.h"
#include <openssl/curve25519.h>

// AOSP pairing_auth 的角色名包含末尾的零字节。
void *kayoi_spake_new(int server) {
    static const uint8_t client_name[] = "adb pair client";
    static const uint8_t server_name[] = "adb pair server";
    if (server) {
        return SPAKE2_CTX_new(spake2_role_bob, server_name, sizeof(server_name),
                             client_name, sizeof(client_name));
    }
    return SPAKE2_CTX_new(spake2_role_alice, client_name, sizeof(client_name),
                         server_name, sizeof(server_name));
}

void kayoi_spake_free(void *context) {
    SPAKE2_CTX_free(static_cast<SPAKE2_CTX *>(context));
}

int kayoi_spake_message(void *context, const uint8_t *password, size_t password_size,
                        uint8_t *output, size_t *output_size, size_t capacity) {
    return SPAKE2_generate_msg(static_cast<SPAKE2_CTX *>(context), output, output_size,
                               capacity, password, password_size);
}

int kayoi_spake_key(void *context, const uint8_t *peer, size_t peer_size,
                    uint8_t *output, size_t *output_size, size_t capacity) {
    return SPAKE2_process_msg(static_cast<SPAKE2_CTX *>(context), output, output_size,
                              capacity, peer, peer_size);
}

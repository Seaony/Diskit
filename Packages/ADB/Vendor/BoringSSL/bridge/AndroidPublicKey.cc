/*
 * Adapted from Android Open Source Project libcrypto_utils/android_pubkey.cpp.
 * Copyright (C) 2016 The Android Open Source Project
 * Licensed under the Apache License, Version 2.0.
 * https://www.apache.org/licenses/LICENSE-2.0
 * Distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND.
 */
#include "include/KayoiCrypto.h"
#include <openssl/bn.h>
#include <openssl/rsa.h>

static void store32(uint8_t *output, uint32_t value) {
    for (int i = 0; i < 4; i++) output[i] = (uint8_t)(value >> (i * 8));
}

int kayoi_android_public_key(const uint8_t *der, size_t der_size, uint8_t *output, size_t output_size) {
    if (output_size != 524) return 0;
    bssl::UniquePtr<RSA> key(RSA_public_key_from_bytes(der, der_size));
    bssl::UniquePtr<BN_CTX> ctx(BN_CTX_new());
    bssl::UniquePtr<BIGNUM> r32(BN_new()), inverse(BN_new()), rr(BN_new());
    if (!key || RSA_size(key.get()) != 256 || !ctx || !r32 || !inverse || !rr) return 0;
    const BIGNUM *modulus = RSA_get0_n(key.get());
    if (!BN_set_bit(r32.get(), 32) || !BN_mod(inverse.get(), modulus, r32.get(), ctx.get()) ||
        !BN_mod_inverse(inverse.get(), inverse.get(), r32.get(), ctx.get()) ||
        !BN_sub(inverse.get(), r32.get(), inverse.get()) ||
        !BN_bn2le_padded(output + 8, 256, modulus) || !BN_set_bit(rr.get(), 2048) ||
        !BN_mod_sqr(rr.get(), rr.get(), modulus, ctx.get()) ||
        !BN_bn2le_padded(output + 264, 256, rr.get())) return 0;
    store32(output, 64);
    store32(output + 4, (uint32_t)BN_get_word(inverse.get()));
    store32(output + 520, (uint32_t)BN_get_word(RSA_get0_e(key.get())));
    return 1;
}

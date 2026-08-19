#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t little_u64(const unsigned char bytes[8]) {
    uint64_t value = 0;
    for (int i = 7; i >= 0; --i) value = (value << 8) | bytes[i];
    return value;
}

int main(int argc, char **argv) {
    if (argc != 3 || strcmp(argv[1], "unsupported") != 0) return 2;
    FILE *file = fopen(argv[2], "r+b");
    if (file == NULL) return 2;
    if (fseek(file, 0, SEEK_END) != 0) return 2;
    long length = ftell(file);
    if (length < 20 || fseek(file, length - 20, SEEK_SET) != 0) return 2;
    unsigned char encoded_length[8];
    if (fread(encoded_length, 1, sizeof(encoded_length), file) != sizeof(encoded_length)) return 2;
    uint64_t payload_length = little_u64(encoded_length);
    if (payload_length > (uint64_t)(length - 20)) return 2;
    long version_offset = length - 20 - (long)payload_length + (long)(sizeof("GLOLIAS-CRED-V1") - 1);
    if (fseek(file, version_offset, SEEK_SET) != 0) return 2;
    const unsigned char unsupported[2] = {0xff, 0x7f};
    if (fwrite(unsupported, 1, sizeof(unsupported), file) != sizeof(unsupported)) return 2;
    if (fclose(file) != 0) return 2;
    return 0;
}

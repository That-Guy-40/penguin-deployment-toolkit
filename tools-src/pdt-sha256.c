/* pdt-sha256.c - SHA-256 of files, and the check of a download against its sidecar.
 *
 *   pdt-sha256 <file>...                      one line per file: "<hex>  <file>" (sha256sum's format)
 *   pdt-sha256 --check <sidecar.json> <file>  hash <file>; compare with the sidecar's "sha256" value
 *
 * Why it exists: Windows PE (the Setup boot.wim) has no certutil, no PowerShell
 * and no .NET, so nothing on the machine can hash what it just downloaded.
 * 25-download runs this on image.wim against images/<name>.json before anything
 * is applied. Plain C99, no Windows headers: the same file compiles on Linux,
 * where it is checked against coreutils' sha256sum (spikes/2026-10-24-sha256-and-dism/).
 * Built by bin/build-tools (mingw-w64, pinned container, two identical builds).
 *
 * The sidecar rule: the first "sha256" key in the file (bin/stage-image writes it
 * at the top level), whose value must be a quoted string of exactly 64 hex
 * digits. Anything else is "no usable hash", exit 4, never "fine".
 *
 * Exit codes: 0 hashed (or: matches), 1 MISMATCH, 2 usage, 3 a file could not be
 * read, 4 the sidecar carries no usable sha256.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHUNK      (1u << 20)   /* bytes read per fread */
#define SIDECAR_MAX (1u << 20)  /* a sidecar is a few hundred bytes; more is not one */

/* ---- SHA-256 (FIPS 180-4) ------------------------------------------------- */

typedef struct {
    uint32_t h[8];
    uint64_t len;            /* bytes hashed so far */
    unsigned char blk[64];
    size_t fill;
} sha256_t;

static const uint32_t K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void sha256_init(sha256_t *s)
{
    static const uint32_t iv[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                   0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    memcpy(s->h, iv, sizeof iv);
    s->len = 0;
    s->fill = 0;
}

static void sha256_block(sha256_t *s, const unsigned char *p)
{
    uint32_t w[64], a, b, c, d, e, f, g, h, t1, t2;
    int i;
    for (i = 0; i < 16; i++)
        w[i] = ((uint32_t)p[4 * i] << 24) | ((uint32_t)p[4 * i + 1] << 16)
             | ((uint32_t)p[4 * i + 2] << 8) | (uint32_t)p[4 * i + 3];
    for (i = 16; i < 64; i++) {
        uint32_t s0 = ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    a = s->h[0]; b = s->h[1]; c = s->h[2]; d = s->h[3];
    e = s->h[4]; f = s->h[5]; g = s->h[6]; h = s->h[7];
    for (i = 0; i < 64; i++) {
        t1 = h + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i];
        t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
        h = g; g = f; f = e; e = d + t1;
        d = c; c = b; b = a; a = t1 + t2;
    }
    s->h[0] += a; s->h[1] += b; s->h[2] += c; s->h[3] += d;
    s->h[4] += e; s->h[5] += f; s->h[6] += g; s->h[7] += h;
}

static void sha256_update(sha256_t *s, const unsigned char *p, size_t n)
{
    s->len += n;
    if (s->fill) {
        size_t take = 64 - s->fill;
        if (take > n) take = n;
        memcpy(s->blk + s->fill, p, take);
        s->fill += take;
        p += take;
        n -= take;
        if (s->fill < 64) return;
        sha256_block(s, s->blk);
        s->fill = 0;
    }
    while (n >= 64) {
        sha256_block(s, p);
        p += 64;
        n -= 64;
    }
    if (n) {
        memcpy(s->blk, p, n);
        s->fill = n;
    }
}

static void sha256_final(sha256_t *s, unsigned char out[32])
{
    uint64_t bits = s->len * 8;
    int i;
    s->blk[s->fill++] = 0x80;
    if (s->fill > 56) {
        memset(s->blk + s->fill, 0, 64 - s->fill);
        sha256_block(s, s->blk);
        s->fill = 0;
    }
    memset(s->blk + s->fill, 0, 56 - s->fill);
    for (i = 0; i < 8; i++) s->blk[56 + i] = (unsigned char)(bits >> (56 - 8 * i));
    sha256_block(s, s->blk);
    for (i = 0; i < 8; i++) {
        out[4 * i]     = (unsigned char)(s->h[i] >> 24);
        out[4 * i + 1] = (unsigned char)(s->h[i] >> 16);
        out[4 * i + 2] = (unsigned char)(s->h[i] >> 8);
        out[4 * i + 3] = (unsigned char)(s->h[i]);
    }
}

/* ---- files ---------------------------------------------------------------- */

/* hash_file: hex[65] <- lowercase SHA-256 of the file. 0, or 3 if it cannot be read. */
static int hash_file(const char *path, char hex[65])
{
    static const char digits[] = "0123456789abcdef";
    unsigned char out[32];
    sha256_t s;
    size_t n;
    int err, i;
    FILE *f = fopen(path, "rb");
    unsigned char *buf;
    if (!f) {
        fprintf(stderr, "pdt-sha256: cannot open %s\n", path);
        return 3;
    }
    buf = malloc(CHUNK);
    if (!buf) {
        fclose(f);
        fputs("pdt-sha256: out of memory\n", stderr);
        return 3;
    }
    sha256_init(&s);
    while ((n = fread(buf, 1, CHUNK, f)) > 0) sha256_update(&s, buf, n);
    err = ferror(f);
    fclose(f);
    free(buf);
    if (err) {
        fprintf(stderr, "pdt-sha256: read error on %s\n", path);
        return 3;
    }
    sha256_final(&s, out);
    for (i = 0; i < 32; i++) {
        hex[2 * i] = digits[out[i] >> 4];
        hex[2 * i + 1] = digits[out[i] & 15];
    }
    hex[64] = 0;
    return 0;
}

static int is_hex(unsigned char c)
{
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

static int is_ws(unsigned char c)
{
    return c == ' ' || c == '\t' || c == '\r' || c == '\n';
}

/* sidecar_hash: hex[65] <- the sidecar's "sha256" value, lowercased.
 * 0, 3 if the file cannot be read, 4 if it carries no usable hash. */
static int sidecar_hash(const char *path, char hex[65])
{
    static const char key[] = "\"sha256\"";
    const size_t klen = sizeof key - 1;
    unsigned char *buf;
    size_t n, i, p;
    int err;
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "pdt-sha256: cannot open sidecar %s\n", path);
        return 3;
    }
    buf = malloc(SIDECAR_MAX + 1);
    if (!buf) {
        fclose(f);
        fputs("pdt-sha256: out of memory\n", stderr);
        return 3;
    }
    n = fread(buf, 1, SIDECAR_MAX + 1, f);
    err = ferror(f);
    fclose(f);
    if (err) {
        free(buf);
        fprintf(stderr, "pdt-sha256: read error on sidecar %s\n", path);
        return 3;
    }
    if (n > SIDECAR_MAX) {
        free(buf);
        fprintf(stderr, "pdt-sha256: %s is larger than a sidecar can be (%u bytes)\n", path, SIDECAR_MAX);
        return 4;
    }
    /* The first "sha256" key, byte-wise (no strstr: a NUL in the file must not hide the rest). */
    for (i = 0; i + klen <= n; i++)
        if (memcmp(buf + i, key, klen) == 0) break;
    if (i + klen > n) {
        free(buf);
        fprintf(stderr, "pdt-sha256: no \"sha256\" key in %s\n", path);
        return 4;
    }
    p = i + klen;
    while (p < n && is_ws(buf[p])) p++;
    if (p >= n || buf[p] != ':') goto bad;
    p++;
    while (p < n && is_ws(buf[p])) p++;
    if (p >= n || buf[p] != '"') goto bad;
    p++;
    if (p + 65 > n) goto bad;                /* 64 digits and the closing quote must fit */
    for (i = 0; i < 64; i++)
        if (!is_hex(buf[p + i])) goto bad;
    if (buf[p + 64] != '"') goto bad;        /* 65 digits, or not a string: not a hash */
    for (i = 0; i < 64; i++) {
        unsigned char c = buf[p + i];
        hex[i] = (char)((c >= 'A' && c <= 'F') ? c + ('a' - 'A') : c);
    }
    hex[64] = 0;
    free(buf);
    return 0;
bad:
    free(buf);
    fprintf(stderr, "pdt-sha256: the \"sha256\" value in %s is not a quoted string of 64 hex digits\n", path);
    return 4;
}

static int usage(void)
{
    fputs("usage: pdt-sha256 <file>...\n"
          "       pdt-sha256 --check <sidecar.json> <file>\n"
          "exit:  0 hashed / matches, 1 MISMATCH, 2 usage, 3 cannot read a file, 4 no usable sha256 in the sidecar\n",
          stderr);
    return 2;
}

int main(int argc, char **argv)
{
    char hex[65];
    int i, rc = 0;

    if (argc >= 2 && strcmp(argv[1], "--check") == 0) {
        char want[65];
        if (argc != 4) return usage();
        rc = sidecar_hash(argv[2], want);     /* the cheap part first: a bad sidecar fails before a 4 GB read */
        if (rc) return rc;
        rc = hash_file(argv[3], hex);
        if (rc) return rc;
        printf("%s  %s\n%s  %s (sidecar)\n", hex, argv[3], want, argv[2]);
        if (strcmp(hex, want) == 0) {
            puts("match");
            return (fflush(stdout) || ferror(stdout)) ? 3 : 0;   /* a full disk must not read as a match */
        }
        puts("MISMATCH: the file is not the one the sidecar describes");
        return 1;
    }
    if (argc < 2 || argv[1][0] == '-') return usage();
    for (i = 1; i < argc; i++) {
        int r = hash_file(argv[i], hex);
        if (r) {
            rc = r;
            continue;
        }
        printf("%s  %s\n", hex, argv[i]);
    }
    if (fflush(stdout) || ferror(stdout)) return 3;
    return rc;
}

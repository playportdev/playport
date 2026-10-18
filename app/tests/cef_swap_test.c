/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * cef_swap_test.c — cef_swap.c on the Linux host (pp test): the CEF substitution's
 * version guard (decision 0110, PLA-370). The exact file version 143.0.14.0 swaps;
 * near versions, a malformed or missing version resource, a write or create open,
 * a name outside CEF's runtime set, a file the payload lacks and a build without
 * the payload do not. Synthetic PE images stand in for libcef.dll.
 */
#include "cef_swap.h"

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int failures;

#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

enum { GOOD, BAD_SIGNATURE, BAD_KEY, NO_VERSION_TYPE, TRUNCATED, NOT_PE };

static void put16(unsigned char *p, unsigned v) { p[0] = v; p[1] = v >> 8; }
static void put32(unsigned char *p, unsigned v) { put16(p, v & 0xffff); put16(p + 2, v >> 16); }

/* A PE32+ image with one .rsrc section holding one RT_VERSION resource. */
static void make_pe(const char *path, unsigned ms, unsigned ls, int kind)
{
    static const char key[] = "VS_VERSION_INFO";
    unsigned char f[0x200 + 0xb4];
    unsigned char *r = f + 0x200, *v = r + 0x58;
    size_t i, len = sizeof(f);
    int fd;
    memset(f, 0, sizeof(f));
    f[0] = 'M'; f[1] = 'Z';
    put32(f + 0x3c, 0x40);
    memcpy(f + 0x40, "PE\0\0", 4);
    put16(f + 0x44, 0x8664);
    put16(f + 0x46, 1);                    /* one section */
    put16(f + 0x54, 240);                  /* SizeOfOptionalHeader, PE32+ */
    put16(f + 0x58, 0x20b);
    put32(f + 0x58 + 108, 16);             /* NumberOfRvaAndSizes */
    put32(f + 0x58 + 112 + 16, 0x1000);    /* the resource directory */
    put32(f + 0x58 + 112 + 20, 0xb4);
    memcpy(f + 0x148, ".rsrc", 5);
    put32(f + 0x148 + 8, 0xb4);
    put32(f + 0x148 + 12, 0x1000);
    put32(f + 0x148 + 16, 0xb4);
    put32(f + 0x148 + 20, 0x200);
    /* type 16 -> name 1 -> language 0x409 -> data entry */
    put16(r + 14, 1); put32(r + 16, kind == NO_VERSION_TYPE ? 3 : 16); put32(r + 20, 0x80000018);
    put16(r + 0x18 + 14, 1); put32(r + 0x18 + 16, 1); put32(r + 0x18 + 20, 0x80000030);
    put16(r + 0x30 + 14, 1); put32(r + 0x30 + 16, 0x409); put32(r + 0x30 + 20, 0x48);
    put32(r + 0x48, 0x1058); put32(r + 0x48 + 4, 92);
    put16(v, 92); put16(v + 2, 52);
    for (i = 0; i < sizeof(key); i++) put16(v + 6 + 2 * i, kind == BAD_KEY && i == 3 ? 'x' : key[i]);
    put32(v + 40, kind == BAD_SIGNATURE ? 0xfeef04bc : 0xfeef04bd);
    put32(v + 44, 0x10000);
    put32(v + 48, ms);
    put32(v + 52, ls);
    if (kind == NOT_PE) f[0] = 'Z';
    if (kind == TRUNCATED) len = 0x200 + 0x60;
    fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0644);
    if (fd < 0 || write(fd, f, len) != (ssize_t)len) { perror(path); exit(2); }
    close(fd);
}

static void touch(const char *root, const char *rel)
{
    char p[4096];
    int fd;
    snprintf(p, sizeof(p), "%s/%s", root, rel);
    fd = open(p, O_CREAT | O_WRONLY, 0644);
    if (fd < 0) { perror(p); exit(2); }
    close(fd);
}

static void sub(const char *root, const char *rel, char *out, size_t n)
{
    snprintf(out, n, "%s/%s", root, rel);
    mkdir(out, 0755);
}

/* Whether opening dir/rel read-only is swapped for the payload's path. */
static int swapped_to(const char *bundle, const char *dir, const char *rel, const char *want)
{
    char path[4096], expect[4096];
    char *got;
    int ok;
    snprintf(path, sizeof(path), "%s/%s", dir, rel);
    got = playport_cef_swap_path(path, 0x80100000u /* GENERIC_READ|SYNCHRONIZE */, 1, 0x20, bundle);
    if (!want) { ok = !got; free(got); return ok; }
    snprintf(expect, sizeof(expect), "%s/cef/143.0.14/%s", bundle, want);
    ok = got && !strcmp(got, expect);
    if (!ok) printf("  %s -> %s (want %s)\n", path, got ? got : "(none)", expect);
    free(got);
    return ok;
}

int main(void)
{
    const char *tmp = getenv("TMPDIR");
    char root[4096], bundle[4096], payload[4096], client[4096], path[4096], buf[256];
    unsigned ms = 0, ls = 0;
    struct { unsigned ms, ls; int kind, ok; } versions[] = {
        { 143u << 16, 14u << 16, GOOD, 1 },
        { 143u << 16, 13u << 16, GOOD, 0 },        /* 143.0.13.0 */
        { 143u << 16, (14u << 16) | 1, GOOD, 0 },  /* 143.0.14.1 */
        { 144u << 16, 14u << 16, GOOD, 0 },        /* 144.0.14.0 */
        { (143u << 16) | 1, 14u << 16, GOOD, 0 },  /* 143.1.14.0 */
    };
    int kinds[] = { BAD_SIGNATURE, BAD_KEY, NO_VERSION_TYPE, TRUNCATED, NOT_PE };
    size_t i;

    snprintf(root, sizeof(root), "%s/cef-swap-XXXXXX", tmp && *tmp ? tmp : "/tmp");
    if (!mkdtemp(root)) { perror("mkdtemp"); return 2; }

    /* The name set and its fast path. */
    CHECK(!strcmp(cef_swap_payload_name("Social Club", 11, "libcef.dll", buf, sizeof(buf)), "libcef.dll"));
    CHECK(!strcmp(cef_swap_payload_name("x", 1, "LIBCEF.DLL", buf, sizeof(buf)), "libcef.dll"));
    CHECK(!strcmp(cef_swap_payload_name("x", 1, "libegl.dll", buf, sizeof(buf)), "libEGL.dll"));
    CHECK(!strcmp(cef_swap_payload_name("x", 1, "vk_swiftshader_icd.json", buf, sizeof(buf)), "vk_swiftshader_icd.json"));
    CHECK(!strcmp(cef_swap_payload_name("x", 1, "chrome_elf.dll", buf, sizeof(buf)), "chrome_elf.dll"));
    CHECK(!strcmp(cef_swap_payload_name("x", 1, "v8_context_snapshot.bin", buf, sizeof(buf)), "v8_context_snapshot.bin"));
    CHECK(!strcmp(cef_swap_payload_name("x", 1, "icudtl.dat", buf, sizeof(buf)), "icudtl.dat"));
    CHECK(!strcmp(cef_swap_payload_name("x", 1, "resources.pak", buf, sizeof(buf)), "resources.pak"));
    CHECK(!strcmp(cef_swap_payload_name("Locales", 7, "en-US.pak", buf, sizeof(buf)), "locales/en-US.pak"));
    CHECK(!cef_swap_payload_name("x", 1, "socialclub.dll", buf, sizeof(buf)));
    CHECK(!cef_swap_payload_name("x", 1, "SocialClubHelper.exe", buf, sizeof(buf)));
    CHECK(!cef_swap_payload_name("x", 1, "other.pak", buf, sizeof(buf)));
    CHECK(!cef_swap_payload_name("x", 1, "libcef.dll.bak", buf, sizeof(buf)));
    CHECK(!cef_swap_payload_name("locales", 7, "libcef.dll", buf, sizeof(buf)));
    CHECK(!cef_swap_payload_name("locales", 7, ".pak", buf, sizeof(buf)));
    CHECK(!cef_swap_payload_name("locale", 6, "en-US.pak", buf, sizeof(buf)));

    /* The access-mask filter: reading only, an existing file only. */
    CHECK(cef_swap_read_only(0x80100000u, 1, 0x20));             /* GENERIC_READ|SYNCHRONIZE */
    CHECK(cef_swap_read_only(0x80u, 1, 0));                      /* FILE_READ_ATTRIBUTES */
    CHECK(cef_swap_read_only(0x20000000u | 0x80000000u, 1, 0));  /* GENERIC_EXECUTE|GENERIC_READ */
    CHECK(!cef_swap_read_only(0x40000000u, 1, 0));               /* GENERIC_WRITE */
    CHECK(!cef_swap_read_only(0x10000000u, 1, 0));               /* GENERIC_ALL */
    CHECK(!cef_swap_read_only(0x02000000u, 1, 0));               /* MAXIMUM_ALLOWED */
    CHECK(!cef_swap_read_only(0x80010000u, 1, 0));               /* DELETE */
    CHECK(!cef_swap_read_only(0x80000002u, 1, 0));               /* FILE_WRITE_DATA */
    CHECK(!cef_swap_read_only(0x80000004u, 1, 0));               /* FILE_APPEND_DATA */
    CHECK(!cef_swap_read_only(0x80000100u, 1, 0));               /* FILE_WRITE_ATTRIBUTES */
    CHECK(!cef_swap_read_only(0x80000010u, 1, 0));               /* FILE_WRITE_EA */
    CHECK(!cef_swap_read_only(0x80040000u, 1, 0));               /* WRITE_DAC */
    CHECK(!cef_swap_read_only(0x80000000u, 1, 0x1000));          /* FILE_DELETE_ON_CLOSE */
    CHECK(!cef_swap_read_only(0x80000000u, 3, 0));               /* FILE_OPEN_IF */
    CHECK(!cef_swap_read_only(0x80000000u, 0, 0));               /* FILE_SUPERSEDE */
    CHECK(!cef_swap_read_only(0x80000000u, 2, 0));               /* FILE_CREATE */

    /* The version resource: exact, near, malformed. */
    snprintf(path, sizeof(path), "%s/v.dll", root);
    make_pe(path, 143u << 16, 14u << 16, GOOD);
    CHECK(!cef_swap_file_version(path, &ms, &ls) && ms == 143u << 16 && ls == 14u << 16);
    for (i = 0; i < sizeof(kinds) / sizeof(*kinds); i++) {
        make_pe(path, 143u << 16, 14u << 16, kinds[i]);
        CHECK(cef_swap_file_version(path, &ms, &ls) == -1);
    }
    snprintf(path, sizeof(path), "%s/absent.dll", root);
    CHECK(cef_swap_file_version(path, &ms, &ls) == -1);

    /* A build without the payload: every client is left alone. */
    sub(root, "bundle-none", bundle, sizeof(bundle));
    sub(root, "client0", client, sizeof(client));
    make_pe(strcat(strcpy(path, client), "/libcef.dll"), 143u << 16, 14u << 16, GOOD);
    touch(client, "icudtl.dat");
    cef_swap_reset();
    CHECK(swapped_to(bundle, client, "icudtl.dat", NULL));

    /* The payload, and clients of each version beside it. */
    sub(root, "bundle", bundle, sizeof(bundle));
    sub(bundle, "cef", path, sizeof(path));
    sub(path, "143.0.14", payload, sizeof(payload));
    sub(payload, "locales", path, sizeof(path));
    touch(payload, "libcef.dll");
    touch(payload, "chrome_elf.dll");
    touch(payload, "icudtl.dat");
    touch(payload, "resources.pak");
    touch(payload, "locales/en-US.pak");
    for (i = 0; i < sizeof(versions) / sizeof(*versions); i++) {
        char name[32];
        snprintf(name, sizeof(name), "client%zu", i + 1);
        sub(root, name, client, sizeof(client));
        sub(client, "locales", path, sizeof(path));
        make_pe(strcat(strcpy(path, client), "/libcef.dll"), versions[i].ms, versions[i].ls, versions[i].kind);
        touch(client, "icudtl.dat");
        touch(client, "locales/en-US.pak");
        cef_swap_reset();
        CHECK(swapped_to(bundle, client, "libcef.dll", versions[i].ok ? "libcef.dll" : NULL));
        CHECK(swapped_to(bundle, client, "icudtl.dat", versions[i].ok ? "icudtl.dat" : NULL));
        CHECK(swapped_to(bundle, client, "locales/en-US.pak", versions[i].ok ? "locales/en-US.pak" : NULL));
        /* The decision is cached: the second open agrees. */
        CHECK(swapped_to(bundle, client, "icudtl.dat", versions[i].ok ? "icudtl.dat" : NULL));
    }

    /* With the matching client (client1): what is not swapped. */
    snprintf(client, sizeof(client), "%s/client1", root);
    cef_swap_reset();
    touch(client, "socialclub.dll");
    touch(client, "chrome_100_percent.pak");
    CHECK(swapped_to(bundle, client, "socialclub.dll", NULL));
    CHECK(swapped_to(bundle, client, "chrome_100_percent.pak", NULL));  /* not in this payload */
    snprintf(path, sizeof(path), "%s/icudtl.dat", client);
    {
        char *got = playport_cef_swap_path(path, 0x40000000u, 1, 0, bundle);
        CHECK(!got);
        free(got);
        got = playport_cef_swap_path(path, 0x80000000u, 3, 0, bundle);
        CHECK(!got);
        free(got);
        got = playport_cef_swap_path(path, 0x80u, 1, 0, bundle);   /* an attribute query */
        CHECK(got != NULL);
        free(got);
    }
    /* A malformed resource beside the CEF files: no swap. */
    make_pe(strcat(strcpy(path, client), "/libcef.dll"), 143u << 16, 14u << 16, BAD_SIGNATURE);
    cef_swap_reset();
    CHECK(swapped_to(bundle, client, "icudtl.dat", NULL));
    /* The payload's own files are never swapped for themselves. */
    CHECK(swapped_to(bundle, payload, "icudtl.dat", NULL));

    if (failures) { printf("%d failure(s); scratch left in %s\n", failures, root); return 1; }
    printf("cef swap: name set, read-only filter, exact 143.0.14.0 guard, near and malformed versions, missing payload\n");
    {
        char cmd[4200];
        snprintf(cmd, sizeof(cmd), "rm -rf '%s'", root);
        if (system(cmd)) return 1;
    }
    return 0;
}

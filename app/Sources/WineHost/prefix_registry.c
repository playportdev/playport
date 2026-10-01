/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * prefix_registry — see include/prefix_registry.h.
 *
 * Plain POSIX C with no Apple headers.
 */

#include "prefix_registry.h"

#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct text {
    char *buf;
    size_t len;
};

static int read_all(const char *path, struct text *t)
{
    FILE *f = fopen(path, "rb");
    t->buf = NULL;
    t->len = 0;
    if (!f) return errno == ENOENT ? 0 : -1;
    size_t cap = 1 << 16;
    t->buf = malloc(cap + 1);
    for (;;) {
        if (!t->buf) {
            fclose(f);
            return -1;
        }
        size_t n = fread(t->buf + t->len, 1, cap - t->len, f);
        t->len += n;
        if (t->len < cap) break;
        cap *= 2;
        t->buf = realloc(t->buf, cap + 1);
    }
    int err = ferror(f);
    fclose(f);
    if (err) {
        free(t->buf);
        t->buf = NULL;
        return -1;
    }
    t->buf[t->len] = 0;
    return 1;
}

/* The key name of a "[name] <time>" line, as wineserver writes and reads it:
 * backslash escapes the next character, the first unescaped ']' ends it.
 * Returns its length (name starts at line + 1), or -1 if the line is not a key. */
static long key_name_len(const char *line, const char *end)
{
    if (line >= end || *line != '[') return -1;
    for (const char *p = line + 1; p < end && *p != '\n'; p++) {
        if (*p == '\\') {
            p++;
            continue;
        }
        if (*p == ']') return p - (line + 1);
    }
    return -1;
}

/* Key names compare case-insensitively (registry semantics; ASCII is enough
 * for what the seed holds, and a miss only appends a duplicate the server merges). */
struct name {
    const char *s;
    long n;
    const char *end;   /* hive keys: where the section's lines end */
};

static int name_cmp(const void *a, const void *b)
{
    const struct name *x = a, *y = b;
    long n = x->n < y->n ? x->n : y->n;
    for (long i = 0; i < n; i++) {
        int c = tolower((unsigned char)x->s[i]) - tolower((unsigned char)y->s[i]);
        if (c) return c;
    }
    return (x->n > y->n) - (x->n < y->n);
}

static const char *next_line(const char *p, const char *end)
{
    const char *nl = memchr(p, '\n', (size_t)(end - p));
    return nl ? nl + 1 : end;
}

/* The name of a value line ("name"=... or @=..., the default value), escapes
 * kept as written: both writers escape the same way. Returns its length
 * (name at *name), or -1 if the line is not a value. */
static long value_name(const char *line, const char *end, const char **name)
{
    if (line < end && *line == '@') {
        *name = line;
        return 0;
    }
    if (line >= end || *line != '"') return -1;
    for (const char *p = line + 1; p < end && *p != '\n'; p++) {
        if (*p == '\\') {
            p++;
            continue;
        }
        if (*p == '"') {
            *name = line + 1;
            return p - (line + 1);
        }
    }
    return -1;
}

/* A value's lines: its own and any continuation lines (a long hex value is
 * wrapped with a trailing backslash onto lines that start with spaces). */
static const char *value_end(const char *line, const char *end)
{
    const char *q = next_line(line, end);
    while (q < end && *q == ' ') q = next_line(q, end);
    return q;
}

/* The comment line app/tools/prefix-registry.py writes directly before a
 * profile section (MARKER there); wineserver skips it as a comment. */
static const char marker[] = ";; playport:top-up\n";

/* Whether the line before line (which starts a line of buf) is the marker. */
static int marked(const char *buf, const char *line)
{
    size_t n = sizeof(marker) - 1;
    if ((size_t)(line - buf) < n || memcmp(line - n, marker, n)) return 0;
    return line - n == buf || line[-(long)n - 1] == '\n';
}

/* Whether any of the hive's sections for key (duplicates included) holds the
 * value named (v, vn). */
static int hive_has_value(const struct name *have, size_t nhave, const struct name *hit, const char *v, long vn)
{
    const struct name *lo = hit, *hi = hit;
    while (lo > have && !name_cmp(lo - 1, hit)) lo--;
    while (hi + 1 < have + nhave && !name_cmp(hi + 1, hit)) hi++;
    for (const struct name *k = lo; k <= hi; k++)
        for (const char *p = next_line(k->s - 1, k->end); p < k->end; p = next_line(p, k->end)) {
            const char *hv;
            long hn = value_name(p, k->end, &hv);
            struct name a = { hv, hn, NULL }, b = { v, vn, NULL };
            if (hn == vn && !name_cmp(&a, &b)) return 1;
        }
    return 0;
}

int prefix_registry_seed(const char *seed_path, const char *hive_path, char *err, size_t errlen)
{
    struct text seed, hive;
    int rc = read_all(seed_path, &seed);
    if (rc <= 0) {
        snprintf(err, errlen, "cannot read %s: %s", seed_path, rc ? strerror(errno) : "missing");
        return -1;
    }
    if (read_all(hive_path, &hive) < 0) {
        snprintf(err, errlen, "cannot read %s: %s", hive_path, strerror(errno));
        free(seed.buf);
        return -1;
    }
    const char *send = seed.buf + seed.len;

    /* The hive's existing key names, sorted for lookup. */
    struct name *have = NULL;
    size_t nhave = 0, caphave = 0;
    for (const char *p = hive.buf; hive.buf && p < hive.buf + hive.len; p = next_line(p, hive.buf + hive.len)) {
        long n = key_name_len(p, hive.buf + hive.len);
        if (n < 0) continue;
        if (nhave == caphave) {
            caphave = caphave ? caphave * 2 : 1024;
            have = realloc(have, caphave * sizeof(*have));
            if (!have) {
                snprintf(err, errlen, "out of memory");
                free(seed.buf);
                free(hive.buf);
                return -1;
            }
        }
        if (nhave) have[nhave - 1].end = p;
        have[nhave++] = (struct name){ p + 1, n, hive.buf + hive.len };
    }
    if (nhave) qsort(have, nhave, sizeof(*have), name_cmp);

    /* A new hive gets the seed's header (version line, root comment, #arch). */
    const char *first = seed.buf;
    while (first < send && key_name_len(first, send) < 0) first = next_line(first, send);

    char tmp[1200];
    snprintf(tmp, sizeof(tmp), "%s.seed-new", hive_path);
    FILE *out = fopen(tmp, "wb");
    if (!out) {
        snprintf(err, errlen, "cannot write %s: %s", tmp, strerror(errno));
        free(seed.buf);
        free(hive.buf);
        free(have);
        return -1;
    }
    if (hive.buf) {
        fwrite(hive.buf, 1, hive.len, out);
        if (hive.len && hive.buf[hive.len - 1] != '\n') fputc('\n', out);
    } else {
        fwrite(seed.buf, 1, (size_t)(first - seed.buf), out);
    }

    /* Each seed section runs from its "[key]" line to the next one (or to
     * the marker before it). A key the hive lacks gets the whole section. A
     * key it has is left alone, unless its section is marked: then it gets
     * the values it lacks, as a second section for that key, which the
     * server merges on load. The marked profile keys exist without the
     * seed's values: ntdll creates HKCU's Volatile Environment empty in
     * every process, shell32 User Shell Folders and ProfileList on first use. */
    int added = 0, topped = 0, nvalues = 0, total = 0;
    for (const char *p = first; p < send;) {
        long n = key_name_len(p, send);
        const char *q = next_line(p, send);
        while (q < send && key_name_len(q, send) < 0) q = next_line(q, send);
        const char *qe = marked(seed.buf, q) ? q - (sizeof(marker) - 1) : q;
        total++;
        struct name key = { p + 1, n, NULL };
        const struct name *hit = nhave ? bsearch(&key, have, nhave, sizeof(*have), name_cmp) : NULL;
        if (!hit) {
            if (hive.buf && !added && !topped) fputc('\n', out);
            fwrite(p, 1, (size_t)(qe - p), out);
            added++;
        } else if (marked(seed.buf, p)) {
            int opened = 0;
            for (const char *v = next_line(p, qe); v < qe;) {
                const char *vend = value_end(v, qe), *vname;
                long vn = value_name(v, qe, &vname);
                if (vn >= 0 && !hive_has_value(have, nhave, hit, vname, vn)) {
                    if (!opened) {
                        if (!added && !topped) fputc('\n', out);
                        fwrite(p, 1, (size_t)(next_line(p, qe) - p), out);
                        opened = 1;
                        topped++;
                    }
                    fwrite(v, 1, (size_t)(vend - v), out);
                    nvalues++;
                }
                v = vend;
            }
            if (opened) fputc('\n', out);
        }
        p = q;
    }
    int werr = ferror(out);
    if (fclose(out) || werr) werr = 1;
    free(seed.buf);
    free(hive.buf);
    free(have);

    if (werr) {
        snprintf(err, errlen, "write to %s failed", tmp);
        remove(tmp);
        return -1;
    }
    if (!added && !topped && nhave) {   /* nothing new: leave the hive untouched */
        remove(tmp);
        snprintf(err, errlen, "%d of %d seed keys present, marked ones with their values", total, total);
        return 0;
    }
    if (rename(tmp, hive_path)) {
        snprintf(err, errlen, "cannot replace %s: %s", hive_path, strerror(errno));
        remove(tmp);
        return -1;
    }
    snprintf(err, errlen, "%d of %d seed keys added, %d values added to %d present keys", added, total, nvalues,
             topped);
    return added + topped;
}

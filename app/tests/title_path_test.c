/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * title_path_test.c — title_path.c on the Linux host (pp test).
 *
 *   title_path_test                 the resolver's cases against a scratch prefix
 *   title_path_test PREFIX PATH     resolve one name; prints dos, dos_dir and
 *                                   unix_path on three lines (exit 1 if it fails)
 */
#include "title_path.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int failures;

#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

static void touch(const char *root, const char *rel)
{
    char p[2048];
    snprintf(p, sizeof(p), "%s/%s", root, rel);
    int fd = open(p, O_CREAT | O_WRONLY, 0644);
    if (fd >= 0) close(fd);
}

static void dir(const char *root, const char *rel)
{
    char p[2048];
    snprintf(p, sizeof(p), "%s/%s", root, rel);
    mkdir(p, 0755);
}

/* Resolve path and compare the result; want_dos NULL means only the rc matters. */
static void expect(const char *prefix, const char *path, int want_rc, const char *want_dos, const char *want_dir)
{
    title_path tp;
    char msg[512];
    int rc = title_path_resolve(prefix, path, &tp, msg, sizeof(msg));
    printf("%-4s %-44s -> %d %s\n", rc == want_rc ? "ok" : "BAD", path, rc, msg);
    CHECK(rc == want_rc);
    CHECK(msg[0]);
    if (rc || !want_dos) return;
    CHECK(!strcmp(tp.dos, want_dos));
    CHECK(!strcmp(tp.dos_dir, want_dir));
    char unix_want[2048];
    snprintf(unix_want, sizeof(unix_want), "%s/drive_c/", prefix);
    CHECK(!strncmp(tp.unix_path, unix_want, strlen(unix_want)));
    struct stat st;
    CHECK(stat(tp.unix_path, &st) == 0 && S_ISREG(st.st_mode));
}

int main(int argc, char **argv)
{
    if (argc == 3) {
        title_path tp;
        char msg[512];
        int rc = title_path_resolve(argv[1], argv[2], &tp, msg, sizeof(msg));
        if (rc) {
            fprintf(stderr, "title_path_resolve -> %d %s\n", rc, msg);
            return 1;
        }
        printf("%s\n%s\n%s\n", tp.dos, tp.dos_dir, tp.unix_path);
        return 0;
    }

    const char *tmp = getenv("TMPDIR");
    char prefix[1024];
    snprintf(prefix, sizeof(prefix), "%s/title_path_test.XXXXXX", tmp && *tmp ? tmp : ".");
    if (!mkdtemp(prefix)) return 2;
    dir(prefix, "drive_c");
    dir(prefix, "drive_c/Games");
    dir(prefix, "drive_c/Games/Hollow Knight");
    dir(prefix, "drive_c/Games/Hollow Knight/hollow_knight_Data");
    touch(prefix, "drive_c/Games/Hollow Knight/hollow_knight.exe");
    dir(prefix, "drive_c/Games/Twin");
    touch(prefix, "drive_c/Games/Twin/a.exe");
    touch(prefix, "drive_c/Games/Twin/A.EXE");
    touch(prefix, "drive_c/Games/Twin/Only.exe");
    touch(prefix, "drive_c/root.exe");
    char link[2048];
    snprintf(link, sizeof(link), "%s/drive_c/Games/dangling.exe", prefix);
    CHECK(symlink("nowhere.exe", link) == 0);
    snprintf(link, sizeof(link), "%s/drive_c/Linked", prefix);
    CHECK(symlink("Games/Hollow Knight", link) == 0);

    const char *hk = "C:\\Games\\Hollow Knight\\hollow_knight.exe", *hk_dir = "C:\\Games\\Hollow Knight";
    /* the three spellings and both separators name the same file */
    expect(prefix, "Games\\Hollow Knight\\hollow_knight.exe", 0, hk, hk_dir);
    expect(prefix, "\\Games\\Hollow Knight\\hollow_knight.exe", 0, hk, hk_dir);
    expect(prefix, "C:\\Games\\Hollow Knight\\hollow_knight.exe", 0, hk, hk_dir);
    expect(prefix, "c:/Games/Hollow Knight/hollow_knight.exe", 0, hk, hk_dir);
    /* case-insensitive as Wine is; the result carries the on-disk case */
    expect(prefix, "GAMES\\hollow knight\\HOLLOW_KNIGHT.EXE", 0, hk, hk_dir);
    /* an exact match wins over a case variant; two variants and no exact one is ambiguous */
    expect(prefix, "Games\\Twin\\A.EXE", 0, "C:\\Games\\Twin\\A.EXE", "C:\\Games\\Twin");
    expect(prefix, "Games\\Twin\\a.Exe", -1, NULL, NULL);
    expect(prefix, "games\\twin\\ONLY.EXE", 0, "C:\\Games\\Twin\\Only.exe", "C:\\Games\\Twin");
    /* the drive root is a working directory too */
    expect(prefix, "root.exe", 0, "C:\\root.exe", "C:\\");
    /* a directory link inside drive_c is followed, and the DOS path keeps the link's name */
    expect(prefix, "Linked\\hollow_knight.exe", 0, "C:\\Linked\\hollow_knight.exe", "C:\\Linked");

    expect(prefix, "Games\\Hollow Knight\\missing.exe", -2, NULL, NULL);
    expect(prefix, "Games\\Nope\\hollow_knight.exe", -2, NULL, NULL);
    expect(prefix, "Games\\Hollow Knight\\hollow_knight.exe\\x.exe", -2, NULL, NULL);
    expect(prefix, "Games\\dangling.exe", -2, NULL, NULL);
    expect(prefix, "Games\\Hollow Knight\\hollow_knight_Data", -3, NULL, NULL);
    expect(prefix, "Games\\Hollow Knight\\", -1, NULL, NULL);
    expect(prefix, "D:\\Games\\Hollow Knight\\hollow_knight.exe", -1, NULL, NULL);
    expect(prefix, "Z:\\etc\\passwd", -1, NULL, NULL);
    expect(prefix, "C:Games\\Hollow Knight\\hollow_knight.exe", -1, NULL, NULL);
    expect(prefix, "\\\\server\\share\\x.exe", -1, NULL, NULL);
    expect(prefix, "Games\\..\\Games\\Hollow Knight\\hollow_knight.exe", -1, NULL, NULL);
    expect(prefix, "Games\\.\\Hollow Knight\\hollow_knight.exe", -1, NULL, NULL);
    expect(prefix, "Games\\\\Hollow Knight\\hollow_knight.exe", -1, NULL, NULL);
    expect(prefix, "Games\\Hollow Knight.\\hollow_knight.exe", -1, NULL, NULL);
    expect(prefix, "Games\\Hollow Knight\\hollow?knight.exe", -1, NULL, NULL);
    expect(prefix, "Games\\Caf\xc3\xa9\\x.exe", -1, NULL, NULL);
    expect(prefix, "", -1, NULL, NULL);
    expect(prefix, "C:\\", -1, NULL, NULL);

    /* the working directory must fit Wine's MAX_PATH buffer */
    char deep[1024] = "", rel[2048];
    for (int i = 0; i < 26; i++) strcat(deep, i ? "/abcdefghij" : "abcdefghij");
    char mk[2048];
    snprintf(mk, sizeof(mk), "mkdir -p '%s/drive_c/%s' && touch '%s/drive_c/%s/t.exe'", prefix, deep, prefix, deep);
    CHECK(system(mk) == 0);
    snprintf(rel, sizeof(rel), "%s/t.exe", deep);
    expect(prefix, rel, -4, NULL, NULL);

    char rm[2048];
    snprintf(rm, sizeof(rm), "rm -rf '%s'", prefix);
    CHECK(system(rm) == 0);
    printf("%s: %d failure%s\n", failures ? "FAIL" : "PASS", failures, failures == 1 ? "" : "s");
    return failures != 0;
}

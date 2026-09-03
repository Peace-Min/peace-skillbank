/* Fake cl.exe for build-check.ps1 tests: MSVC-shaped argument and diagnostic contract, no real compilation.
 * - requires INCLUDE to contain the marker directory (proves build-check constructed the environment)
 * - for each input .cpp: emits `path(line): error C2065: ...` when the file mentions undefined_symbol,
 *   otherwise writes the /Fo object file; `/Zs` = syntax only (no object)
 * Built with MinGW g++ by the fixture runner; never shipped. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int has(const char* s, const char* needle) { return strstr(s, needle) != NULL; }

int main(int argc, char** argv)
{
    const char* inc = getenv("INCLUDE");
    const char* lib = getenv("LIB");
    if (!inc || !has(inc, "FAKEMSVC")) { fprintf(stderr, "fake cl: INCLUDE does not contain the MSVC include directory\n"); return 9; }
    if (!lib || !has(lib, "FAKEMSVC")) { fprintf(stderr, "fake cl: LIB does not contain the MSVC lib directory\n"); return 9; }
    const char* fo = NULL; int zs = 0; int rc = 0;
    int i;
    for (i = 1; i < argc; i++) {
        if (strncmp(argv[i], "/Fo", 3) == 0) fo = argv[i] + 3;
        else if (strcmp(argv[i], "/Zs") == 0) zs = 1;
    }
    for (i = 1; i < argc; i++) {
        const char* a = argv[i];
        size_t n = strlen(a);
        if (a[0] == '/' || n < 4) continue;
        if (!(strcmp(a + n - 4, ".cpp") == 0 || strcmp(a + n - 2, ".h") == 0)) continue;
        FILE* f = fopen(a, "rb");
        if (!f) { fprintf(stderr, "fake cl: cannot open %s\n", a); return 2; }
        char buf[65536]; size_t got = fread(buf, 1, sizeof(buf) - 1, f); buf[got] = 0; fclose(f);
        const char* leaf = strrchr(a, '\\'); leaf = leaf ? leaf + 1 : a;
        printf("%s\n", leaf);
        if (has(buf, "undefined_symbol")) {
            int line = 1; const char* p = buf; const char* hit = strstr(buf, "undefined_symbol");
            while (p < hit) { if (*p == '\n') line++; p++; }
            printf("%s(%d): error C2065: 'undefined_symbol': undeclared identifier\n", a, line);
            rc = 2;
            continue;
        }
        if (!zs && fo) { FILE* o = fopen(fo, "wb"); if (o) { fputs("fake obj\n", o); fclose(o); } }
    }
    return rc;
}

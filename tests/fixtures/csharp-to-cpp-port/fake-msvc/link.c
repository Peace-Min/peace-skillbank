/* Fake link.exe: accepts /OUT:<exe> and object files, requires LIB to be set, writes the output file.
 * Extra inputs ending in .lib are echoed so the fixture can prove -LinkArgs reached the linker. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char** argv)
{
    const char* lib = getenv("LIB");
    if (!lib || !strstr(lib, "FAKEMSVC")) { fprintf(stderr, "fake link: LIB not set by build-check\n"); return 9; }
    const char* out = NULL; int objs = 0; int i;
    for (i = 1; i < argc; i++) {
        if (strncmp(argv[i], "/OUT:", 5) == 0) out = argv[i] + 5;
        else if (argv[i][0] != '/') {
            size_t n = strlen(argv[i]);
            if (n > 4 && strcmp(argv[i] + n - 4, ".lib") == 0) printf("fake link: library %s\n", argv[i]);
            else objs++;
        }
    }
    if (!out || objs == 0) { fprintf(stderr, "fake link: missing /OUT: or objects\n"); return 1; }
    FILE* f = fopen(out, "wb"); if (!f) { fprintf(stderr, "fake link: cannot write %s\n", out); return 1; }
    fputs("fake exe\n", f); fclose(f);
    printf("fake link: wrote %s (%d objects)\n", out, objs);
    return 0;
}

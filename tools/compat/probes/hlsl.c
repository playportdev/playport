/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * hlsl: compiles one entry point of an HLSL file with D3DCompile and writes
 * the bytecode as a C array, for a probe that embeds its shaders
 * (d3d12-shaders.sh runs it under desktop Wine, whose d3dcompiler_47.dll
 * does the work; not a phone probe).
 *
 *   hlsl.exe FILE ENTRY PROFILE NAME  >  static const unsigned char NAME[] = {...};
 */
#include <windows.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
    ID3DBlob *code = NULL, *errors = NULL;
    const unsigned char *bytes;
    char *src;
    long len;
    size_t size, i;
    FILE *f;
    HRESULT hr;

    if (argc != 5) {
        fprintf(stderr, "usage: hlsl FILE ENTRY PROFILE NAME\n");
        return 2;
    }
    if (!(f = fopen(argv[1], "rb"))) {
        fprintf(stderr, "hlsl: cannot open %s\n", argv[1]);
        return 2;
    }
    fseek(f, 0, SEEK_END);
    len = ftell(f);
    fseek(f, 0, SEEK_SET);
    src = malloc(len + 1);
    if (!src || fread(src, 1, len, f) != (size_t)len) {
        fprintf(stderr, "hlsl: cannot read %s\n", argv[1]);
        return 2;
    }
    fclose(f);

    hr = D3DCompile(src, len, argv[1], NULL, NULL, argv[2], argv[3], D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &code, &errors);
    if (FAILED(hr)) {
        fprintf(stderr, "hlsl: D3DCompile %s %s: %#lx\n", argv[2], argv[3], (unsigned long)hr);
        if (errors) fprintf(stderr, "%s\n", (const char *)errors->lpVtbl->GetBufferPointer(errors));
        return 1;
    }
    bytes = code->lpVtbl->GetBufferPointer(code);
    size = code->lpVtbl->GetBufferSize(code);
    if (size < 4 || memcmp(bytes, "DXBC", 4)) {
        fprintf(stderr, "hlsl: %s is not DXBC\n", argv[2]);
        return 1;
    }
    printf("/* %s %s, %zu bytes */\nstatic const unsigned char %s[] = {", argv[2], argv[3], size, argv[4]);
    for (i = 0; i < size; i++) printf("%s0x%02x,", i % 12 ? " " : "\n    ", bytes[i]);
    printf("\n};\n");
    return 0;
}

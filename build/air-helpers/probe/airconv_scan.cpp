// SPDX-License-Identifier: GPL-3.0-or-later
// Batch driver for DXMT's airconv public API, for a whole title's shaders in
// one process (title_shaders.py runs it):
//   airconv_scan plain  <list> [outdir]  every shader alone, the way
//                                        d3d11_shader.cpp compiles VS/PS/CS;
//                                        writes <outdir>/<name>.metallib
//   airconv_scan gs     <vs-list> <gs-list>   vertex and geometry halves
//   airconv_scan hull   <vs-list> <hs-list>   of the mesh pipelines DXMT
//   airconv_scan domain <hs-list> <ds-list>   builds for GS and tessellation
// A list holds one .dxbc path per line. Pair modes try each first-list shader
// until one compiles with the second: the title's real pairings are not known
// offline, so a pair result shows that the second shader's body converts, not
// that its pairing does. Output: one "ok"/"fail"/"init-fail" line per shader.
#include "airconv_public.h"
#include <cstdio>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

static std::vector<char> slurp(const std::string &p) {
  std::ifstream f(p, std::ios::binary);
  return {std::istreambuf_iterator<char>(f), {}};
}

static std::vector<std::string> lines(const char *p) {
  std::ifstream f(p);
  std::vector<std::string> v;
  std::string s;
  while (std::getline(f, s))
    if (!s.empty()) v.push_back(s);
  return v;
}

static sm50_shader_t load(const std::string &p) {
  auto c = slurp(p);
  sm50_shader_t sh = nullptr;
  sm50_error_t e = nullptr;
  MTL_SHADER_REFLECTION r{};
  if (SM50Initialize(c.data(), c.size(), &sh, &r, &e)) {
    printf("init-fail %s %s\n", p.c_str(), SM50GetErrorMessageString(e).c_str());
    return nullptr;
  }
  return sh;
}

static std::string base(const std::string &p) {
  auto s = p.substr(p.find_last_of('/') + 1);
  return s.substr(0, s.find_last_of('.'));
}

int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage: see source\n"); return 2; }
  std::string mode = argv[1];
  SM50_SHADER_COMMON_DATA common{};
  common.type = SM50_SHADER_COMMON;
  common.metal_version = SM50_SHADER_METAL_320;
  SM50_SHADER_PSO_TESSELLATOR_DATA tess{};
  tess.type = SM50_SHADER_PSO_TESSELLATOR;
  tess.max_potential_tess_factor = 64;
  tess.next = &common;
  int failed = 0;

  if (mode == "plain") {
    std::string out = argc > 3 ? argv[3] : "";
    for (auto &p : lines(argv[2])) {
      sm50_shader_t sh = load(p);
      if (!sh) { failed++; continue; }
      sm50_bitcode_t bc = nullptr;
      sm50_error_t err = nullptr;
      if (SM50Compile(sh, (SM50_SHADER_COMPILATION_ARGUMENT_DATA *)&common, "shader_main", &bc, &err)) {
        printf("fail %s %s\n", p.c_str(), SM50GetErrorMessageString(err).c_str());
        SM50FreeError(err);
        failed++;
      } else {
        if (!out.empty()) {
          SM50_COMPILED_BITCODE d{};
          SM50GetCompiledBitcode(bc, &d);
          FILE *f = fopen((out + "/" + base(p) + ".metallib").c_str(), "wb");
          if (f) { fwrite(d.Data, 1, d.Size, f); fclose(f); }
        }
        printf("ok %s\n", p.c_str());
        SM50DestroyBitcode(bc);
      }
      SM50Destroy(sh);
      fflush(stdout);
    }
    return failed ? 1 : 0;
  }

  if (argc < 4 || (mode != "gs" && mode != "hull" && mode != "domain")) {
    fprintf(stderr, "unknown mode %s\n", mode.c_str());
    return 2;
  }
  auto A = lines(argv[2]), B = lines(argv[3]);
  std::vector<sm50_shader_t> a;
  for (auto &p : A) a.push_back(load(p));
  for (auto &pb : B) {
    sm50_shader_t b = load(pb);
    if (!b) { failed++; continue; }
    std::string last = "no first-list shader";
    bool ok = false;
    for (size_t i = 0; i < a.size() && !ok; i++) {
      if (!a[i]) continue;
      sm50_bitcode_t bc = nullptr;
      sm50_error_t err = nullptr;
      int rc;
      if (mode == "gs") {
        SM50_SHADER_IA_INPUT_LAYOUT_DATA ia{};
        ia.type = SM50_SHADER_IA_INPUT_LAYOUT;
        ia.index_buffer_format = SM50_INDEX_BUFFER_FORMAT_NONE;
        ia.next = &common;
        SM50_SHADER_PSO_GEOMETRY_SHADER_DATA g{};
        g.type = SM50_SHADER_PSO_GEOMETRY_SHADER;
        g.next = &ia;
        rc = SM50CompileGeometryPipelineVertex(a[i], b, (SM50_SHADER_COMPILATION_ARGUMENT_DATA *)&g,
                                               "vsgs_main", &bc, &err);
        if (!rc) {
          SM50DestroyBitcode(bc);
          bc = nullptr;
          SM50_SHADER_PSO_GEOMETRY_SHADER_DATA g2{};
          g2.type = SM50_SHADER_PSO_GEOMETRY_SHADER;
          g2.next = &common;
          rc = SM50CompileGeometryPipelineGeometry(a[i], b, (SM50_SHADER_COMPILATION_ARGUMENT_DATA *)&g2,
                                                   "gs_main", &bc, &err);
        }
      } else if (mode == "hull") {
        SM50_SHADER_IA_INPUT_LAYOUT_DATA ia{};
        ia.type = SM50_SHADER_IA_INPUT_LAYOUT;
        ia.index_buffer_format = SM50_INDEX_BUFFER_FORMAT_NONE;
        ia.next = &tess;
        rc = SM50CompileTessellationPipelineHull(a[i], b, (SM50_SHADER_COMPILATION_ARGUMENT_DATA *)&ia,
                                                 "hull_main", &bc, &err);
      } else {
        SM50_SHADER_GS_PASS_THROUGH_DATA gs{};
        gs.type = SM50_SHADER_GS_PASS_THROUGH;
        gs.next = &tess;
        rc = SM50CompileTessellationPipelineDomain(a[i], b, (SM50_SHADER_COMPILATION_ARGUMENT_DATA *)&gs,
                                                   "domain_main", &bc, &err);
      }
      if (!rc) {
        ok = true;
        printf("ok %s %s\n", pb.c_str(), A[i].c_str());
        SM50DestroyBitcode(bc);
      } else {
        last = SM50GetErrorMessageString(err);
        SM50FreeError(err);
      }
    }
    if (!ok) { printf("fail %s %s\n", pb.c_str(), last.c_str()); failed++; }
    SM50Destroy(b);
    fflush(stdout);
  }
  return failed ? 1 : 0;
}

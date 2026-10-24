// SPDX-License-Identifier: GPL-3.0-or-later
// Links the actual patched signer objects built by build/toolchain/xtool.sh.
#include "Zupersign.h"
#include "bundle.h"
#include <fstream>
#include <iterator>

static std::string read(const char *path) {
    std::ifstream input(path);
    return std::string(std::istreambuf_iterator<char>(input), {});
}

int main(int argc, char **argv) {
    if (argc != 5) return 2;
    const std::string root = argv[1], mode = argv[2];
    const std::string helper = root + "/PlugIns/Helper.appex";
    const auto rootXML = read(argv[3]), helperXML = read(argv[4]);
    if (mode == "missing-helper") {
        ZSignAsset asset;
        if (!asset.Init(nullptr, nullptr, "", rootXML, true, false, false)) return 3;
        ZBundle bundle;
        bundle.SetBundleEntitlements({{root, rootXML}}, true);
        // Exercise the real-signing strict-mapping branch with an ad hoc
        // asset: no actual identity, developer account or private key needed.
        const bool ok = bundle.SignFolder(&asset, root, "", "", "", {}, {}, true, false, false);
        return ok ? 4 : 0;
    }
    entitlements_data_t entries[] = {
        {root.c_str(), rootXML.data(), rootXML.size()},
        {helper.c_str(), helperXML.data(), helperXML.size()},
    };
    if (mode == "reverse") std::swap(entries[0], entries[1]);
    const auto *start = mode == "missing-root" ? entries + 1 : entries;
    const size_t count = mode == "missing-root" ? 1 : 2;
    char *error = nullptr;
    int context = 0;
    const int result = zsign_sign(root.c_str(), "", 0, "", 0, start, count,
                                 [](const void *, double) {}, &context, &error);
    free(error);
    return mode == "missing-root" ? (result == 0 ? 5 : 0) : result;
}

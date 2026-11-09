#include "bundle.h"

// Host-side tool for the public self-signed reference package, not device installation.
int main(int argc, char **argv) {
    if (argc != 6) return 2;
    ZLog::SetLogLever(ZLog::E_ERROR);
    ZSignAsset asset;
    if (!asset.Init("", argv[2], argv[4], "", argv[3], false, true, false)) return 3;
    // A reference package must not claim an Apple-anchored designated requirement.
    // The CMS still embeds the clearly named Retools self-signed certificate.
    asset.m_strSubjectCN.clear();
    ZBundle bundle;
    return bundle.SignFolder(&asset, argv[1], argv[5], "", "", {}, {}, true, false, false) ? 0 : 4;
}

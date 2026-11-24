#!/bin/bash
set -euo pipefail
download_repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
download_check_dir=$(mktemp -d)
trap 'rm -rf "$download_check_dir"' EXIT
cd "$download_repo_dir"
swiftc NVDAppleIDDownload/Backend/AppStore/StoreProtocol.swift \
    NVDAppleIDDownload/Backend/AppStore/StoreDiagnostics.swift \
    NVDAppleIDDownload/Backend/AppStore/StoreDownloadProtocol.swift \
    Resources/Tests/DownloadProtocolChecks.swift -o "$download_check_dir/download-checks"
"$download_check_dir/download-checks"
/usr/bin/python3 Resources/Tests/LocalizationChecks.py NVDAppleIDDownload/Backend/AppStore/StoreDownloadProtocol.swift

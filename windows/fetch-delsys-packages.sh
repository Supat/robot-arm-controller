#!/bin/sh
# Downloads the Delsys API NuGet packages from Delsys's public example repository into
# ./packages, where NuGet.Config looks for them. They are Delsys's binaries and are not
# redistributed in this repository. Windows users: run fetch-delsys-packages.ps1 instead.
set -eu
cd "$(dirname "$0")"
mkdir -p packages
base='https://raw.githubusercontent.com/delsys-inc/Example-Applications/main/C%23%20.NET/DelsysAPI'
for name in DelsysAPI.2.9.7.1088-Main Delsys.Drivers.1.2.2.417-main Delsys.Signals.2.1.1.28-main Filtering.2.1.1.28-main; do
    if [ ! -s "packages/$name.nupkg" ]; then
        echo "Fetching $name"
        curl -fsSL -o "packages/$name.nupkg" "$base/$name.nupkg"
    fi
done
echo "Delsys packages are in $(pwd)/packages"

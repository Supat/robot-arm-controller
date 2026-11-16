# Downloads the Delsys API NuGet packages from Delsys's public example repository into
# .\packages, where NuGet.Config looks for them. They are Delsys's binaries and are not
# redistributed in this repository.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$packages = Join-Path $here 'packages'
New-Item -ItemType Directory -Force -Path $packages | Out-Null
$base = 'https://raw.githubusercontent.com/delsys-inc/Example-Applications/main/C%23%20.NET/DelsysAPI'
$names = 'DelsysAPI.2.9.7.1088-Main', 'Delsys.Drivers.1.2.2.417-main', 'Delsys.Signals.2.1.1.28-main', 'Filtering.2.1.1.28-main'
foreach ($name in $names) {
    $target = Join-Path $packages "$name.nupkg"
    if (-not (Test-Path $target) -or (Get-Item $target).Length -eq 0) {
        Write-Host "Fetching $name"
        Invoke-WebRequest -Uri "$base/$name.nupkg" -OutFile $target
    }
}
Write-Host "Delsys packages are in $packages"

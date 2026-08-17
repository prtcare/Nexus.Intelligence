# Packs the product-facing contract so Nexus.Web can consume it.
$ErrorActionPreference = 'Stop'
$feed    = 'C:\Personal\LocalNuGet'
$version = "0.1.0-dev.$(Get-Date -Format yyyyMMddHHmmss)"

Write-Host "packing Nexus.Intelligence.Contracts as $version -> $feed" -ForegroundColor Cyan
dotnet pack src\Nexus.Intelligence.Contracts\Nexus.Intelligence.Contracts.csproj `
    -c Release -o $feed -p:PackageVersion=$version --nologo
if ($LASTEXITCODE -ne 0) { throw 'pack failed' }
Write-Host "done. run 'dotnet restore' in Nexus.Web to pick it up." -ForegroundColor Green

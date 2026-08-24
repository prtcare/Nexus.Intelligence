# Packs Nexus.Intelligence.Contracts and publishes it to GitHub Packages so
# Nexus.Web (and anything else outside this repo) can consume it.
$ErrorActionPreference = 'Stop'

# Credential: read from $env:GITHUB_PACKAGES_TOKEN (a PAT scoped to write:packages).
# Its value is never read for display, logged, echoed, or written to any file -
# it is only passed as the api-key argument to dotnet nuget push.
if (-not $env:GITHUB_PACKAGES_TOKEN) {
    throw 'GITHUB_PACKAGES_TOKEN is not set. Set it to a GitHub PAT scoped to write:packages before running this script.'
}

# Pack output stays at the existing local staging location. It is scratch space
# for this script only now (nothing restores from it - see nuget.config, which
# points at github-prtcare instead), so it needs no .gitignore change.
$feed    = 'C:\Personal\LocalNuGet'
$version = "0.1.0-dev.$(Get-Date -Format yyyyMMddHHmmss)"

Write-Host "packing Nexus.Intelligence.Contracts as $version -> $feed" -ForegroundColor Cyan
dotnet pack src\Nexus.Intelligence.Contracts\Nexus.Intelligence.Contracts.csproj `
    -c Release -o $feed -p:PackageVersion=$version --nologo
if ($LASTEXITCODE -ne 0) { throw 'pack failed' }

Write-Host 'pushing to GitHub Packages (https://nuget.pkg.github.com/prtcare/index.json)' -ForegroundColor Cyan
dotnet nuget push "$feed\Nexus.Intelligence.Contracts.$version.nupkg" --source https://nuget.pkg.github.com/prtcare/index.json --api-key $env:GITHUB_PACKAGES_TOKEN --skip-duplicate
if ($LASTEXITCODE -ne 0) { throw 'nuget push failed' }

Write-Host 'done. Nexus.Web picks this up via its nuget.config github-prtcare source.' -ForegroundColor Green

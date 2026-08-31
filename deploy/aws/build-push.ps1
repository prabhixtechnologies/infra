# Builds the images CI would build, and pushes them to ECR, from a workstation.
#
# This exists because GitHub Actions is on metered billing since the repositories went private and
# will not start a job, so nothing can be released through CI. It is a stand-in for the pipeline and
# not a replacement for it: it does not run the test suites, and it trusts whoever runs it to have
# done that.
#
# It mirrors .github/workflows/ci.yml deliberately. The build arguments are the part that matters --
# Vite and Next inline them at build time, so an image built without them is not a slower version of
# the right one, it is a different product with features missing. Changing a build argument in one
# place and not the other is how the marketing site came to address an organization that did not
# exist. If you edit the arguments here, edit the workflow too.
#
# Usage:
#   pwsh Infra/deploy/aws/build-push.ps1                      # everything
#   pwsh Infra/deploy/aws/build-push.ps1 -Only identity
#   pwsh Infra/deploy/aws/build-push.ps1 -Only web,admin -WhatIf
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Names from the table below. Empty means all of them.
    [string[]]$Only = @(),
    [string]$Region = "ap-south-1",
    [string]$RegistryId = "029096972251",
    # The box is x86_64. Building on an arm64 workstation without this produces an image that cannot
    # run in production, and nothing notices until the container fails to start.
    [string]$Platform = "linux/amd64",
    # Skips the clean-tree check. Only for trying a build out; a tag produced this way names a commit
    # that does not describe what is inside the image.
    [switch]$AllowDirty
)

$ErrorActionPreference = "Stop"

# docker and aws write their progress to stderr, and under ErrorActionPreference = Stop PowerShell
# turns the first line of it into a terminating error. The build then dies at "#0 building with
# desktop-linux" -- having started correctly, with nothing actually wrong. Every native call here is
# judged by its exit code instead, which is what the checks after them already do.
#
# remote-run.ps1 does the same thing for ssh, for the same reason.
function Invoke-Native {
    param([Parameter(Mandatory = $true)][scriptblock]$Command)
    $prior = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { & $Command } finally { $ErrorActionPreference = $prior }
}

# The umbrella directory holding every repository: three levels above Infra/deploy/aws.
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$registry = "$RegistryId.dkr.ecr.$Region.amazonaws.com"

# Repo is relative to the umbrella; Context is relative to the repo. Image is the ECR repository
# under prabhix/, which must contain a slash: the deployer policy scopes ECR to
# repository/prabhix/*, and that pattern does not match a name without one.
$images = @(
    @{ Name = "backend"; Repo = "oneOps"; Image = "prabhix/backend"; Context = "backend"; Args = @{} }

    # VITE_IDENTITY_ISSUER is what turns each console's own password form into a redirect to the
    # hosted login page. Setting it on both in the same build is deliberate: the point of a shared
    # login is that signing into one signs you into the other, and a build where only one console
    # redirects gives whoever signs in at the other a second, separate session -- which looks like
    # single sign-on failing rather than like a half-finished rollout.
    #
    # api. rather than id. because that is where the Caddyfile serves the login page and discovery
    # until id. has an A record. Products compare the issuer by string equality, so moving it later
    # invalidates every token in flight and both consoles have to be rebuilt together again.
    @{ Name = "web"; Repo = "oneOps"; Image = "prabhix/web"; Context = "web"; Args = [ordered]@{
        APP                     = "oneops"
        VITE_API_URL            = "https://api.prabhixtechnologies.com"
        VITE_GOOGLE_SSO_ENABLED = "false"
        VITE_IDENTITY_ISSUER    = "https://api.prabhixtechnologies.com"
        VITE_MAILROOM_URL       = "https://mail.prabhixtechnologies.com"
        # VITE_RAZORPAY_KEY_ID is deliberately absent: it was an unset repository variable in CI, so
        # the images already in ECR were built without it and checkout is already off. Setting it
        # here and not in the workflow would make the two builds differ.
    } }

    # Same context and Dockerfile as web; APP picks the entry point, so the two images differ only in
    # which routes they contain. No Razorpay key -- the admin app has no checkout.
    @{ Name = "admin"; Repo = "oneOps"; Image = "prabhix/admin"; Context = "web"; Args = [ordered]@{
        APP                     = "admin"
        VITE_API_URL            = "https://api.prabhixtechnologies.com"
        VITE_GOOGLE_SSO_ENABLED = "false"
        VITE_IDENTITY_ISSUER    = "https://api.prabhixtechnologies.com"
        VITE_ONEOPS_URL         = "https://oneops.prabhixtechnologies.com"
        VITE_MAILROOM_URL       = "https://mail.prabhixtechnologies.com"
    } }

    @{ Name = "marketing"; Repo = "Platform"; Image = "prabhix/marketing"; Context = "marketing"; Args = [ordered]@{
        NEXT_PUBLIC_API_URL       = "https://api.prabhixtechnologies.com"
        NEXT_PUBLIC_SITE_URL      = "https://prabhixtechnologies.com"
        NEXT_PUBLIC_CONSOLE_URL   = "https://oneops.prabhixtechnologies.com"
        NEXT_PUBLIC_MOBISTACK_URL = "https://mobistack.prabhixtechnologies.com"
        # From oneOps/deploy/seed.sql. These turn on the storefront, chat widget and visitor beacon, and a
        # slug that does not match a real row disables all three at runtime rather than failing the
        # build -- which is exactly what production was doing.
        NEXT_PUBLIC_ORG_SLUG      = "prabhix-platform"
        NEXT_PUBLIC_ORG_ID        = "00000000-0000-4000-8000-000000000001"
    } }

    @{ Name = "identity"; Repo = "Identity"; Image = "prabhix/identity"; Context = "."; Args = @{} }

    @{ Name = "mailroom"; Repo = "Mailroom"; Image = "prabhix/mailroom"; Context = "web"; Args = [ordered]@{
        VITE_API_URL         = "https://api.prabhixtechnologies.com"
        # Required here, unlike in the two consoles: Mailroom has no password form of its own and
        # authenticates only through Identity, so an empty issuer leaves it unable to sign in at all.
        # api. rather than id. because that is where the Caddyfile serves discovery until id. has an
        # A record.
        VITE_IDENTITY_ISSUER = "https://api.prabhixtechnologies.com"
        VITE_ONEOPS_URL      = "https://oneops.prabhixtechnologies.com"
    } }
)

# Split on commas as well as taking an array, because `powershell -File this.ps1 -Only web,admin`
# hands the whole list over as one string rather than three, and the resulting "unknown image" error
# names every image you asked for as if none of them existed.
$wanted = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$selected = if ($wanted.Count -gt 0) {
    $known = $images | ForEach-Object { $_.Name }
    $missing = $wanted | Where-Object { $_ -notin $known }
    if ($missing) { throw "unknown image(s): $($missing -join ', '). Known: $($known -join ', ')" }
    # Ordered by the table, not by the argument, so a full run always builds in the same order.
    $images | Where-Object { $_.Name -in $wanted }
} else { $images }

# One login for the whole run. The credentials last twelve hours, so a long multi-image build does
# not lose them halfway through.
Write-Host "==> Authenticating to $registry"
Invoke-Native { aws ecr get-login-password --region $Region | docker login --username AWS --password-stdin $registry }
if ($LASTEXITCODE -ne 0) { throw "ECR login failed" }

# Resolved once per repository rather than once per image, so the two images built from oneOps/web
# cannot end up tagged with different commits.
$shas = @{}
foreach ($repo in ($selected | ForEach-Object { $_.Repo } | Select-Object -Unique)) {
    $path = Join-Path $root $repo
    if (-not (Test-Path $path)) { throw "no such repository: $path" }

    # A tag is a claim that the image contains that commit. Building from a dirty tree breaks the
    # claim, and the image is then impossible to reproduce or to roll back to with any confidence.
    $dirty = git -C $path status --porcelain
    if ($dirty -and -not $AllowDirty) {
        throw "$repo has uncommitted changes, so a commit tag would not describe the image. Commit them, or pass -AllowDirty.`n$dirty"
    }
    $shas[$repo] = (git -C $path rev-parse --short=7 HEAD).Trim()
}

$built = @()
foreach ($image in $selected) {
    $sha = $shas[$image.Repo]
    $context = Join-Path (Join-Path $root $image.Repo) $image.Context
    $target = "$registry/$($image.Image)"

    Write-Host ""
    Write-Host "==> $($image.Name)  ($($image.Repo)@$sha)"

    $argv = @(
        "build", "--platform", $Platform,
        "-f", (Join-Path $context "Dockerfile"),
        "-t", "${target}:$sha", "-t", "${target}:latest"
    )
    foreach ($key in $image.Args.Keys) {
        $argv += @("--build-arg", "$key=$($image.Args[$key])")
    }
    $argv += $context

    if (-not $PSCmdlet.ShouldProcess("$($image.Image):$sha", "build and push")) {
        Write-Host "    docker $($argv -join ' ')"
        continue
    }

    Invoke-Native { & docker @argv }
    if ($LASTEXITCODE -ne 0) { throw "build failed for $($image.Name)" }

    # Both tags: the sha is what a deploy pins, latest is what a bare `docker compose pull` takes.
    # Pushed separately because one push only sends the tag it names.
    foreach ($tag in @($sha, "latest")) {
        Invoke-Native { docker push "${target}:$tag" }
        if ($LASTEXITCODE -ne 0) { throw "push failed for $($image.Image):$tag" }
    }
    $built += [pscustomobject]@{ Image = $image.Name; Tag = $sha }
}

if ($built) {
    Write-Host ""
    Write-Host "==> Pushed:"
    $built | Format-Table -AutoSize
    Write-Host "Set the matching *_TAG in deploy/.env.prod, then run deploy/deploy-remote.ps1."
}

# Mirrors the third-party images we run in production into our own ECR registry.
#
# Everything else we deploy is either built by us or is a Docker Official Image, and AWS mirrors
# the official ones into public.ecr.aws/docker/library, so the Dockerfiles and compose files point
# straight at the gallery. The images here are neither: they have no gallery mirror, and pulling
# them from Docker Hub at deploy time puts an anonymous rate limit on the critical path of a
# production restart. Copying them into our registry removes that, and pins the exact digest we
# tested against rather than whatever the upstream tag points at on the day.
#
# Run this when adding an image or moving to a new upstream version, not on every deploy -- the
# repositories are IMMUTABLE, so re-pushing an existing tag is refused rather than silently
# swapping what production runs.
#
# Usage:  pwsh deploy/aws/mirror-third-party.ps1
[CmdletBinding()]
param(
    [string]$Region = "ap-south-1",
    [string]$RegistryId = "029096972251",
    # The box is x86_64. Pulling without pinning this on an arm64 workstation mirrors an image
    # that cannot run in production, and the failure only shows up at deploy time.
    [string]$Platform = "linux/amd64"
)

$ErrorActionPreference = "Stop"

$images = @(
    @{ Source = "edoburu/pgbouncer:1.22.1-p0"; Target = "prabhix/third-party/pgbouncer:1.22.1-p0" }
)

$registry = "$RegistryId.dkr.ecr.$Region.amazonaws.com"

Write-Host "==> Authenticating to $registry"
aws ecr get-login-password --region $Region | docker login --username AWS --password-stdin $registry
if ($LASTEXITCODE -ne 0) { throw "ECR login failed" }

foreach ($image in $images) {
    $source = $image.Source
    $target = "$registry/$($image.Target)"
    $repository = ($image.Target -split ":")[0]

    Write-Host ""
    Write-Host "==> $source -> $target"

    # Create on demand so adding an entry above is the only edit needed. Already-exists is the
    # ordinary case on a re-run and is not an error.
    aws ecr describe-repositories --repository-names $repository --region $Region 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "    creating repository $repository"
        aws ecr create-repository --repository-name $repository --region $Region `
            --image-tag-mutability IMMUTABLE --image-scanning-configuration scanOnPush=true | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "could not create $repository" }
    }

    docker pull --platform $Platform $source
    if ($LASTEXITCODE -ne 0) { throw "could not pull $source" }

    docker tag $source $target
    docker push $target
    if ($LASTEXITCODE -ne 0) {
        throw "could not push $target. If this says the tag is immutable, the version is already mirrored."
    }
}

Write-Host ""
Write-Host "==> Done. Nothing in the production stack pulls from Docker Hub."

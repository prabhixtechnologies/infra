# Mirrors the third-party images we depend on into our own ECR registry.
#
# Two kinds of image are here, for the same reason but arrived at differently.
#
# PgBouncer has no Docker Official Image and no gallery mirror, so pulling it from Docker Hub at
# deploy time would put an anonymous rate limit on the critical path of a production restart.
#
# The base images were left on public.ecr.aws/docker/library on the reasoning that AWS mirrors the
# official ones and anonymous pulls work. They do not, reliably. Nine Dockerfiles across six
# repositories pull from the gallery, and when the repositories are pushed together those builds
# run concurrently and the gallery answers `429 toomanyrequests: Data limit exceeded`. It has
# failed a documentation-only commit, which is the real cost: a quota failure is indistinguishable
# from a genuine one, so every red build has to be opened before it can be dismissed.
# Infra/scripts/push-waves.ps1 reduces the collisions; mirroring removes them, because CI already
# authenticates to this registry in order to push.
#
# Either way the mirror pins the exact digest we tested against rather than whatever the upstream
# tag points at on the day.
#
# BEFORE MIRRORING THE BASE IMAGES: the CI role's ecr-push-policy.json enumerates the ten
# prabhix/* repositories by name and does not cover the prabhix/third-party/* prefix, so CI can
# push its own images but cannot pull a mirrored base layer. Repointing the Dockerfiles before
# that policy grants the prefix breaks every build at once. The instance role's
# ecr-pull-policy.json already grants it.
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

# Target tags keep the upstream version so a Dockerfile reads the same after repointing: only the
# host and the prabhix/third-party/ prefix change. The sources are the gallery rather than Docker
# Hub because that is where these are pulled from today, so what gets mirrored is byte-for-byte
# what CI has been building against.
$images = @(
    @{ Source = "edoburu/pgbouncer:1.22.1-p0"; Target = "prabhix/third-party/pgbouncer:1.22.1-p0" },

    # Base images. Every one of these appears in at least one Dockerfile; see the table in
    # README.md under "Third-party images we run".
    @{ Source = "public.ecr.aws/docker/library/node:22-alpine";                  Target = "prabhix/third-party/node:22-alpine" },
    @{ Source = "public.ecr.aws/docker/library/nginx:1.27-alpine";               Target = "prabhix/third-party/nginx:1.27-alpine" },
    @{ Source = "public.ecr.aws/docker/library/python:3.12-alpine";              Target = "prabhix/third-party/python:3.12-alpine" },
    @{ Source = "public.ecr.aws/docker/library/eclipse-temurin:25-jdk-alpine";   Target = "prabhix/third-party/eclipse-temurin:25-jdk-alpine" },
    @{ Source = "public.ecr.aws/docker/library/eclipse-temurin:25-jre-alpine";   Target = "prabhix/third-party/eclipse-temurin:25-jre-alpine" },
    @{ Source = "public.ecr.aws/docker/library/maven:3.9-eclipse-temurin-25";    Target = "prabhix/third-party/maven:3.9-eclipse-temurin-25" }
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

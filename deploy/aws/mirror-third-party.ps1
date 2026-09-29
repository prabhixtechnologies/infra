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

# Native calls here are judged by their exit codes, which every call site below already does, and
# not by whether they wrote to stderr. docker and aws both report ordinary progress there, and
# under "Stop" the first line of it becomes a terminating error on a command that succeeded.
#
# This script only ever ran against pgbouncer, whose repository already existed, so it never hit
# the case that matters: `describe-repositories` on a repository that is absent writes to stderr
# by design -- that is how the script asks whether it needs to create one -- and killed the run
# on the first new image. build-push.ps1 carries the same note for the same reason.
$ErrorActionPreference = "Continue"

# Target tags keep the upstream version so a Dockerfile reads the same after repointing: only the
# host and the prabhix/third-party/ prefix change. The sources are the gallery rather than Docker
# Hub because that is where these are pulled from today, so what gets mirrored is byte-for-byte
# what CI has been building against.
$images = @(
    @{ Source = "edoburu/pgbouncer:1.22.1-p0"; Target = "prabhix/third-party/pgbouncer:1.22.1-p0" },

    # Base images. Every one of these appears in at least one Dockerfile, and both tags of a
    # duplicated image are listed rather than consolidated: Dependabot moves the repositories
    # independently, so Node sits on 22 in MobiStack and Mailroom and on 26 in oneOps and
    # marketing. Mirroring only the newest would silently leave two builds pulling from the
    # gallery, which is the failure this is meant to end. Cross-check with:
    #   rg '^FROM public\.ecr\.aws' --glob '**/Dockerfile*'
    @{ Source = "public.ecr.aws/docker/library/node:22-alpine";                  Target = "prabhix/third-party/node:22-alpine" },
    @{ Source = "public.ecr.aws/docker/library/node:26-alpine";                  Target = "prabhix/third-party/node:26-alpine" },
    @{ Source = "public.ecr.aws/docker/library/maven:3-eclipse-temurin-26";      Target = "prabhix/third-party/maven:3-eclipse-temurin-26" },
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

    # The repositories are IMMUTABLE, so a tag that is already there cannot be replaced and does
    # not need to be. Skipping rather than failing is what makes this script re-runnable: before
    # this check, the first already-mirrored entry threw and nothing after it was reached, so
    # adding an image meant the existing ones blocked it.
    $tag = ($image.Target -split ":")[-1]
    aws ecr describe-images --repository-name $repository --image-ids "imageTag=$tag" `
        --region $Region 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    already mirrored, skipping"
        continue
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

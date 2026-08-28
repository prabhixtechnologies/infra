# smoke.ps1 — post-deploy checks from a Windows workstation.
# Usage: .\deploy\smoke.ps1 -ApiBase "https://api.prabhixtechnologies.com" `
#          -MarketingBase "https://prabhixtechnologies.com" `
#          -ConsoleBase "https://oneops.prabhixtechnologies.com" `
#          -OrgSlug "your-org-slug"

param(
    [string]$ApiBase = "http://localhost:8080",
    [string]$MarketingBase = "http://localhost:3000",
    [string]$ConsoleBase = "http://localhost:5173",
    # Needed for the public storefront checks. Skipped when empty.
    [string]$OrgSlug = ""
)

$ErrorActionPreference = "Stop"
$failed = 0

<#
Windows PowerShell 5.1 makes two things awkward that this script has to handle explicitly.

1. Invoke-WebRequest throws on any 4xx/5xx, so a check that *expects* 401 would land in the catch
   block and be reported as a failure. The response is recovered from the exception instead — and
   the body has to come from $_.ErrorDetails.Message, not from GetResponseStream(). Invoke-WebRequest
   has already drained that stream to build the exception, so reading it again yields zero bytes.
2. Content comes back as byte[] rather than a string when PowerShell does not recognise the
   Content-Type as text — which is the case for Spring Boot Actuator's
   `application/vnd.spring-boot.actuator.v3+json`. Matching a regex against byte[] stringifies it
   to space-separated numbers, so `{"status":"UP"}` reads as `123 34 115 ...` and never matches.
#>
function Get-BodyText {
    param($Response)
    $content = $Response.Content
    if ($null -eq $content) { return "" }
    if ($content -is [byte[]]) { return [System.Text.Encoding]::UTF8.GetString($content) }
    return [string]$content
}

function Test-Endpoint {
    param(
        [string]$Name,
        [string]$Url,
        [scriptblock]$Assert,
        [hashtable]$Headers = @{},
        # Set when a non-2xx status is the expected result.
        [switch]$AllowErrorStatus
    )
    Write-Host "==> $Name : $Url"
    try {
        $response = $null
        try {
            $response = Invoke-WebRequest -Uri $Url -Headers $Headers -UseBasicParsing -TimeoutSec 30
        }
        catch {
            $webResponse = $_.Exception.Response
            if (-not $AllowErrorStatus -or $null -eq $webResponse) { throw }
            $response = [pscustomobject]@{
                StatusCode = [int]$webResponse.StatusCode
                Content    = $_.ErrorDetails.Message
            }
        }
        & $Assert $response
        Write-Host "    OK" -ForegroundColor Green
    }
    catch {
        Write-Host "    FAIL: $_" -ForegroundColor Red
        $script:failed++
    }
}

# 1. Backend readiness
Test-Endpoint -Name "API health (readiness)" -Url "$ApiBase/actuator/health/readiness" -Assert {
    param($r)
    if ($r.StatusCode -ne 200) { throw "Expected 200, got $($r.StatusCode)" }
    $body = Get-BodyText $r
    if ($body -notmatch '"status"\s*:\s*"UP"') { throw "Status not UP: $body" }
}

# 2. Marketing homepage
Test-Endpoint -Name "Marketing site" -Url $MarketingBase -Assert {
    param($r)
    if ($r.StatusCode -ne 200) { throw "Expected 200, got $($r.StatusCode)" }
}

# 3. Console SPA shell
Test-Endpoint -Name "Console (OneOps)" -Url $ConsoleBase -Assert {
    param($r)
    if ($r.StatusCode -ne 200) { throw "Expected 200, got $($r.StatusCode)" }
}

# 4. Unauthenticated API — expect UNAUTHENTICATED JSON shape
Test-Endpoint -Name "API auth gate" -Url "$ApiBase/api/v1/mail/mailboxes" -AllowErrorStatus -Assert {
    param($r)
    if ($r.StatusCode -ne 401) { throw "Expected 401, got $($r.StatusCode)" }
    $json = Get-BodyText $r | ConvertFrom-Json
    if ($json.code -ne "UNAUTHENTICATED") {
        throw "Expected code UNAUTHENTICATED, got $($json.code)"
    }
    if (-not $json.message) { throw "Missing message field in ApiError" }
}

# 5. Public storefront catalog. Also pins the cursor-page contract: nextCursor must be present even
# on a last page, because clients validate the response shape and a missing key breaks them.
if ($OrgSlug) {
    Test-Endpoint -Name "Storefront catalog" `
        -Url "$ApiBase/api/v1/commerce/public/$OrgSlug/products" `
        -Headers @{ Origin = $MarketingBase } -Assert {
        param($r)
        if ($r.StatusCode -ne 200) { throw "Expected 200, got $($r.StatusCode)" }
        $body = Get-BodyText $r
        $json = $body | ConvertFrom-Json
        $keys = $json.PSObject.Properties.Name
        if ($keys -notcontains "nextCursor") {
            throw "cursor page is missing the nextCursor key: $body"
        }
        if ($keys -notcontains "hasMore") { throw "cursor page is missing hasMore: $body" }
        if ($null -eq $json.items) { throw "cursor page is missing items: $body" }
    }

    # 6. Origin allowlist actually refuses a foreign origin. The public endpoints have no token, so
    # this is the only thing standing between them and use from someone else's site.
    Test-Endpoint -Name "Storefront origin allowlist" `
        -Url "$ApiBase/api/v1/commerce/public/$OrgSlug/products" `
        -Headers @{ Origin = "https://smoke-test.invalid" } -AllowErrorStatus -Assert {
        param($r)
        if ($r.StatusCode -ne 403) { throw "Expected 403 for a foreign Origin, got $($r.StatusCode)" }
    }
}

# 7. Sitemap must list product pages. An empty sitemap is the visible symptom of the marketing
# server-side API base being wrong, which otherwise fails silently.
Test-Endpoint -Name "Marketing sitemap" -Url "$MarketingBase/sitemap.xml" -Assert {
    param($r)
    if ($r.StatusCode -ne 200) { throw "Expected 200, got $($r.StatusCode)" }
    $body = Get-BodyText $r
    if ($body -notmatch '/products/') { throw "sitemap lists no product pages" }
}

Write-Host ""
if ($failed -eq 0) {
    Write-Host "All smoke checks passed." -ForegroundColor Green
    exit 0
}
else {
    Write-Host "$failed check(s) failed." -ForegroundColor Red
    exit 1
}

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

<#
8 and 9. The page renders, not merely responds.

Checks 2 and 3 assert a 200 and nothing more, which is how the marketing site once served every
page completely unstyled without a single check failing. The container was running an image built
before its CSP middleware existed, so it sent no policy of its own and inherited Caddy's
`default-src 'none'` floor — meant for the API — which blocked every stylesheet, script and font.
The document itself was fine, so the status was 200 and the sitemap was correct.

So assert two things a bare status cannot express: that the host serves its own policy rather than
the no-document floor, and that the assets the HTML references are actually permitted by it.
#>
function Test-DocumentCsp {
    param([string]$Name, [string]$Url)

    Test-Endpoint -Name "$Name CSP allows its own assets" -Url $Url -Assert {
        param($r)
        if ($r.StatusCode -ne 200) { throw "Expected 200, got $($r.StatusCode)" }

        $csp = $r.Headers["Content-Security-Policy"]
        if (-not $csp) {
            throw "No Content-Security-Policy. The app must send its own; Caddy no longer supplies one for document hosts."
        }
        if ($csp -match "default-src\s+'none'") {
            throw "Serving the no-document CSP floor ($csp). This host serves HTML, so every asset on the page is blocked. The app is not sending its own policy, most likely a stale image."
        }

        # A document that references no stylesheet is itself the symptom of a broken build.
        $refs = [regex]::Matches($r.Content, '(?:href|src)="(/[^"]*\.(?:css|js))"') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $css = @($refs | Where-Object { $_ -like '*.css' })
        if ($css.Count -eq 0) { throw "Page references no stylesheet at all" }

        $base = ([uri]$Url).GetLeftPart([System.UriPartial]::Authority)
        foreach ($ref in $refs) {
            $assetUrl = "$base$ref"
            try {
                $a = Invoke-WebRequest -Uri $assetUrl -UseBasicParsing -TimeoutSec 30
                if ($a.StatusCode -ne 200) { throw "status $($a.StatusCode)" }
            }
            catch {
                throw "Asset referenced by the page does not load: $ref ($_)"
            }
        }
    }
}

Test-DocumentCsp -Name "Marketing" -Url $MarketingBase
Test-DocumentCsp -Name "Console (OneOps)" -Url $ConsoleBase

Write-Host ""
if ($failed -eq 0) {
    Write-Host "All smoke checks passed." -ForegroundColor Green
    exit 0
}
else {
    Write-Host "$failed check(s) failed." -ForegroundColor Red
    exit 1
}

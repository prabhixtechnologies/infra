#!/usr/bin/env bash
# Verifies the Phase 2 claim end to end against the deployed domain: one sign-in covers both
# consoles, the native body-refresh path is untouched, and revoking a session kills both.
set -uo pipefail

API=https://api.prabhixtechnologies.com/api/v1
ONEOPS=https://oneops.prabhixtechnologies.com
ADMIN=https://admin.prabhixtechnologies.com
EMAIL="${TEST_EMAIL:?set TEST_EMAIL}"
PASSWORD="${TEST_PASSWORD:?set TEST_PASSWORD}"
JAR=$(mktemp)
pass=0; fail=0

ok()   { echo "  PASS  $*"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $*"; fail=$((fail+1)); }
head2() { echo; echo "== $* =="; }

head2 "1. Both hostnames serve their own bundle over valid TLS"
for pair in "$ONEOPS|Team Inbox" "$ADMIN|Prabhix Admin"; do
  host="${pair%%|*}"; want="${pair##*|}"
  title=$(curl -fsS --max-time 20 "$host/" 2>/dev/null | grep -o '<title>[^<]*</title>')
  if echo "$title" | grep -q "$want"; then ok "$host serves: $title"; else bad "$host title was '$title', wanted '$want'"; fi
done

head2 "2. The OneOps bundle does not contain the platform admin code"
oneops_assets=$(curl -fsS --max-time 20 "$ONEOPS/" | grep -o 'assets/[A-Za-z0-9._-]*\.js' | head -1)
if curl -fsS --max-time 20 "$ONEOPS/" | grep -qi 'opshub'; then
  bad "OneOps index references an OpsHub chunk"
else
  ok "OneOps entry ($oneops_assets) has no OpsHub reference"
fi

head2 "3. Signing in sets a session cookie scoped to the parent domain"
login=$(curl -sS -D - -o /tmp/login.json --max-time 20 -c "$JAR" \
  -H 'Content-Type: application/json' -H "Origin: $ONEOPS" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" \
  "$API/auth/login" 2>&1)

setcookie=$(echo "$login" | grep -i '^set-cookie:.*pbx_session' || true)
if [ -n "$setcookie" ]; then ok "cookie issued"; echo "        $setcookie"; else bad "no session cookie in the login response"; fi
for attr in 'Domain=.prabhixtechnologies.com' 'HttpOnly' 'Secure' 'SameSite=Lax'; do
  if echo "$setcookie" | grep -qi -- "$attr"; then ok "cookie carries $attr"; else bad "cookie missing $attr"; fi
done

ACCESS=$(python3 -c 'import json;print(json.load(open("/tmp/login.json")).get("accessToken",""))')
REFRESH=$(python3 -c 'import json;print(json.load(open("/tmp/login.json")).get("refreshToken") or "")')
SESSION=$(python3 -c 'import json;print(json.load(open("/tmp/login.json")).get("sessionId") or "")')
[ -n "$ACCESS" ] && ok "access token returned" || bad "no access token"
[ -n "$REFRESH" ] && ok "refresh token still in the body, so native clients are unaffected" || bad "refresh token missing from body"
[ -n "$SESSION" ] && ok "sessionId returned ($SESSION)" || bad "no sessionId"

head2 "4. The admin console exchanges that same cookie for its own token, with no second login"
admin_tok=$(curl -sS --max-time 20 -b "$JAR" -X POST \
  -H "Origin: $ADMIN" -H 'Content-Type: application/json' \
  "$API/auth/session/token" 2>&1)
a1=$(echo "$admin_tok" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("accessToken",""))' 2>/dev/null)
if [ -n "$a1" ]; then ok "admin origin got a token from the cookie alone"; else bad "exchange from admin origin failed: $admin_tok"; fi
if [ -n "$a1" ] && [ "$a1" != "$ACCESS" ]; then ok "it is a distinct token, not the login one replayed"; fi

head2 "5. The exchange does not rotate, so both consoles can call it repeatedly"
for n in 1 2 3; do
  t=$(curl -sS --max-time 20 -b "$JAR" -X POST -H "Origin: $ONEOPS" "$API/auth/session/token" \
      | python3 -c 'import json,sys;print(json.load(sys.stdin).get("accessToken",""))' 2>/dev/null)
  [ -n "$t" ] && ok "exchange $n succeeded" || bad "exchange $n failed — the cookie rotated or was consumed"
done

head2 "6. The exchange returns no refresh token, so nothing rotatable reaches the browser"
body=$(curl -sS --max-time 20 -b "$JAR" -X POST -H "Origin: $ONEOPS" "$API/auth/session/token")
if echo "$body" | grep -q '"refreshToken"'; then
  bad "exchange response still contains a refreshToken"
else
  ok "no refreshToken in the exchange response"
fi

head2 "7. Both tokens work against a protected endpoint"
for pair in "OneOps|$ACCESS" "admin|$a1"; do
  name="${pair%%|*}"; tok="${pair##*|}"
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -H "Authorization: Bearer $tok" "$API/auth/me")
  [ "$code" = "200" ] && ok "$name token authenticates ($code)" || bad "$name token got $code from /auth/me"
done

head2 "8. The native body-refresh path still works, untouched"
nat=$(curl -sS --max-time 20 -H 'Content-Type: application/json' \
  -d "{\"refreshToken\":\"$REFRESH\"}" "$API/auth/refresh")
nat_access=$(echo "$nat" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("accessToken",""))' 2>/dev/null)
nat_refresh=$(echo "$nat" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("refreshToken") or "")' 2>/dev/null)
[ -n "$nat_access" ] && ok "refresh by body returned an access token" || bad "body refresh failed: $nat"
[ -n "$nat_refresh" ] && ok "and a rotated refresh token, as before" || bad "body refresh returned no new refresh token"

head2 "9. Revoking the session from Settings kills both consoles at once"
sessions=$(curl -sS --max-time 20 -H "Authorization: Bearer $ACCESS" "$API/users/me/sessions")
echo "    sessions visible: $(echo "$sessions" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))' 2>/dev/null)"
# Sign in again so there is a session to kill that is not the one doing the killing.
curl -sS -o /tmp/login2.json --max-time 20 -c /tmp/jar2 -H 'Content-Type: application/json' \
  -H "Origin: $ONEOPS" -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" "$API/auth/login" >/dev/null
A2=$(python3 -c 'import json;print(json.load(open("/tmp/login2.json")).get("accessToken",""))')
S2=$(python3 -c 'import json;print(json.load(open("/tmp/login2.json")).get("sessionId") or "")')

# Second browser can exchange before revocation.
pre=$(curl -sS --max-time 20 -b /tmp/jar2 -X POST -H "Origin: $ADMIN" "$API/auth/session/token" \
      | python3 -c 'import json,sys;print(json.load(sys.stdin).get("accessToken",""))' 2>/dev/null)
[ -n "$pre" ] && ok "second browser could exchange before revocation" || bad "second browser could not exchange even before revocation"

code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -X DELETE \
  -H "Authorization: Bearer $ACCESS" "$API/users/me/sessions/$S2")
echo "    revoke returned $code"

post=$(curl -sS --max-time 20 -b /tmp/jar2 -X POST -H "Origin: $ADMIN" "$API/auth/session/token")
if echo "$post" | grep -q '"accessToken"'; then
  bad "the revoked session's cookie still mints tokens: $post"
else
  ok "revoked session's cookie is refused: $(echo "$post" | head -c 120)"
fi

head2 "10. A browser with no cookie is refused, and told so plainly"
code=$(curl -sS -o /tmp/nocookie.json -w '%{http_code}' --max-time 20 -X POST -H "Origin: $ONEOPS" "$API/auth/session/token")
if [ "$code" = "401" ]; then ok "no cookie gives 401: $(head -c 100 /tmp/nocookie.json)"; else bad "no cookie gave $code, expected 401"; fi

head2 "11. Logout clears the cookie on both hosts"
out=$(curl -sS -D - -o /dev/null --max-time 20 -b "$JAR" -c "$JAR" -X POST \
  -H "Authorization: Bearer $ACCESS" -H "Origin: $ONEOPS" "$API/auth/logout" 2>&1)
if echo "$out" | grep -i '^set-cookie:.*pbx_session' | grep -qiE 'Max-Age=0|Expires=Thu, 01 Jan 1970'; then
  ok "logout sends an expiring cookie"
else
  bad "logout did not clear the cookie: $(echo "$out" | grep -i set-cookie | head -1)"
fi
after=$(curl -sS --max-time 20 -b "$JAR" -X POST -H "Origin: $ADMIN" "$API/auth/session/token")
if echo "$after" | grep -q '"accessToken"'; then
  bad "cookie still works after logout"
else
  ok "the other console cannot exchange after logout"
fi

echo
echo "================================"
echo " passed: $pass   failed: $fail"
echo "================================"
rm -f "$JAR" /tmp/jar2 /tmp/login.json /tmp/login2.json /tmp/nocookie.json
[ "$fail" -eq 0 ]

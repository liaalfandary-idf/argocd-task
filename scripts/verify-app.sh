#!/usr/bin/env bash
# End-to-end checks for the deployed app: TLS chain, routing, security hardening, network policy.
# Works whether the app was deployed by Argo CD or `helm install`.
# Hostnames and names are read from the cluster, not hard-coded.
#
# Usage: scripts/verify-app.sh [namespace] [name] [ca-cert]
set -u

NS="${1:-lia-temp-page}"
NAME="${2:-lia-temp-page}"                    # chart fullname = Service / Deployment name
CA="${3:-$HOME/argocd-tls/ca.crt}"
CURL_IMAGE="curlimages/curl:8.17.0"

PASS=0; FAIL=0
pass() { printf '  \e[32mPASS\e[0m %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  \e[31mFAIL\e[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi; }
section() { printf '\n\e[1m== %s\e[0m\n' "$1"; }
C() { curl -s --max-time 8 --cacert "$CA" "$@"; }

# Restricted-compliant throwaway pod; $1 = name, $2 = extra labels JSON, $3 = curl args JSON array.
# Prints the pod's log. The pod is run to completion and its log read afterwards: attaching with
# `kubectl run -i` can miss the output of a short-lived pod and make a check fail falsely.
run_pod() {
  kubectl delete pod "$1" -n "$NS" --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl run "$1" -n "$NS" --restart=Never --image="$CURL_IMAGE" \
    --overrides="{\"metadata\":{\"labels\":$2},\"spec\":{\"automountServiceAccountToken\":false,
      \"securityContext\":{\"runAsNonRoot\":true,\"runAsUser\":65532,\"seccompProfile\":{\"type\":\"RuntimeDefault\"}},
      \"containers\":[{\"name\":\"$1\",\"image\":\"$CURL_IMAGE\",\"args\":$3,
        \"securityContext\":{\"allowPrivilegeEscalation\":false,\"readOnlyRootFilesystem\":true,\"capabilities\":{\"drop\":[\"ALL\"]}},
        \"volumeMounts\":[{\"name\":\"ca\",\"mountPath\":\"/etc/ca\",\"readOnly\":true}]}],
      \"volumes\":[{\"name\":\"ca\",\"configMap\":{\"name\":\"$NAME-ca\"}}]}}" >/dev/null 2>&1
  # Wait until the pod has finished (Succeeded or Failed), up to 2 minutes
  for _ in $(seq 1 60); do
    case "$(kubectl get pod "$1" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)" in
      Succeeded|Failed) break ;;
    esac
    sleep 2
  done
  kubectl logs "$1" -n "$NS" 2>/dev/null
  kubectl delete pod "$1" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
section "1. Kubernetes resources in namespace $NS"
check "Namespace enforces Pod Security 'restricted'" \
  test "$(kubectl get ns "$NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')" = restricted
check "Deployment $NAME is fully available" kubectl rollout status deploy/"$NAME" -n "$NS" --timeout=60s
for r in service/"$NAME" configmap/"$NAME"-html configmap/"$NAME"-nginx configmap/"$NAME"-ca \
         secret/"$NAME"-tls networkpolicy/"$NAME" ingressroutetcp.traefik.io/"$NAME"; do
  check "$r exists" kubectl get "$r" -n "$NS"
done
check "Service listens on 443" test "$(kubectl get svc "$NAME" -n "$NS" -o jsonpath='{.spec.ports[0].port}')" = 443
check "IngressRouteTCP uses TLS passthrough" \
  test "$(kubectl get ingressroutetcp "$NAME" -n "$NS" -o jsonpath='{.spec.tls.passthrough}')" = true

HOSTS=$(kubectl get ingressroutetcp "$NAME" -n "$NS" -o jsonpath='{.spec.routes[0].match}' | grep -oP 'HostSNI\(`\K[^`]+')
echo "  hosts from the route: $(echo $HOSTS)"

# ---------------------------------------------------------------------------
section "2. Certificates (Secret $NAME-tls, CA $CA)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
kubectl get secret "$NAME-tls" -n "$NS" -o jsonpath='{.data.tls\.crt}' | base64 -d > "$WORK/tls.crt"
kubectl get secret "$NAME-tls" -n "$NS" -o jsonpath='{.data.tls\.key}' | base64 -d > "$WORK/tls.key"
kubectl get cm "$NAME-ca" -n "$NS" -o jsonpath='{.data.ca\.crt}' > "$WORK/ca-cm.crt"

check "CA file is 'ArgoCD Local CA'" sh -c "openssl x509 -in '$CA' -noout -subject | grep -q 'CN *= *ArgoCD Local CA'"
check "ConfigMap $NAME-ca holds the same CA (fingerprint match)" test \
  "$(openssl x509 -in "$WORK/ca-cm.crt" -noout -fingerprint -sha256)" = "$(openssl x509 -in "$CA" -noout -fingerprint -sha256)"
check "Server cert chains to the CA" openssl verify -CAfile "$CA" -x509_strict "$WORK/tls.crt"
check "Server cert valid for at least 30 more days" openssl x509 -in "$WORK/tls.crt" -noout -checkend 2592000
check "Private key matches the certificate" test \
  "$(openssl pkey -in "$WORK/tls.key" -pubout 2>/dev/null)" = "$(openssl x509 -in "$WORK/tls.crt" -noout -pubkey)"
check "Certificate is server-only (not a CA)" sh -c "openssl x509 -in '$WORK/tls.crt' -noout -ext basicConstraints | grep -q 'CA:FALSE'"
SANS=$(openssl x509 -in "$WORK/tls.crt" -noout -ext subjectAltName | tail -n +2)
for h in $HOSTS "$NAME" "$NAME.$NS.svc" "$NAME.$NS.svc.cluster.local"; do
  check "SAN covers $h" grep -q "DNS:$h\b" <<< "$SANS"
done

# ---------------------------------------------------------------------------
EXPECTED=$(kubectl get cm "$NAME-html" -n "$NS" -o jsonpath='{.data.index\.html}' | grep -c "Hello")
for H in $HOSTS; do
  U="https://$H"
  section "3. HTTPS through Traefik: $U"
  check "Certificate verified against ArgoCD Local CA" C -o /dev/null "$U/"
  check "Served cert is nginx's own, not Traefik's (passthrough)" sh -c \
    "echo | openssl s_client -connect 127.0.0.1:443 -servername '$H' 2>/dev/null | openssl x509 -noout -fingerprint -sha256 \
     | grep -qx \"\$(openssl x509 -in '$WORK/tls.crt' -noout -fingerprint -sha256)\""
  check "Page shows all $EXPECTED 'Hello' lines" test "$(C "$U/" | grep -c Hello)" = "$EXPECTED"
  check "HTTP/2 negotiated" test "$(C -o /dev/null -w '%{http_version}' "$U/")" = 2
  check "TLS 1.3 accepted" C --tlsv1.3 -o /dev/null "$U/"
  check "TLS 1.2 accepted" C --tlsv1.2 --tls-max 1.2 -o /dev/null "$U/"
  check "TLS 1.1 refused" sh -c "! curl -s --max-time 8 --cacert '$CA' --tls-max 1.1 -o /dev/null '$U/'"
  check "Plain http:// does not serve the page" sh -c "! curl -s --max-time 5 'http://$H/' | grep -q Hello"

  section "4. HTTP security behaviour: $U"
  HDRS=$(C -I "$U/")
  for hd in "strict-transport-security" "content-security-policy" "x-content-type-options: nosniff" \
            "x-frame-options: DENY" "referrer-policy: no-referrer" "permissions-policy" \
            "cross-origin-opener-policy" "cross-origin-resource-policy"; do
    check "Header $hd" grep -qi "^$hd" <<< "$HDRS"
  done
  check "nginx version hidden" sh -c "printf '%s' \"\$1\" | grep -qi '^server: nginx\s*$'" _ "$HDRS"
  check "POST rejected (405)"     test "$(C -X POST   -o /dev/null -w '%{http_code}' "$U/")" = 405
  check "DELETE rejected (405)"   test "$(C -X DELETE -o /dev/null -w '%{http_code}' "$U/")" = 405
  check "Unknown Host rejected (421)" test "$(C -H 'Host: evil.example' -o /dev/null -w '%{http_code}' "$U/")" = 421
  check "Directory listing / missing file gives 404" test "$(C -o /dev/null -w '%{http_code}' "$U/nope/")" = 404
done

# ---------------------------------------------------------------------------
section "5. Pod hardening"
POD=$(kubectl get pod -n "$NS" -l app.kubernetes.io/name=argocd-task,app.kubernetes.io/component!=test \
      --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
echo "  pod: $POD"
X() { kubectl exec -n "$NS" "$POD" -- sh -c "$1" 2>&1; }
check "Image is the official nginx image" sh -c \
  "kubectl get pod '$POD' -n '$NS' -o jsonpath='{.spec.containers[0].image}' | grep -qE '^(docker.io/library/)?nginx:'"
check "Runs as non-root user nginx (uid 101)" test "$(X 'id -u')" = 101
check "nginx listens on 443 as non-root" sh -c "kubectl exec -n '$NS' '$POD' -- cat /proc/net/tcp | awk '\$4==\"0A\"{print \$2}' | grep -qi ':01BB$'"
check "No Linux capabilities (CapEff = 0)" sh -c "kubectl exec -n '$NS' '$POD' -- grep CapEff /proc/1/status | grep -q '0000000000000000'"
check "Root filesystem is read-only" sh -c "kubectl exec -n '$NS' '$POD' -- touch /etc/x 2>&1 | grep -qi 'read-only'"
check "No Kubernetes API token mounted" sh -c "! kubectl exec -n '$NS' '$POD' -- ls /var/run/secrets/kubernetes.io/serviceaccount 2>/dev/null"
check "Private key not world-readable" sh -c "kubectl exec -n '$NS' '$POD' -- stat -L -c %a /etc/nginx/tls/tls.key | grep -qx 440"
check "Privilege escalation disabled" test \
  "$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.spec.containers[0].securityContext.allowPrivilegeEscalation}')" = false
check "Outbound internet blocked" sh -c "! kubectl exec -n '$NS' '$POD' -- timeout 4 wget -qO- http://1.1.1.1 >/dev/null 2>&1"
check "Outbound DNS blocked" sh -c "! kubectl exec -n '$NS' '$POD' -- timeout 4 nslookup kubernetes.default >/dev/null 2>&1"

# ---------------------------------------------------------------------------
section "6. Network policy + in-cluster TLS (throwaway pods, ~1 min)"
OUT=$(run_pod verify-blocked '{}' "[\"-sk\",\"--max-time\",\"5\",\"-o\",\"/dev/null\",\"-w\",\"code=%{http_code}\",\"https://$NAME.$NS.svc/\"]")
check "Unauthorised pod in the namespace is blocked" grep -q "code=000" <<< "$OUT"
FIRST=$(echo $HOSTS | awk '{print $1}')
# Retries: the first connection through the network policy can be slow (~1 s) on this CNI
OUT=$(run_pod verify-client "{\"$NAME-client\":\"true\"}" \
  "[\"-sS\",\"--max-time\",\"8\",\"--retry\",\"5\",\"--retry-delay\",\"2\",\"--retry-all-errors\",\"--cacert\",\"/etc/ca/ca.crt\",\"-o\",\"/dev/null\",\"-w\",\"svc=%{http_code} \",\"https://$NAME.$NS.svc/\",
    \"--connect-to\",\"$FIRST:443:$NAME.$NS.svc:443\",\"https://$FIRST/\"]")
check "Allowed client verifies TLS by Service DNS name (CA from ConfigMap)" grep -q "svc=200" <<< "$OUT"
check "Allowed client verifies TLS by public hostname" sh -c "printf '%s' \"\$1\" | grep -o 'svc=200' | wc -l | grep -qx 2" _ "$OUT"

# ---------------------------------------------------------------------------
printf '\n\e[1mResult: %d passed, %d failed\e[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

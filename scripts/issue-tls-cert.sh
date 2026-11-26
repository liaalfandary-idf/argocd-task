#!/usr/bin/env bash
# Issue (or rotate) the app's TLS server certificate, signed by "ArgoCD Local CA",
# and store it as a kubernetes.io/tls Secret in the app namespace.
#
# The CA private key and the server private key stay on this machine / in the cluster;
# nothing secret is written to the Git repo.
#
# Usage: scripts/issue-tls-cert.sh <namespace> [-f values-file]... [--chart dir]
#   e.g. scripts/issue-tls-cert.sh lia-temp-page
#        scripts/issue-tls-cert.sh lia-temp-page-2 -f charts/web-application/values-lia-temp-page-2.yaml
#
# Pass the same -f values files the deployment uses (Argo CD `valueFiles`).
# Hostnames are NOT configured here: the Service name, Secret name and every DNS name
# are read from the rendered chart (values `hosts` + in-cluster Service names),
# exactly as nginx's server_name uses them.
set -euo pipefail

usage() { sed -n '8,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
[ $# -ge 1 ] && [ "${1#-}" = "$1" ] || usage
NS="$1"; shift
CHART="$(dirname "$0")/../charts/web-application"
VALUES_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -f|--values) [ $# -ge 2 ] || usage; [ -f "$2" ] || { echo "No such values file: $2" >&2; exit 1; }
                 VALUES_ARGS+=(-f "$2"); shift 2 ;;
    --chart)     [ $# -ge 2 ] || usage; CHART="$2"; shift 2 ;;
    *)           usage ;;
  esac
done
CA_DIR="${CA_DIR:-$HOME/argocd-tls}"
DAYS="${DAYS:-825}"                 # same lifetime as the Argo CD certificates

umask 077
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Render the chart once and read the names from it
helm template tls "$CHART" -n "$NS" "${VALUES_ARGS[@]}" > "$WORK/rendered.yaml"
NAME="$(awk '/^kind: Service$/{f=1} f && /^  name:/{print $2; exit}' "$WORK/rendered.yaml")"
SECRET="$(awk '/- name: tls$/{f=1} f && /secretName:/{print $2; exit}' "$WORK/rendered.yaml")"
read -r -a DNS_NAMES <<< "$(grep -m1 -E '^\s+server_name ' "$WORK/rendered.yaml" | sed -E 's/^\s+server_name (.*);/\1/')"
[ -n "$NAME" ] && [ -n "$SECRET" ] && [ "${#DNS_NAMES[@]}" -gt 0 ] || { echo "Could not read names from the chart" >&2; exit 1; }

# Local copies per namespace, so instances in different namespaces never overwrite each other
OUT_DIR="$CA_DIR/$NS"
KEY="$OUT_DIR/$NAME.key"
CRT="$OUT_DIR/$NAME.crt"
SANS="$(printf 'DNS:%s,' "${DNS_NAMES[@]}")"; SANS="${SANS%,}"
echo "Issuing CN=${NAME} for: ${DNS_NAMES[*]}"

cat > "$WORK/ext.cnf" <<CNF
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = ${SANS}
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid, issuer
CNF

# ECDSA P-256 key, CSR, then sign with the local CA
openssl ecparam -name prime256v1 -genkey -noout -out "$WORK/tls.key"
openssl req -new -key "$WORK/tls.key" -subj "/CN=${NAME}" -out "$WORK/tls.csr"
openssl x509 -req -in "$WORK/tls.csr" -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
  -CAserial "$CA_DIR/ca.srl" -days "$DAYS" -sha256 -extfile "$WORK/ext.cnf" -out "$WORK/tls.crt"

openssl verify -CAfile "$CA_DIR/ca.crt" -x509_strict "$WORK/tls.crt"

# Keep a local copy next to the other Argo CD certificates (key readable only by you)
install -d -m 700 "$OUT_DIR"
install -m 600 "$WORK/tls.key" "$KEY"
install -m 644 "$WORK/tls.crt" "$CRT"

# Namespace with the strictest Pod Security level
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NS" --overwrite \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted

# Create or update the Secret (server cert + key; ca.crt for clients that read the Secret)
kubectl create secret generic "$SECRET" -n "$NS" --type=kubernetes.io/tls \
  --from-file=tls.crt="$CRT" --from-file=tls.key="$KEY" --from-file=ca.crt="$CA_DIR/ca.crt" \
  --dry-run=client -o yaml | kubectl apply -f -

echo
openssl x509 -in "$CRT" -noout -subject -issuer -dates -ext subjectAltName
echo "Secret ${NS}/${SECRET} is ready."

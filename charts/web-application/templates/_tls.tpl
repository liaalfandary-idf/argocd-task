{{/* Name of the TLS Secret nginx serves */}}
{{- define "argocd-task.tlsSecretName" -}}
{{- .Values.tls.secretName | default (printf "%s-tls" (include "argocd-task.fullname" .)) -}}
{{- end }}

{{/* Public hostnames from values.yaml (at least one is required) */}}
{{- define "argocd-task.hosts" -}}
{{- required "values.yaml: hosts must list at least one hostname" .Values.hosts | join " " -}}
{{- end }}

{{/* Every DNS name this app answers to: the public hosts + all in-cluster Service names.
     nginx's server_name uses this, and scripts/issue-tls-cert.sh reads it from the
     rendered chart to build the certificate SANs, so they can never drift apart. */}}
{{- define "argocd-task.dnsNames" -}}
{{- $svc := include "argocd-task.fullname" . -}}
{{- $ns := .Release.Namespace -}}
{{ include "argocd-task.hosts" . }} {{ $svc }} {{ $svc }}.{{ $ns }} {{ $svc }}.{{ $ns }}.svc {{ $svc }}.{{ $ns }}.svc.cluster.local
{{- end }}

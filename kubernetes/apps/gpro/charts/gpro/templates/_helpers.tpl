{{- define "gpro.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "gpro.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "gpro.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "gpro.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | quote }}
app.kubernetes.io/name: {{ include "gpro.name" . | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
{{- end -}}

{{- define "gpro.selectorLabels" -}}
app.kubernetes.io/name: {{ include "gpro.name" . | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
{{- end -}}

{{- define "gpro.componentLabels" -}}
{{- $context := .context -}}
{{ include "gpro.labels" $context }}
app.kubernetes.io/component: {{ .component | quote }}
{{- end -}}

{{- define "gpro.componentSelectorLabels" -}}
{{- $context := .context -}}
{{ include "gpro.selectorLabels" $context }}
app.kubernetes.io/component: {{ .component | quote }}
{{- end -}}

{{- define "gpro.image" -}}
{{- $tag := default .root.Chart.AppVersion .image.tag -}}
{{- printf "%s:%s" .image.repository $tag -}}
{{- end -}}

{{- define "gpro.podDnsConfig" -}}
dnsConfig:
  options:
    - name: ndots
      value: "1"
    - name: use-vc
    - name: single-request-reopen
{{- end -}}

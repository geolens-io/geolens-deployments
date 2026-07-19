{{- define "geolens.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "geolens.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "geolens.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "geolens.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "geolens.selectorLabels" -}}
app.kubernetes.io/name: {{ include "geolens.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "geolens.secretName" -}}
{{- if .Values.secrets.existingSecret -}}
{{- .Values.secrets.existingSecret -}}
{{- else -}}
{{- printf "%s-secrets" (include "geolens.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "geolens.apiUrl" -}}
http://{{ include "geolens.fullname" . }}-api:{{ .Values.service.api.port }}
{{- end -}}

{{/*
The shared /app/staging volume (GAP-022 handoff contract — see values.yaml).
With persistence enabled, api/worker/titiler all mount one RWX claim; without
it each pod gets its own emptyDir and cross-pod handoff cannot work.
*/}}
{{- define "geolens.stagingVolume" -}}
- name: staging
{{- if .Values.staging.persistence.enabled }}
  persistentVolumeClaim:
    claimName: {{ .Values.staging.persistence.existingClaim | default (printf "%s-staging" (include "geolens.fullname" .)) }}
{{- else }}
  emptyDir: {}
{{- end }}
{{- end -}}

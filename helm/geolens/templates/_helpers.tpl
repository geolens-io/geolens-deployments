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

{{/*
The ServiceAccount the api, worker, migrate and titiler pods run as. When
create is false and no name is given this resolves to "default", which is what
every release before this value existed already ran as — so an upgrade that
sets neither keeps its current identity.
*/}}
{{- define "geolens.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "geolens.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Fully qualified on purpose: the frontend nginx resolves this through its
`resolver` directive, which does not apply resolv.conf search domains — a
short Service name would NXDOMAIN at CoreDNS.
*/}}
{{- define "geolens.apiUrl" -}}
http://{{ include "geolens.fullname" . }}-api.{{ .Release.Namespace }}.svc.{{ .Values.clusterDomain }}:{{ .Values.service.api.port }}
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

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
The ServiceAccount the api, worker and titiler pods run as. With the default
create: false and no name, this resolves to "default" — what every release
before this value existed already ran as, so an upgrade that sets neither keeps
its current identity, and anything bound to that account (imagePullSecrets,
RBAC, its own workload-identity annotations) keeps applying.

The migrate Job deliberately does not use this; see migrate-job.yaml.
*/}}
{{- define "geolens.serviceAccountName" -}}
{{- $sa := .Values.serviceAccount | default dict -}}
{{- if $sa.create -}}
{{- default (include "geolens.fullname" .) $sa.name -}}
{{- else -}}
{{- default "default" $sa.name -}}
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
it each pod gets its own emptyDir, which only storage.backend=local needs to
share (s3 hands uploads over through the bucket).
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

{{/* fix(#52, #53): Pod Security "restricted" plus a read-only root, as compose
     runs these images. Titiler states the same inline. An absent value
     (--reuse-values from an older release) keeps the root read-only. */}}
{{- define "geolens.containerSecurityContext" -}}
readOnlyRootFilesystem: {{ ternary .Values.readOnlyRootFilesystem true (hasKey .Values "readOnlyRootFilesystem") }}
allowPrivilegeEscalation: false
capabilities:
  drop: ["ALL"]
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{/* #53: what the backend images write outside /app/staging, the paths compose
     mounts as tmpfs. codex review on #53: a path the component's extraVolumeMounts
     already mounts stays the operator's. Takes (list extraVolumeMounts "mounts"|"volumes"). */}}
{{- define "geolens.backendScratch" -}}
{{- $taken := list -}}
{{- range (index . 0 | default list) }}{{ $taken = append $taken .mountPath }}{{ end -}}
{{- range list (list "geolens-tmp" "/tmp") (list "geolens-home" "/home/appuser") }}
{{- if not (has (index . 1) $taken) }}
- name: {{ index . 0 }}
{{- if eq (index $ 1) "mounts" }}
  mountPath: {{ index . 1 }}
{{- else }}
  emptyDir: {}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{/* #53: one component's placement (nodeSelector, affinity, tolerations,
     topologySpreadConstraints), rendered only when set. Takes the component's
     values map; the migrate hook passes the api's. */}}
{{- define "geolens.scheduling" -}}
{{- with .nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .topologySpreadConstraints }}
topologySpreadConstraints:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/* fix(#39): one set of encryption-key checks, shared by the Secret and
     the migrate hook so the two can never disagree. */}}
{{- define "geolens.validateEncryptionKeys" -}}
{{- $cur := .Values.secrets.secretEncryptionKey | default "" | toString -}}
{{- $prev := .Values.secrets.secretEncryptionKeyPrevious | default "" | toString -}}
{{- if and $prev (not $cur) -}}
{{- fail "secrets.secretEncryptionKeyPrevious is set but secrets.secretEncryptionKey is empty; the backend refuses that at boot. Set the new key alongside the previous one." -}}
{{- end -}}
{{- /* Both backend images read the key from the Secret, so both must be new enough. */ -}}
{{- range $name, $tag := dict "api" (.Values.api.image.tag | toString) "worker" (.Values.worker.image.tag | toString) -}}
{{- if and $cur (regexMatch "^v?\\d+\\.\\d+\\.\\d+$" $tag) (semverCompare "<1.18.2-0" $tag) -}}
{{- fail (printf "secrets.secretEncryptionKey needs app images >= 1.18.2 (geolens#1882); %s tag %s would silently ignore it" $name $tag) -}}
{{- end -}}
{{- end -}}
{{- end -}}

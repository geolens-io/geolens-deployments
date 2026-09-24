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

{{/* The account api, worker and titiler run as. Unset, it is "default", what releases
     ran as before this value existed, so an upgrade keeps that account's
     imagePullSecrets, RBAC and annotations. The migrate hook never uses it. */}}
{{- define "geolens.serviceAccountName" -}}
{{- $sa := .Values.serviceAccount | default dict -}}
{{- if $sa.create -}}
{{- default (include "geolens.fullname" .) $sa.name -}}
{{- else -}}
{{- default "default" $sa.name -}}
{{- end -}}
{{- end -}}

{{/* Fully qualified: the frontend nginx resolves it through its `resolver`
     directive, which skips resolv.conf search domains, so a short Service name
     would NXDOMAIN at CoreDNS. */}}
{{- define "geolens.apiUrl" -}}
http://{{ include "geolens.fullname" . }}-api.{{ .Release.Namespace }}.svc.{{ .Values.clusterDomain }}:{{ .Values.service.api.port }}
{{- end -}}

{{/* /app/staging: one RWX claim that api, worker and titiler share when persistence
     is on, else a per-pod emptyDir, which only the s3 backend tolerates because
     it alone hands uploads to the worker through the bucket. See values.yaml. */}}
{{- define "geolens.stagingVolume" -}}
- name: staging
{{- if .Values.staging.persistence.enabled }}
  persistentVolumeClaim:
    claimName: {{ .Values.staging.persistence.existingClaim | default (printf "%s-staging" (include "geolens.fullname" .)) }}
{{- else }}
  emptyDir: {}
{{- end }}
{{- end -}}

{{/* Pod Security "restricted" plus a read-only root, as compose runs these
     images; titiler states the same inline. An absent value (--reuse-values
     from an older release) keeps the root read-only. */}}
{{- define "geolens.containerSecurityContext" -}}
readOnlyRootFilesystem: {{ ternary .Values.readOnlyRootFilesystem true (hasKey .Values "readOnlyRootFilesystem") }}
allowPrivilegeEscalation: false
capabilities:
  drop: ["ALL"]
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{/* (list extraVolumeMounts podVolumes "mounts"|"volumes"): emptyDirs where the backend
     images write outside /app/staging, as compose mounts tmpfs. A path the operator
     already mounts stays theirs; an operator volume reusing one of these names fails. */}}
{{- define "geolens.backendScratch" -}}
{{- $taken := list -}}
{{- range (index . 0 | default list) }}{{ $taken = append $taken .mountPath }}{{ end -}}
{{- $names := list -}}
{{- range (index . 1 | default list) }}{{ $names = append $names .name }}{{ end -}}
{{- range list (list "geolens-tmp" "/tmp") (list "geolens-home" "/home/appuser") }}
{{- if not (has (index . 1) $taken) }}
{{- if has (index . 0) $names }}
{{- fail (printf "extraVolumes defines %q, the name the chart gives its %s emptyDir; rename that volume" (index . 0) (index . 1)) }}
{{- end }}
- name: {{ index . 0 }}
{{- if eq (index $ 2) "mounts" }}
  mountPath: {{ index . 1 }}
{{- else }}
  emptyDir: {}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{/* One component's placement (nodeSelector, affinity, tolerations,
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

{{/* One set of encryption-key checks, shared by the Secret and
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

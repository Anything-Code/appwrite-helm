{{/*
Expand the name of the chart.
*/}}
{{- define "appwrite.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "appwrite.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "appwrite.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "appwrite.labels" -}}
app.kubernetes.io/name: {{ include "appwrite.name" . }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- range $name, $value := .Values.commonLabels }}
{{ $name }}: {{ $value  }}
{{- end }}
{{- end -}}

{{/*
Selector labels
*/}}
{{- define "appwrite.selectorLabels" -}}
app.kubernetes.io/name: {{ include "appwrite.name" . }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
{{- end -}}

{{- define "boolToStr" }}
{{- if . -}}
  "enabled"
{{- else -}}
  "disabled"
{{- end -}}
{{- end -}}

{{- define "_arrayjoin"}}
{{- range $i, $val := . }}
{{- (print $val ",") -}}
{{ end -}}
{{- end -}}

{{- define "array.join" }}
{{- include "_arrayjoin" . | trimSuffix "," | quote -}}
{{- end -}}

{{- define "_sitoNum" }}
{{- if hasSuffix "Gi" . -}}
{{ mul (mul (mul (trimSuffix "Gi" . | atoi) 1024) 1024) 1024 }}
{{- else if hasSuffix "Mi" . -}}
{{ mul (mul (trimSuffix "Mi" . | atoi) 1024) 1024 }}
{{- else if hasSuffix "Ki" . -}}
{{ mul (trimSuffix "Ki" . | atoi) 1024 }}
{{- end -}}
{{- end -}}

{{- define "si.toNum" }}
{{- include "_sitoNum" . | quote -}}
{{- end -}}

{{- define "probeTcp" -}}
livenessProbe:
  tcpSocket:
    port: {{ . }}
  initialDelaySeconds: 5
  periodSeconds: 10
  timeoutSeconds: 3
  failureThreshold: 3
readinessProbe:
  tcpSocket:
    port: {{ . }}
  initialDelaySeconds: 15
  periodSeconds: 5
  timeoutSeconds: 3
  failureThreshold: 3
startupProbe:
  tcpSocket:
    port: {{ . }}
  initialDelaySeconds: 60
  periodSeconds: 5
  timeoutSeconds: 3
  failureThreshold: 3
{{- end -}}

{{- define "probeHttp" -}}
livenessProbe:
  tcpSocket:
    port: http
  initialDelaySeconds: 5
  periodSeconds: 10
  timeoutSeconds: 3
  failureThreshold: 3
readinessProbe:
  tcpSocket:
    port: http
  initialDelaySeconds: 15
  periodSeconds: 5
  timeoutSeconds: 3
  failureThreshold: 3
startupProbe:
  tcpSocket:
    port: http
  initialDelaySeconds: 15
  periodSeconds: 5
  timeoutSeconds: 3
  failureThreshold: 3
{{- end -}}

# Place it to initContainers section
{{- define "influxdbCheck" -}}
- name: wait-for-influxdb
  image: busybox:1.36
  command:
    - sh
    - -c
    - |
      echo "Waiting for InfluxDB at {{ .Values.influxdb.host }}:{{ .Values.influxdb.port }}..."
      until nc -z {{ .Values.influxdb.host }} {{ .Values.influxdb.port }}; do
        echo "InfluxDB is unavailable - sleeping"
        sleep 2
      done
      echo "InfluxDB is up!"
{{- end }}

{{- define "dbCheck" -}}
- name: wait-for-mariadb
  image: busybox:1.36
  command:
    - sh
    - -c
    - |
      echo "Waiting for MariaDB at {{ include "appwrite.fullname" . }}-mariadb:3306..."
      until nc -z {{ include "appwrite.fullname" . }}-mariadb 3306; do
        echo "MariaDB is unavailable - sleeping"
        sleep 2
      done
      echo "MariaDB is up!"
{{- end }}

{{- define "redisCheck" -}}
- name: wait-for-redis
  image: busybox:1.36
  command:
    - sh
    - -c
    - |
      echo "Waiting for Redis at {{ include "appwrite.fullname" . }}-redis-master:6379..."
      until nc -z {{ include "appwrite.fullname" . }}-redis-master 6379; do
        echo "Redis is unavailable - sleeping"
        sleep 2
      done
      echo "Redis is up!"
{{- end }}

{{- define "coreCheck" -}}
- name: wait-for-core
  image: busybox:1.36
  command:
    - sh
    - -c
    - |
      echo "Waiting for Appwrite Core at {{ include "appwrite.fullname" . }}-core:80..."
      until nc -z {{ include "appwrite.fullname" . }}-core 80; do
        echo "Appwrite Core is unavailable - sleeping"
        sleep 2
      done
      echo "Appwrite Core is up!"
{{- end }}

{{/*
Pod affinity to colocate with appwrite-core (for RWO volumes).
Only rendered when appwrite.volumes.coreAffinity.enabled is true.
*/}}
{{- define "appwrite.coreAffinity" -}}
{{- if .Values.appwrite.volumes.coreAffinity.enabled }}
affinity:
  podAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchLabels:
          {{- include "appwrite.selectorLabels" . | nindent 10 }}
          app.kubernetes.io/component: core
      topologyKey: kubernetes.io/hostname
{{- end }}
{{- end }}

{{/*
Executor secret - generated once and reused.
Uses existing secret if found, otherwise uses values or generates new.
*/}}
{{- define "appwrite.executorSecret" -}}
{{- if .Values.executor.secret -}}
{{- .Values.executor.secret -}}
{{- else -}}
{{- $secretObj := (lookup "v1" "Secret" (include "appwrite.namespace" .) (printf "%s-executor-env" (include "appwrite.fullname" .))) | default dict }}
{{- $secretData := (get $secretObj "data") | default dict }}
{{- $existingSecret := (get $secretData "OPR_EXECUTOR_SECRET") | default "" | b64dec }}
{{- if $existingSecret -}}
{{- $existingSecret -}}
{{- else -}}
{{- randAlphaNum 32 -}}
{{- end -}}
{{- end -}}
{{- end }}

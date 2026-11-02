{{/*
Expand the name of the chart.
*/}}
{{- define "lab-tenants.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "lab-tenants.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels for all resources in the chart.
*/}}
{{- define "lab-tenants.labels" -}}
helm.sh/chart: {{ include "lab-tenants.chart" . }}
app.kubernetes.io/name: {{ include "lab-tenants.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

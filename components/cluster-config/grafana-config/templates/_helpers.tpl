{{/*
Datasource input bindings for community dashboards.

grafana-operator does not auto-bind __inputs.<NAME> declarations from
imported dashboards. Without an explicit mapping, every panel renders
"Datasource ${DS_X} was not found". Listing common input names here
covers our existing dashboards; the operator only substitutes inputs
actually present in the dashboard JSON, so extra entries are no-ops.
*/}}
{{- define "grafana-config.datasourceBindings" -}}
- inputName: DS_PROMETHEUS
  datasourceName: Prometheus
- inputName: DS_PROM
  datasourceName: Prometheus
- inputName: DS_VICTORIAMETRICS-PROD-ALL
  datasourceName: Prometheus
{{- end -}}

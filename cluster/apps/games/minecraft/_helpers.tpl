{{- define "mychart.urls" -}}
{{- range $index, $element := .Files.Lines "mod-urls.txt" -}}
  {{- if $index }},{{ end -}}
  {{ $element | trim -}}
{{- end -}}
{{- end -}}

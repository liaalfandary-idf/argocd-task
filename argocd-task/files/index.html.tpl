<!DOCTYPE html>
<html>
  <head>
    <title>{{ .Values.page.title }}</title>
  </head>
  <body>
    {{- range $i, $subject := .Values.subjects }}
    <h1 style="color: {{ index $.Values.colors (mod $i (len $.Values.colors)) }}">Hello {{ $subject }}</h1>
    {{- end }}
  </body>
</html>
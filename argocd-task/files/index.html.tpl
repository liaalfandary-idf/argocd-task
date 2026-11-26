<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="color-scheme" content="light dark">
    <title>{{ .Values.page.title | html }}</title>
    <link rel="stylesheet" href="/styles.css">
  </head>
  <body>
    <main class="page">
      <header class="hero">
        <p class="eyebrow">{{ len .Values.subjects }} greetings</p>
        <h1>{{ .Values.page.title | html }}</h1>
        <p class="lede">Rendered by Helm, deployed by Argo CD, served by nginx over HTTPS.</p>
      </header>

      <ul class="grid">
        {{- range $i, $subject := .Values.subjects }}
        <li class="card c{{ mod $i (len $.Values.colors) }}"><span class="avatar" aria-hidden="true">{{ substr 0 1 $subject | upper | html }}</span><span class="greeting"><span class="hello">Hello</span> <span class="name">{{ $subject | html }}</span></span></li>
        {{- end }}
      </ul>

      <footer class="footer">
        <svg class="lock" viewBox="0 0 16 16" aria-hidden="true"><path d="M4.5 7V5a3.5 3.5 0 0 1 7 0v2h.5A1.5 1.5 0 0 1 13.5 8.5v5A1.5 1.5 0 0 1 12 15H4a1.5 1.5 0 0 1-1.5-1.5v-5A1.5 1.5 0 0 1 4 7h.5Zm1.5 0h4V5a2 2 0 1 0-4 0v2Z"/></svg>
        <span>TLS by ArgoCD Local CA</span>
      </footer>
    </main>
  </body>
</html>

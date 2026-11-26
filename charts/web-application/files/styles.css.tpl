:root {
  --bg: #f5f6f8;
  --surface: #ffffff;
  --text: #1b2130;
  --muted: #5e6776;
  --border: #e2e5ea;
  --shadow: 0 1px 2px rgb(16 24 40 / 0.04), 0 1px 3px rgb(16 24 40 / 0.06);
  --shadow-hover: 0 4px 12px rgb(16 24 40 / 0.08), 0 2px 4px rgb(16 24 40 / 0.06);
  --radius: 14px;
  --accent-text-mix: 78%;   /* how much of the raw accent shows in text (light mode) */
  font-family: system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  line-height: 1.5;
  -webkit-font-smoothing: antialiased;
}

@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0e1117;
    --surface: #161b24;
    --text: #e7eaf0;
    --muted: #98a1b0;
    --border: #252c38;
    --shadow: 0 1px 2px rgb(0 0 0 / 0.3);
    --shadow-hover: 0 6px 16px rgb(0 0 0 / 0.35);
    --accent-text-mix: 55%;  /* lighter accents on dark backgrounds for contrast */
  }
}

/* One accent per entry in values.yaml `colors` */
{{- range $i, $c := .Values.colors }}
.c{{ $i }} { --accent: {{ $c }}; }
{{- end }}

*, *::before, *::after { box-sizing: border-box; }

body {
  margin: 0;
  min-height: 100vh;
  display: grid;
  place-items: center;
  padding: clamp(1.5rem, 5vw, 4rem) 1.25rem;
  background: var(--bg);
  color: var(--text);
}

.page {
  width: 100%;
  max-width: 880px;
}

.hero {
  margin-bottom: 2.25rem;
}

.eyebrow {
  margin: 0 0 0.5rem;
  font-size: 0.8rem;
  font-weight: 600;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: var(--muted);
}

h1 {
  margin: 0;
  font-size: clamp(2rem, 5vw, 2.9rem);
  font-weight: 700;
  letter-spacing: -0.02em;
  line-height: 1.1;
}

.lede {
  margin: 0.75rem 0 0;
  max-width: 46ch;
  color: var(--muted);
}

.grid {
  list-style: none;
  margin: 0;
  padding: 0;
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(210px, 1fr));
  gap: 0.875rem;
}

.card {
  display: flex;
  align-items: center;
  gap: 0.875rem;
  padding: 1rem 1.125rem;
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  box-shadow: inset 3px 0 0 var(--accent), var(--shadow);
  box-shadow: inset 3px 0 0 color-mix(in oklab, var(--accent) 70%, var(--surface)), var(--shadow);
  transition: transform 160ms ease, box-shadow 160ms ease, border-color 160ms ease;
  animation: rise 360ms ease both;
}

.card:hover {
  transform: translateY(-2px);
  box-shadow: inset 3px 0 0 var(--accent), var(--shadow-hover);
  border-color: var(--accent);
  border-color: color-mix(in oklab, var(--accent) 45%, var(--border));
}

.avatar {
  flex: none;
  display: grid;
  place-items: center;
  width: 2.75rem;
  height: 2.75rem;
  border-radius: 50%;
  font-weight: 700;
  font-size: 1.1rem;
  color: var(--accent);
  color: color-mix(in oklab, var(--accent) var(--accent-text-mix), var(--text));
  background: var(--border);
  background: color-mix(in oklab, var(--accent) 18%, var(--surface));
}

.greeting {
  display: flex;
  flex-direction: column;
  min-width: 0;
}

.hello {
  font-size: 0.78rem;
  font-weight: 600;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(--muted);
}

.name {
  font-size: 1.15rem;
  font-weight: 650;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.footer {
  display: flex;
  align-items: center;
  gap: 0.45rem;
  margin-top: 2.5rem;
  font-size: 0.85rem;
  color: var(--muted);
}

.lock {
  width: 0.95rem;
  height: 0.95rem;
  fill: currentColor;
}

@keyframes rise {
  from { opacity: 0; transform: translateY(6px); }
  to   { opacity: 1; transform: none; }
}

@media (prefers-reduced-motion: reduce) {
  .card { animation: none; transition: none; }
  .card:hover { transform: none; }
}

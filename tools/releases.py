# SPDX-License-Identifier: GPL-3.0-or-later
"""Render site/releases/index.html from the release notes in site/releases/*.md.

    python3 tools/releases.py            write site/releases/index.html
    python3 tools/releases.py --check    exit 1 when the committed page is stale

Each notes file is site/releases/<version>.md. Line 1 is `# Playport <version>`,
optionally followed by `: <tagline>`; line 2 is `<!-- date: YYYY-MM-DD -->`, the
GitHub publish date. The rest is the Markdown that `pp release` also uses as the
GitHub release body. The page lists every release newest first, each under an
`id="v<version>"` anchor. Links to https://playport.dev/ become relative (../), so
the page works before the site is deployed.

The Markdown renderer is a small stdlib one, deterministic across machines; it
covers what release notes use: headings, paragraphs, lists (nested by
indentation), tables, block quotes, fenced code, rules, emphasis, code, links and
images. Raw HTML is escaped, not passed through.
"""

import argparse
import html
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
NOTES = REPO / "site" / "releases"
SITE_URL = "https://playport.dev/"

TITLE = re.compile(r"# Playport ((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))(?:: (.+))?")
DATE = re.compile(r"<!-- date: (\d{4}-\d{2}-\d{2}) -->")
MONTHS = ("January", "February", "March", "April", "May", "June", "July", "August", "September",
          "October", "November", "December")


class Bad(Exception):
    pass


# Inline Markdown

INLINE = re.compile(
    r"(?P<code>`+)(?P<code_text>.+?)(?P=code)"
    r"|!\[(?P<img_alt>[^\]]*)\]\((?P<img_url>[^)\s]+)\)"
    r"|\[(?P<link_text>(?:[^\[\]]|\[[^\]]*\])+)\]\((?P<link_url>[^)\s]+)\)"
    r"|<(?P<auto>https?://[^>\s]+)>"
    r"|\\(?P<escaped>[\\`*_{}\[\]()#+\-.!|<>])")
STRONG = re.compile(r"\*\*(?=\S)(.+?)(?<=\S)\*\*|__(?=\S)(.+?)(?<=\S)__", re.S)
EMPH = re.compile(r"(?<![\w*])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![\w*])|(?<!\w)_(?=\S)(.+?)(?<=\S)_(?!\w)", re.S)


def url(target):
    if target.startswith(SITE_URL):
        target = "../" + target[len(SITE_URL):]
    return html.escape(target)


def emphasis(text):
    """Escaped plain text with ** and * emphasis."""
    text = html.escape(text, quote=False)
    text = STRONG.sub(lambda m: f"<strong>{m.group(1) or m.group(2)}</strong>", text)
    return EMPH.sub(lambda m: f"<em>{m.group(1) or m.group(2)}</em>", text)


def inline(text):
    """Code spans, images, links and escapes first; emphasis on the text between,
    and inside link text. A placeholder keeps emphasis from crossing a token."""
    tokens = []

    def hold(markup):
        tokens.append(markup)
        return f"\x00{len(tokens) - 1}\x00"

    def token(m):
        if m.group("code"):
            return hold(f"<code>{html.escape(m.group('code_text').strip(), quote=False)}</code>")
        if m.group("img_url"):
            return hold(f'<img src="{url(m.group("img_url"))}" alt="{html.escape(m.group("img_alt"))}" '
                        'loading="lazy">')
        if m.group("link_url"):
            return hold(f'<a href="{url(m.group("link_url"))}">{inline(m.group("link_text"))}</a>')
        if m.group("auto"):
            return hold(f'<a href="{url(m.group("auto"))}">{html.escape(m.group("auto"), quote=False)}</a>')
        return hold(html.escape(m.group("escaped"), quote=False))

    text = emphasis(INLINE.sub(token, text))
    return re.sub(r"\x00(\d+)\x00", lambda m: tokens[int(m.group(1))], text)


# Block Markdown

HEADING = re.compile(r"(#{1,6})\s+(.*?)\s*#*\s*$")
BULLET = re.compile(r"( {0,3})([-*+])( +)(.*)")
ORDERED = re.compile(r"( {0,3})(\d{1,9})([.)])( +)(.*)")
RULE = re.compile(r" {0,3}([-*_])(\s*\1){2,}\s*$")
FENCE = re.compile(r" {0,3}(```+|~~~+)\s*([\w+-]*)\s*$")
TABLE_SEP = re.compile(r"\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$")
COMMENT = re.compile(r"\s*<!--.*?-->\s*$")


def list_marker(line):
    m = BULLET.fullmatch(line)
    if m and not RULE.match(line):
        return "ul", len(m.group(1)) + 1 + len(m.group(3)), m.group(4), None
    m = ORDERED.fullmatch(line)
    if m:
        return "ol", len(m.group(1)) + len(m.group(2)) + 1 + len(m.group(4)), m.group(5), int(m.group(2))
    return None


def cells(row):
    row = row.strip()
    if row.startswith("|"):
        row = row[1:]
    if row.endswith("|") and not row.endswith("\\|"):
        row = row[:-1]
    return [c.strip() for c in re.split(r"(?<!\\)\|", row)]


def starts_block(lines, i):
    line = lines[i]
    return bool(HEADING.match(line) or FENCE.match(line) or RULE.match(line) or line.lstrip().startswith(">")
                or list_marker(line) or COMMENT.match(line)
                or (i + 1 < len(lines) and "|" in line and TABLE_SEP.match(lines[i + 1])))


def indent(line):
    return len(line) - len(line.lstrip(" "))


def blocks(lines, tight=False, shift=0):
    """Render Markdown lines to HTML. tight: list item paragraphs without <p>.
    shift: added to heading levels."""
    out, i = [], 0
    while i < len(lines):
        line = lines[i]
        if not line.strip() or COMMENT.match(line):
            i += 1
            continue
        if m := FENCE.match(line):
            end = i + 1
            while end < len(lines) and not lines[end].strip().startswith(m.group(1)):
                end += 1
            lang = f' class="language-{m.group(2)}"' if m.group(2) else ""
            code = html.escape("\n".join(lines[i + 1:end]) + "\n", quote=False)
            out.append(f"<pre><code{lang}>{code}</code></pre>")
            i = end + 1
            continue
        if m := HEADING.match(line):
            level = min(len(m.group(1)) + shift, 6)
            out.append(f"<h{level}>{inline(m.group(2))}</h{level}>")
            i += 1
            continue
        if RULE.match(line):
            out.append("<hr>")
            i += 1
            continue
        if line.lstrip().startswith(">"):
            quoted = []
            while i < len(lines) and lines[i].strip() and (lines[i].lstrip().startswith(">") or quoted):
                quoted.append(re.sub(r"^\s*> ?", "", lines[i]))
                i += 1
            out.append(f"<blockquote>\n{blocks(quoted, shift=shift)}\n</blockquote>")
            continue
        if "|" in line and i + 1 < len(lines) and TABLE_SEP.match(lines[i + 1]):
            head = cells(line)
            aligns = []
            for sep in cells(lines[i + 1]):
                aligns.append(' style="text-align: center"' if sep.startswith(":") and sep.endswith(":") else
                              ' style="text-align: right"' if sep.endswith(":") else "")
            rows = ["<tr>" + "".join(f"<th{a}>{inline(c)}</th>" for c, a in zip(head, aligns)) + "</tr>"]
            i += 2
            while i < len(lines) and lines[i].strip() and "|" in lines[i]:
                row = cells(lines[i]) + [""] * len(head)
                rows.append("<tr>" + "".join(f"<td{a}>{inline(c)}</td>" for c, a in zip(row, aligns)) + "</tr>")
                i += 1
            out.append('<div class="table"><table>\n<thead>\n' + rows[0] + "\n</thead>\n<tbody>\n"
                       + "\n".join(rows[1:]) + "\n</tbody>\n</table></div>")
            continue
        if first := list_marker(line):
            i = render_list(lines, i, first, out, shift)
            continue
        para = [line.strip()]
        i += 1
        while i < len(lines) and lines[i].strip() and not starts_block(lines, i):
            para.append(lines[i].strip())
            i += 1
        text = inline("\n".join(para))
        out.append(text if tight else f"<p>{text}</p>")
    return "\n".join(out)


def render_list(lines, i, first, out, shift):
    kind, _, _, start = first
    base = indent(lines[i])
    items, loose = [], False
    while i < len(lines):
        marker = list_marker(lines[i]) if indent(lines[i]) == base else None
        if not marker or marker[0] != kind:
            break
        width = marker[1]
        item = [marker[2]]
        i += 1
        while i < len(lines):
            line = lines[i]
            if not line.strip():
                # After a blank line, indented content continues the item and a
                # sibling marker the list (both make it loose); anything else ends it.
                nxt = i + 1
                while nxt < len(lines) and not lines[nxt].strip():
                    nxt += 1
                if nxt < len(lines) and indent(lines[nxt]) >= width:
                    item.extend([""] * (nxt - i))
                    loose, i = True, nxt
                    continue
                sibling = list_marker(lines[nxt]) if nxt < len(lines) and indent(lines[nxt]) == base else None
                if sibling and sibling[0] == kind:
                    loose, i = True, nxt
                break
            if indent(line) >= width:
                item.append(line[width:])
            elif indent(line) <= base and starts_block(lines, i):
                break
            elif list_marker(line) and indent(line) > base:
                item.append(line[indent(line):] if indent(line) < width else line[width:])
            else:
                item.append(line.strip())  # lazy continuation
            i += 1
        items.append(item)
    attr = f' start="{start}"' if kind == "ol" and start != 1 else ""
    body = "\n".join(f"<li>{blocks(item, tight=not loose, shift=shift)}</li>" for item in items)
    out.append(f"<{kind}{attr}>\n{body}\n</{kind}>")
    return i


def markdown(text, shift=0):
    return blocks(text.replace("\r\n", "\n").split("\n"), shift=shift)


# Notes files and the page

def version_key(version):
    return tuple(int(n) for n in version.split("."))


def read_notes(folder=NOTES):
    releases = []
    for path in sorted(folder.glob("*.md")):
        lines = path.read_text(encoding="utf-8").replace("\r\n", "\n").split("\n")
        title = TITLE.fullmatch(lines[0]) if lines else None
        if not title or title.group(1) != path.stem:
            raise Bad(f"{path.name}: line 1 must be '# Playport {path.stem}' or '# Playport {path.stem}: <tagline>'")
        date = DATE.fullmatch(lines[1]) if len(lines) > 1 else None
        if not date:
            raise Bad(f"{path.name}: line 2 must be '<!-- date: YYYY-MM-DD -->'")
        releases.append({"version": title.group(1), "tagline": title.group(2), "date": date.group(1),
                         "body": "\n".join(lines[2:])})
    if not releases:
        raise Bad(f"no release notes in {folder}")
    return sorted(releases, key=lambda r: version_key(r["version"]), reverse=True)


def long_date(date):
    year, month, day = (int(n) for n in date.split("-"))
    return f"{day} {MONTHS[month - 1]} {year}"


STYLE = """\
  :root {
    --bg: #0B0E13;
    --surface: #151A21;
    --surface-2: #1D242E;
    --surface-3: #24324A;
    --line: #2A3340;
    --accent: #F5B544;
    --accent-tint: #FFD08A;
    --text: #EEF1F5;
    --muted: #9AA4B2;
    --radius: 18px;
    --max: 1120px;
    --read: 820px;
  }
  * { box-sizing: border-box; }
  html { scroll-padding-top: 84px; }
  body {
    margin: 0;
    background: var(--bg);
    color: var(--text);
    font: 17px/1.6 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Inter, Roboto, "Helvetica Neue", Arial, sans-serif;
    -webkit-font-smoothing: antialiased;
  }
  a { color: var(--accent-tint); text-decoration: none; }
  a:hover { text-decoration: underline; }
  code { font: 0.92em ui-monospace, "SF Mono", Menlo, Consolas, monospace; background: var(--surface-2); padding: 2px 6px; border-radius: 6px; }
  .wrap { max-width: var(--max); margin: 0 auto; padding: 0 24px; }

  nav { position: sticky; top: 0; z-index: 10; background: rgba(11, 14, 19, 0.82); backdrop-filter: blur(14px); -webkit-backdrop-filter: blur(14px); border-bottom: 1px solid rgba(42, 51, 64, 0.6); }
  nav .wrap { display: flex; align-items: center; gap: 28px; height: 64px; }
  .brand { display: flex; align-items: center; gap: 10px; color: var(--text); font-weight: 700; font-size: 19px; letter-spacing: -0.01em; }
  .brand:hover { text-decoration: none; }
  .brand img { width: 30px; height: 30px; }
  nav .links { display: flex; align-items: center; gap: 24px; margin-left: auto; font-size: 15px; }
  nav .links a { color: var(--muted); }
  nav .links a:hover { color: var(--text); text-decoration: none; }
  nav .links a[aria-current="page"] { color: var(--text); }

  .btn { display: inline-flex; align-items: center; gap: 10px; padding: 13px 22px; border-radius: 999px; font-weight: 600; font-size: 16px; transition: transform .15s ease, background .15s ease; }
  .btn:hover { text-decoration: none; transform: translateY(-1px); }
  .btn svg { width: 18px; height: 18px; }
  .btn-primary { background: var(--accent); color: #1A1306; box-shadow: 0 8px 30px -8px rgba(245, 181, 68, 0.55); }
  .btn-primary:hover { background: var(--accent-tint); }
  .btn-ghost { background: var(--surface-2); color: var(--text); border: 1px solid var(--line); }
  .btn-ghost:hover { background: var(--surface-3); }
  .btn-small { padding: 8px 16px; font-size: 14px; }
  nav .links a.btn-primary { color: #1A1306; }
  .btn-kofi { background: #FF5E5B; color: #fff; }
  .btn-kofi:hover { background: #FF7A77; }
  nav .links a.btn-kofi, nav .links a.btn-kofi:hover { color: #fff; }

  header { padding: 64px 0 24px; }
  .kicker { color: var(--accent); font-weight: 700; font-size: 13px; letter-spacing: 0.14em; text-transform: uppercase; margin: 0 0 12px; }
  header h1 { font-size: clamp(34px, 5vw, 52px); line-height: 1.08; letter-spacing: -0.025em; margin: 0 0 16px; font-weight: 800; }
  .sub { color: var(--muted); font-size: 18px; max-width: 760px; margin: 0 0 24px; }
  .ctas { display: flex; flex-wrap: wrap; gap: 14px; }
  .versions { display: flex; flex-wrap: wrap; gap: 8px; margin: 28px 0 0; padding: 0; list-style: none; }
  .versions a { display: inline-block; padding: 6px 13px; border-radius: 999px; border: 1px solid var(--line); background: var(--surface); color: var(--muted); font-size: 14px; font-weight: 600; }
  .versions a:hover { color: var(--text); border-color: rgba(245, 181, 68, 0.6); text-decoration: none; }

  main { padding: 16px 0 72px; }
  .release { background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius); padding: 36px 40px; margin: 0 0 28px; }
  .release > header { padding: 0 0 8px; margin: 0 0 20px; border-bottom: 1px solid var(--line); }
  .release > header p { margin: 0 0 6px; color: var(--muted); font-size: 14.5px; }
  .release > header .version { color: var(--accent); font-weight: 700; letter-spacing: 0.06em; }
  .release > header h2 { margin: 0 0 12px; font-size: clamp(26px, 3.4vw, 34px); line-height: 1.15; letter-spacing: -0.02em; }
  .release > header h2 a { color: var(--text); }
  .notes { max-width: var(--read); }
  .notes h2, .notes h3 { font-size: 22px; letter-spacing: -0.01em; margin: 32px 0 10px; }
  .notes h4, .notes h5, .notes h6 { font-size: 18px; margin: 24px 0 8px; }
  .notes p, .notes ul, .notes ol, .notes blockquote, .notes pre, .notes .table { margin: 0 0 14px; }
  .notes ul, .notes ol { padding-left: 24px; }
  .notes li { margin: 0 0 6px; }
  .notes li > ul, .notes li > ol { margin: 6px 0 0; }
  .notes img { display: block; max-width: 100%; height: auto; margin: 8px 0; border-radius: 14px; border: 1px solid var(--line); background: var(--surface-2); }
  .notes blockquote { padding: 2px 18px; border-left: 3px solid var(--accent); color: var(--muted); }
  .notes pre { padding: 14px 16px; overflow-x: auto; background: var(--surface-2); border-radius: 10px; }
  .notes pre code { padding: 0; background: none; }
  .notes hr { border: 0; border-top: 1px solid var(--line); margin: 24px 0; }
  .notes .table { overflow-x: auto; }
  .notes table { width: 100%; border-collapse: separate; border-spacing: 0; border: 1px solid var(--line); border-radius: 12px; overflow: hidden; font-size: 15.5px; }
  .notes th, .notes td { padding: 10px 14px; text-align: left; vertical-align: top; border-bottom: 1px solid var(--line); }
  .notes tr:last-child td { border-bottom: 0; }
  .notes th { color: var(--muted); font-size: 12.5px; letter-spacing: 0.08em; text-transform: uppercase; font-weight: 700; background: var(--surface-2); }

  footer { border-top: 1px solid var(--line); padding: 36px 0 48px; color: var(--muted); font-size: 14.5px; }
  footer .wrap { display: flex; flex-wrap: wrap; gap: 20px 48px; justify-content: space-between; align-items: center; }
  footer p { margin: 0; }

  @media (max-width: 640px) {
    .wrap { padding: 0 16px; }
    nav .links a:not(.btn) { display: none; }
    header { padding: 40px 0 16px; }
    .release { padding: 24px 18px; }
  }
"""

DOWNLOAD = "https://github.com/playportdev/playport/releases"


def page(releases):
    chips = "\n".join(f'      <li><a href="#v{r["version"]}">{r["version"]}</a></li>' for r in releases)
    sections = []
    for r in releases:
        v = r["version"]
        title = f"Playport {v}" + (f": {r['tagline']}" if r["tagline"] else "")
        sections.append(f"""\
<section class="release" id="v{v}">
  <header>
    <p><span class="version">{v}</span> · <time datetime="{r['date']}">{long_date(r['date'])}</time></p>
    <h2><a href="#v{v}">{inline(title)}</a></h2>
  </header>
  <div class="notes">
{markdown(r['body'], shift=1)}
  </div>
</section>""")
    body = "\n\n".join(sections)
    return f"""\
<!doctype html>
<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Generated by tools/releases.py from site/releases/*.md. Do not edit: edit the notes and run
     python3 tools/releases.py. -->
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Releases: Playport</title>
<meta name="description" content="What is new in each Playport release, newest first.">
<meta name="theme-color" content="#0B0E13">
<meta property="og:title" content="Releases: Playport">
<meta property="og:description" content="What is new in each Playport release, newest first.">
<meta property="og:type" content="website">
<meta property="og:image" content="https://playport.dev/screenshots/og-0.5.jpg">
<meta name="twitter:card" content="summary_large_image">
<link rel="icon" href="../logo.svg" type="image/svg+xml">
<style>
{STYLE}</style>
</head>
<body>

<nav>
  <div class="wrap">
    <a class="brand" href="../"><img src="../logo.svg" alt="">Playport</a>
    <div class="links">
      <a href="../">Home</a>
      <a href="../#start">Get started</a>
      <a href="../compatibility/">Games</a>
      <a href="./" aria-current="page">Releases</a>
      <a class="btn btn-kofi btn-small" href="https://ko-fi.com/playportdev">♥ Support</a>
      <a class="btn btn-primary btn-small" href="{DOWNLOAD}">Download</a>
    </div>
  </div>
</nav>

<header>
  <div class="wrap">
    <p class="kicker">Releases</p>
    <h1>What is new in Playport.</h1>
    <p class="sub">Every release, newest first. The IPA, its source and notices are attached to each release on GitHub.</p>
    <div class="ctas">
      <a class="btn btn-primary" href="{DOWNLOAD}">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4v11m0 0-4.5-4.5M12 15l4.5-4.5M5 20h14"/></svg>
        Download the IPA</a>
      <a class="btn btn-ghost" href="../#start">How to install</a>
    </div>
    <ul class="versions" aria-label="Releases">
{chips}
    </ul>
  </div>
</header>

<main>
  <div class="wrap">

{body}

  </div>
</main>

<footer>
  <div class="wrap">
    <p>Playport. GNU GPL version 3 or later; every component keeps its own licence.</p>
    <a class="btn btn-ghost btn-small" href="https://github.com/playportdev/playport">Source on GitHub</a>
  </div>
</footer>

</body>
</html>
"""


def main(argv=None):
    ap = argparse.ArgumentParser(prog="tools/releases.py", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="exit 1 when site/releases/index.html is stale")
    args = ap.parse_args(argv)
    try:
        releases = read_notes()
        html_text = page(releases)
    except Bad as exc:
        print(f"releases: {exc}", file=sys.stderr)
        return 2
    target = NOTES / "index.html"
    if args.check:
        if not target.exists() or target.read_text(encoding="utf-8") != html_text:
            print("releases: site/releases/index.html is stale; run python3 tools/releases.py", file=sys.stderr)
            return 1
        return 0
    target.write_text(html_text, encoding="utf-8")
    print(f"releases: wrote {target.relative_to(REPO)} ({len(releases)} releases)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

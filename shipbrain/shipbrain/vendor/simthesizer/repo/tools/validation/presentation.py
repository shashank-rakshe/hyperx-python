"""Self-contained evidence report with aligned step plots and explicit gaps."""

import html
import json


def step_plot(rows, keys, title, unit):
    esc = lambda s: html.escape(str(s), quote=True)
    points = [row[k] for row in rows for k in keys if row[k] is not None]
    if not points:
        return "<p>No comparable plotted observations.</p>"
    lo = min(0, min(points))
    hi = max(0, max(points))
    if hi == lo:
        hi = lo + 1
    start = rows[0]["start_s"]
    end = rows[-1]["end_s"]
    x = lambda v: 70 + 850 * (v - start) / (end - start)
    y = lambda v: 165 - 130 * (v - lo) / (hi - lo)
    colors = ["#222222", "#888888"]
    parts = [
        f"<figure><figcaption>{esc(title)} ({esc(unit)})</figcaption>",
        f'<svg viewBox="0 0 960 205" role="img" aria-label="{esc(title)}">',
        '<path d="M70 35V165H920" fill="none" stroke="#bbb"/>',
        f'<path d="M70 {y(0):.3f}H920" stroke="#ddd"/>',
        f'<text x="4" y="39">{hi:.4g}</text><text x="4" y="169">{lo:.4g}</text>',
        f'<text x="70" y="193">{start:.4g} s</text><text x="855" y="193">{end:.4g} s</text>',
    ]
    for index, key in enumerate(keys):
        path = []
        connected = False
        for row in rows:
            value = row[key]
            if value is None:
                connected = False
                continue
            path.append(
                f"{'L' if connected else 'M'}{x(row['start_s']):.3f} {y(value):.3f}L{x(row['end_s']):.3f} {y(value):.3f}"
            )
            connected = True
        parts.append(
            f'<path d="{" ".join(path)}" fill="none" stroke="{colors[index % 2]}" stroke-width="1.4"'
            + (' stroke-dasharray="5 3"' if index else "")
            + "/>"
        )
    parts.append(
        '</svg><p class="legend">'
        + esc(" / ".join(keys))
        + "; bin means shown as steps. Gaps remain gaps.</p></figure>"
    )
    return "".join(parts)


def html_report(report, text):
    esc = lambda s: html.escape(str(s), quote=True)
    parts = [
        '<!doctype html><html lang="en"><meta charset="utf-8"><title>Engine comparison evidence</title>',
        "<style>body{font:15px system-ui;max-width:1120px;margin:36px auto;padding:0 24px;color:#222}pre{white-space:pre-wrap;line-height:1.5}table{border-collapse:collapse;width:100%;margin:12px 0}th,td{padding:8px;border-bottom:1px solid #ddd;text-align:left}svg{width:100%;font:12px system-ui}figure{margin:16px 0}.legend,small{color:#555}details{margin:16px 0}code{overflow-wrap:anywhere}a{color:inherit}</style>",
        "<h1>Engine comparison evidence</h1>",
        f"<p><strong>{esc(report['case_id'])}</strong> · Availability: {esc(report['analysis_status'])}</p>",
        "<p>The agent assesses modeling adequacy and causes. This report describes observations, differences and evidence limitations.</p>",
        f"<p>Data: {esc(report['data_kind'])}</p>",
        '<p><a href="summary.json">Statistics and provenance</a> · <a href="findings.json">All difference intervals and concurrent signals</a> · <a href="window_errors.csv">All aligned bins</a></p>',
    ]
    if report["contract_issues"]:
        parts.append(
            "<h2>Comparability issues</h2><ul>"
            + "".join("<li>" + esc(x) + "</li>" for x in report["contract_issues"])
            + "</ul>"
        )
    if report["acceptance_check"]["requested"]:
        parts.append(
            "<p>Explicit optional policy check: "
            + esc(report["acceptance_check"]["status"])
            + ". This is separate from agent judgment.</p>"
        )
    for name, metric in report["metrics"].items():
        parts.extend(
            [
                f"<h2>{esc(name)}</h2><p>{esc(metric['meaning'])} · {esc(metric['unit'])} · {esc(metric['analysis_status'])}</p>",
                "<table><tr><th>Paired coverage</th><th>MAE</th><th>Signed bias</th><th>p95 absolute error</th><th>First difference</th></tr><tr>"
                + "".join(
                    "<td>" + esc(metric.get(key)) + "</td>"
                    for key in [
                        "coverage_fraction",
                        "mae",
                        "signed_bias",
                        "absolute_error_p95",
                        "first_difference_s",
                    ]
                )
                + "</tr></table>",
            ]
        )
        for reason in metric.get("reasons", []):
            parts.append("<p>" + esc(reason) + "</p>")
        rows = [w for w in report["windows"] if w["metric"] == name]
        if rows:
            parts.append(
                step_plot(
                    rows,
                    ["reference", "candidate"],
                    "Reference (solid) and candidate (dashed)",
                    metric["unit"],
                )
            )
            parts.append(
                step_plot(
                    rows, ["signed_error"], "Candidate minus reference", metric["unit"]
                )
            )
        findings = [f for f in report["findings"] if f["metric"] == name]
        if findings:
            parts.append(
                "<h3>Largest observed difference intervals</h3><p>Ranked by error area within this metric; not by acceptance or inferred cause. Up to 20 intervals shown; every interval is in findings.json.</p>"
            )
        for finding in findings[:20]:
            parts.append(
                f"<details><summary>{esc(finding['id'])}: [{finding['start_s']:.6g}, {finding['end_s']:.6g}) s · {esc(finding['direction'])} · mean difference {finding['mean_signed_error']:.6g}</summary>"
            )
            parts.append(
                "<p>Source rows: "
                + esc(finding["evidence"])
                + "</p><table><tr><th>Concurrent signal</th><th>Reference mean</th><th>Candidate mean</th><th>Paired coverage</th></tr>"
            )
            for signal, context in finding["concurrent_signals"].items():
                parts.append(
                    "<tr>"
                    + "".join(
                        "<td>" + esc(value) + "</td>"
                        for value in [
                            signal + " (" + context["unit"] + ")",
                            context["reference_mean"],
                            context["candidate_mean"],
                            context["paired_coverage_fraction"],
                        ]
                    )
                    + "</tr>"
                )
            parts.append("</table><p>Causal status: not established.</p></details>")
        parts.append(
            "<details><summary>Coverage, source semantics and statistics</summary><pre>"
            + esc(json.dumps(metric, indent=2))
            + "</pre></details>"
        )
    parts.append(
        "<details><summary>Full text evidence summary and interpretation limits</summary><pre>"
        + esc(text)
        + "</pre></details></html>"
    )
    return "".join(parts)

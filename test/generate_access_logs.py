#!/usr/bin/env python3
"""Generate synthetic, historical nginx access log entries in vhost_combined format."""

import argparse
import gzip
import os
from random import randint, choice, uniform
from datetime import datetime, timedelta, timezone

SERVER_NAMES = [
    "localhost",
    "www.myserver.com",
    "blog.myserver.com",
    "server2.com"
]

USER_AGENTS = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/121.0",
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Mobile/15E148 Safari/604.1",
    "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
    "Mozilla/5.0 (compatible; Bingbot/2.0; +http://www.bing.com/bingbot.htm)",
    "curl/8.4.0",
    "python-requests/2.31.0",
]

REQUESTS = [
    ("GET",  "/",                      200, 80),
    ("GET",  "/index.html",            200, 20),
    ("GET",  "/about",                 200, 30),
    ("GET",  "/contact",               200, 20),
    ("GET",  "/api/v1/users",          200, 40),
    ("GET",  "/api/v1/products",       200, 40),
    ("POST", "/api/v1/login",          200, 30),
    ("POST", "/api/v1/login",          401, 10),
    ("GET",  "/static/css/main.css",   200, 50),
    ("GET",  "/static/js/app.js",      200, 50),
    ("GET",  "/favicon.ico",           200, 60),
    ("GET",  "/robots.txt",            200, 10),
    ("GET",  "/missing-page",          404, 15),
    ("GET",  "/admin",                 403, 5),
    ("GET",  "/.env",                  404, 3),
    ("GET",  "/api/v1/error",          500, 2),
]

BODY_SIZES = {
    200: (800,  80000),
    304: (0,    0),
    301: (160,  160),
    302: (160,  160),
    401: (150,  300),
    403: (150,  300),
    404: (150,  500),
    500: (200,  500),
}

REQUEST_POOL = [(f"{m} {p} HTTP/1.1", s) for m, p, s, w in REQUESTS for _ in range(w)]


def random_ip():
    return f"{randint(1, 254)}.{randint(0, 255)}.{randint(0, 255)}.{randint(1, 254)}"


def body_size(status):
    lo, hi = BODY_SIZES.get(status, (800, 80000))
    return randint(lo, hi) if lo != hi else lo


def format_time(dt):
    return dt.strftime("%d/%b/%Y:%H:%M:%S +0000")


def generate_line(dt):
    server = choice(SERVER_NAMES)
    request, status = choice(REQUEST_POOL)
    ua = choice(USER_AGENTS)
    return (
        f'{server} {random_ip()} - - [{format_time(dt)}] '
        f'"{request}" {status} {body_size(status)} "-" "{ua}"'
    )


def write_lines(path, lines, gz=False):
    opener = gzip.open(path, "wt") if gz else open(path, "w")
    with opener as f:
        f.write("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("n", type=int, nargs="?", default=10000,
                        help="Number of log lines to generate (default: 10000)")
    parser.add_argument("--days", type=float, default=45,
                        help="Spread entries over this many past days (default: 45)")
    parser.add_argument("--rotations", type=int, default=3,
                        help="Number of rotated files to produce (default: 3)")
    args = parser.parse_args()

    now = datetime.now(timezone.utc)
    span_seconds = args.days * 86400
    times = sorted(
        now - timedelta(seconds=uniform(0, span_seconds))
        for _ in range(args.n)
    )
    lines = [generate_line(t) for t in times]

    os.makedirs("seed", exist_ok=True)

    num_groups = args.rotations + 1
    size = len(lines) // num_groups
    groups = [lines[i * size:(i + 1) * size] for i in range(num_groups - 1)]
    groups.append(lines[(num_groups - 1) * size:])  # last group gets any remainder

    # groups[0] is oldest; groups[-1] is most recent (current log).
    # Rotated files are numbered from most-recent-rotation outward:
    #   groups[-2] -> access.log.1  (plain text, most recent rotation)
    #   groups[-3] -> access.log.2.gz
    #   groups[-4] -> access.log.3.gz  ...
    write_lines("seed/access.log", groups[-1])
    for i, group in enumerate(reversed(groups[:-1]), start=1):
        if i == 1:
            write_lines("seed/access.log.1", group)
        else:
            write_lines(f"seed/access.log.{i}.gz", group, gz=True)


if __name__ == "__main__":
    main()

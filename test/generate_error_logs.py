#!/usr/bin/env python3
"""Generate synthetic, historical nginx error log entries."""

import argparse
import sys
from random import randint, choice, uniform
from datetime import datetime, timedelta, timezone

SERVER_NAMES = [
    "localhost",
    "www.myserver.com",
    "blog.myserver.com",
    "server2.com"
]

# (level, weight, message_template)
ERROR_TYPES = [
    ("error",  50, 'open() "{root}{path}" failed (2: No such file or directory)'),
    ("error",  10, 'open() "{root}{path}" failed (13: Permission denied)'),
    ("error",  15, 'upstream timed out (110: Connection timed out) while reading response header from upstream'),
    ("error",   8, 'connect() failed (111: Connection refused) while connecting to upstream'),
    ("warn",   30, 'client sent invalid header line while reading client request headers'),
    ("warn",   10, 'upstream server temporarily disabled while reading response header from upstream'),
    ("crit",    3, 'SSL_do_handshake() failed (SSL: error:0A000126) while SSL handshaking'),
    ("notice",  5, 'signal process started'),
    ("info",   10, 'client connected'),
]

PATHS = [
    "/missing-page", "/.env", "/wp-admin/", "/phpMyAdmin/", "/admin/config.php",
    "/api/v1/secret", "/.git/config", "/backup.zip", "/static/missing.css",
    "/uploads/shell.php",
]

DOC_ROOTS = ["/var/www/html", "/usr/share/nginx/html", "/srv/www"]

REQUESTS = [
    "GET {path} HTTP/1.1",
    "POST {path} HTTP/1.1",
    "HEAD {path} HTTP/1.1",
]

ERROR_POOL = [
    (level, msg)
    for level, weight, msg in ERROR_TYPES
    for _ in range(weight)
]


def random_ip():
    return f"{randint(1, 254)}.{randint(0, 255)}.{randint(0, 255)}.{randint(1, 254)}"


def format_time(dt):
    return dt.strftime("%Y/%m/%d %H:%M:%S")


def generate_line(dt):
    server = choice(SERVER_NAMES)
    level, msg_template = choice(ERROR_POOL)
    path = choice(PATHS)
    root = choice(DOC_ROOTS)
    msg = msg_template.format(root=root, path=path)
    pid = randint(1, 30)
    tid = pid
    conn = randint(1, 9999)
    ip = random_ip()
    request = choice(REQUESTS).format(path=path)
    return (
        f'{format_time(dt)} [{level}] {pid}#{tid}: *{conn} {msg}, '
        f'client: {ip}, server: {server}, request: "{request}", host: "{server}"'
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("n", type=int, nargs="?", default=2000,
                        help="Number of log lines to generate (default: 2000)")
    parser.add_argument("--days", type=float, default=45,
                        help="Spread entries over this many past days (default: 45)")
    parser.add_argument("-o", type=str, default="initial_error.log",
                        help="Specify the output file or '-' for stdout (default: initial_error.log)")
    args = parser.parse_args()

    now = datetime.now(timezone.utc)
    span_seconds = args.days * 86400
    times = sorted(
        now - timedelta(seconds=uniform(0, span_seconds))
        for _ in range(args.n)
    )
    out = sys.stdout if args.o == '-' else open(args.o, 'w')
    try:
        for t in times:
            print(generate_line(t), file=out)
    finally:
        if out is not sys.stdout:
            out.close()


if __name__ == "__main__":
    main()

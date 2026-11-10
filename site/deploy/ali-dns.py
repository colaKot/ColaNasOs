#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给 gexuan.net 加/查一条子域 A 记录（阿里云 DNS，RPC 签名版）。
凭据从 acme.sh 的 account.conf 读，不落盘、不回显。
用法：python3 ali-dns.py cola 106.54.217.61
"""
import base64
import hashlib
import hmac
import json
import os
import re
import sys
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone

ACCOUNT = os.path.expanduser("~/.acme.sh/account.conf")
ENDPOINT = "https://alidns.aliyuncs.com/"
DOMAIN = "gexuan.net"


def read_creds():
    txt = open(ACCOUNT, encoding="utf-8", errors="ignore").read()
    out = {}
    for key in ("Ali_Key", "Ali_Secret"):
        m = re.search(r"^(?:SAVED_)?%s\s*=\s*'?([^'\n\r]+)'?" % key, txt, re.M)
        if not m:
            raise SystemExit("account.conf 里没找到 %s" % key)
        out[key] = m.group(1).strip()
    return out["Ali_Key"], out["Ali_Secret"]


def pe(v):
    s = urllib.parse.quote(str(v), safe="")
    return s.replace("+", "%20").replace("*", "%2A").replace("%7E", "~")


def call(ak, sk, action, extra=None):
    params = {
        "Action": action,
        "Version": "2015-01-09",
        "Format": "JSON",
        "AccessKeyId": ak,
        "SignatureMethod": "HMAC-SHA1",
        "SignatureVersion": "1.0",
        "SignatureNonce": str(uuid.uuid4()),
        "Timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    if extra:
        params.update(extra)
    canonical = "&".join("%s=%s" % (pe(k), pe(v)) for k, v in sorted(params.items()))
    to_sign = "GET&%%2F&%s" % pe(canonical)
    sig = base64.b64encode(
        hmac.new((sk + "&").encode(), to_sign.encode(), hashlib.sha1).digest()
    ).decode()
    url = "%s?Signature=%s&%s" % (ENDPOINT, pe(sig), canonical)
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode())


def main():
    rr = sys.argv[1] if len(sys.argv) > 1 else "cola"
    ip = sys.argv[2] if len(sys.argv) > 2 else "106.54.217.61"
    ak, sk = read_creds()

    exist = call(ak, sk, "DescribeDomainRecords", {
        "DomainName": DOMAIN, "RRKeyWord": rr, "SearchMode": "EXACT",
    })
    recs = [r for r in exist.get("DomainRecords", {}).get("Record", [])
            if r.get("RR") == rr]
    if recs:
        for r in recs:
            print("已存在: %s.%s %s -> %s (TTL %s, id %s)" % (
                r["RR"], DOMAIN, r["Type"], r["Value"], r.get("TTL"), r.get("RecordId")))
        return

    res = call(ak, sk, "AddDomainRecord", {
        "DomainName": DOMAIN, "RR": rr, "Type": "A", "Value": ip, "TTL": "600",
    })
    print("已添加: %s.%s A -> %s, RecordId=%s" % (rr, DOMAIN, ip, res.get("RecordId")))


if __name__ == "__main__":
    main()

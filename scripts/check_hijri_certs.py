#!/usr/bin/env python3
"""Keeps the Hijri date sync's extra certificates current, by itself (run daily by the models
repo's GitHub workflow .github/workflows/hijri-certs.yml, or by hand).

Some official sources send an incomplete certificate chain (www.alriyadh.com leaves out its
intermediate), and older phones lack newer roots (Android 9 has no Sectigo Root R46). The app's
own HTTP client fetches nothing, so it adds certificates for the sync's requests only: a built-in
copy (lib/prayer/hijri_certs.dart) and the `hijri_certs` field of prayer-data.json, which phones
fetch from the models repo once a day (lib/prayer/prayer_updates.dart).

For each source host this script:
  1. takes the server's own certificate (the leaf) and the chain it sends;
  2. fetches what is missing from the address the certificates name (Authority Information
     Access, caIssuers), as browsers do;
  3. VERIFIES the whole chain (signatures, validity dates, the host name, key usage) against
     Mozilla's root store (certifi) with cryptography's X.509 path validation: a certificate that
     does not chain to a public root is never written;
  4. keeps the verified intermediates and the root.
The union for all hosts becomes `hijri_certs` (PEM). The file is rewritten only when that set
changed; the exit code is 0 (no change), 10 (changed: commit it) or 1 (a host could not be
verified: nothing about that host is changed, the rest is still written).

    pip install cryptography certifi
    python tool/hijri_sync/check_certs.py --prayer-data ../quran-companion-models/prayer-data.json

The host list is the sync's sources (lib/prayer/hijri_sync.dart `url:`); test/hijri_sync_test.dart
checks the two stay alike.
"""

import argparse
import json
import re
import socket
import ssl
import sys
import urllib.request
from pathlib import Path

import certifi
from cryptography import x509
from cryptography.hazmat.primitives.serialization import Encoding, pkcs7
from cryptography.x509.oid import AuthorityInformationAccessOID, ExtensionOID
from cryptography.x509.verification import PolicyBuilder, Store

HOSTS = [
    'www.uqn.gov.sa',
    'www.alriyadh.com',
    'www.darifta.ps',
    'www.aliftaa.jo',
    'www.dar-alifta.org',
    'www.habous.gov.ma',
    'namazvakitleri.diyanet.gov.tr',
    'www.e-solat.gov.my',
]

MAX_FETCH = 4  # intermediates fetched along one chain at most


def server_chain(host):
    """The leaf and the certificates the server sends (unverified, to build the path)."""
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    with socket.create_connection((host, 443), timeout=15) as sock:
        with ctx.wrap_socket(sock, server_hostname=host) as tls:
            try:
                ders = tls.get_unverified_chain()  # Python 3.13+
                certs = [x509.load_der_x509_certificate(bytes(d)) for d in ders]
            except AttributeError:
                certs = [x509.load_der_x509_certificate(tls.getpeercert(binary_form=True))]
    return certs[0], certs[1:]


def aia_issuer_urls(cert):
    try:
        aia = cert.extensions.get_extension_for_oid(ExtensionOID.AUTHORITY_INFORMATION_ACCESS).value
    except x509.ExtensionNotFound:
        return []
    return [d.access_location.value for d in aia
            if d.access_method == AuthorityInformationAccessOID.CA_ISSUERS]


def fetch_certs(url):
    data = urllib.request.urlopen(url, timeout=15).read()
    for load in (lambda b: [x509.load_der_x509_certificate(b)],
                 lambda b: [x509.load_pem_x509_certificate(b)],
                 pkcs7.load_der_pkcs7_certificates,
                 pkcs7.load_pem_pkcs7_certificates):
        try:
            return load(data)
        except Exception:
            continue
    return []


def roots():
    pem = Path(certifi.where()).read_bytes()
    return x509.load_pem_x509_certificates(pem)


def verified_chain(host, store):
    """The verified path leaf → … → root for [host] (the leaf left out), or raise."""
    leaf, sent = server_chain(host)
    pool = list(sent)
    verifier = PolicyBuilder().store(store).build_server_verifier(x509.DNSName(host))
    last_error = None
    for _ in range(MAX_FETCH + 1):
        try:
            chain = verifier.verify(leaf, pool)
            return chain[1:]
        except Exception as e:  # missing issuer: fetch it from the AIA address
            last_error = e
        tip = pool[-1] if pool else leaf
        urls = aia_issuer_urls(tip)
        got = [c for u in urls for c in fetch_certs(u)]
        new = [c for c in got if c not in pool and c != leaf]
        if not new:
            break
        pool.extend(new)
    raise RuntimeError(f'{host}: no verified chain ({last_error})')


def pem_of(certs):
    seen, out = set(), []
    for c in certs:
        fp = c.fingerprint(c.signature_hash_algorithm).hex() if c.signature_hash_algorithm else id(c)
        if fp in seen:
            continue
        seen.add(fp)
        out.append(c.public_bytes(Encoding.PEM).decode('ascii').strip())
    return '\n'.join(out) + '\n'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--prayer-data', type=Path, required=True)
    args = ap.parse_args()
    store = Store(roots())
    data = json.loads(args.prayer_data.read_text(encoding='utf-8'))
    old = data.get('hijri_certs') or ''
    keep, failed = [], []
    for host in HOSTS:
        try:
            chain = verified_chain(host, store)
            names = ' → '.join(c.subject.rfc4514_string() for c in chain)
            print(f'ok  {host}: {names}')
            keep.extend(chain)
        except Exception as e:
            print(f'ERR {host}: {e}', file=sys.stderr)
            failed.append(host)
    if failed and old:
        # A host that could not be checked now keeps the certificates it had.
        for c in x509.load_pem_x509_certificates(old.encode('ascii')):
            keep.append(c)
    new = pem_of(sorted(keep, key=lambda c: c.subject.rfc4514_string()))
    if new == old:
        print('hijri_certs unchanged')
        return 1 if failed else 0
    # Only this field's text changes; the rest of the file keeps its own layout.
    text = args.prayer_data.read_text(encoding='utf-8')
    line = f' "hijri_certs": {json.dumps(new)}'
    if 'hijri_certs' in data:
        text = re.sub(r'(?m)^ "hijri_certs": ".*?"(,?)$', lambda m: line + m.group(1), text, count=1)
    else:
        text = text.replace('{\n', '{\n' + line + ',\n', 1)
    json.loads(text)  # still valid JSON
    args.prayer_data.write_bytes(text.encode('utf-8'))
    print(f'hijri_certs updated: {new.count("BEGIN CERTIFICATE")} certificates')
    return 10


if __name__ == '__main__':
    sys.exit(main())

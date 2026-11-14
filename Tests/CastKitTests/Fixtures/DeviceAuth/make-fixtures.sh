#!/bin/sh
# Generates the fake Cast PKI the device-authentication tests run against:
# a test root and intermediate standing in for Google's, device certificates
# with and without the properties Chromium requires, TLS certificates, and a
# CRL signer. Every key here is a throwaway made for these tests; no real
# device's certificate is, or may be, committed.
#
# The tests verify at a fixed time, 2026-06-01 12:00 UTC, so the files never
# go stale. Needs OpenSSL 3.4 or later (-not_before / -not_after).
#
#   cd Tests/CastKitTests/Fixtures/DeviceAuth && ./make-fixtures.sh
set -eu

cd "$(dirname "$0")"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

O="/C=US/O=CastKit Tests/OU=Cast"

key() { # name bits
  openssl genrsa -out "$WORK/$1.key" "${2:-2048}" 2>/dev/null
}

ext() { # name, then the extension lines
  name=$1; shift
  printf '%s\n' "[x]" "$@" > "$WORK/$name.ext"
}

# cert <out> <key> <subject CN> <issuer cert|self> <issuer key> <ext> <from> <to> <serial> [sigopts...]
cert() {
  out=$1 k=$2 cn=$3 issuer=$4 ikey=$5 e=$6 from=$7 to=$8 serial=$9
  shift 9
  openssl req -new -key "$WORK/$k.key" -subj "$O/CN=$cn" -out "$WORK/$out.csr"
  if [ "$issuer" = self ]; then
    signer="-key $WORK/$ikey.key"
  else
    signer="-CA $WORK/$issuer.pem -CAkey $WORK/$ikey.key"
  fi
  # shellcheck disable=SC2086
  openssl x509 -req -in "$WORK/$out.csr" $signer -set_serial "$serial" \
    -not_before "$from" -not_after "$to" \
    -extfile "$WORK/$e.ext" -extensions x "$@" -out "$WORK/$out.pem" 2>/dev/null
  openssl x509 -in "$WORK/$out.pem" -outform DER -out "$out.der"
}

pss="-sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:digest"

ext root "basicConstraints=critical,CA:TRUE,pathlen:2" "keyUsage=critical,keyCertSign,cRLSign" \
  "subjectKeyIdentifier=hash"
ext ica "basicConstraints=critical,CA:TRUE,pathlen:0" "keyUsage=critical,keyCertSign,cRLSign" \
  "subjectKeyIdentifier=hash" "authorityKeyIdentifier=keyid"
ext ica-audio "basicConstraints=critical,CA:TRUE,pathlen:0" "keyUsage=critical,keyCertSign,cRLSign" \
  "subjectKeyIdentifier=hash" "authorityKeyIdentifier=keyid" "certificatePolicies=1.3.6.1.4.1.11129.2.5.2"
ext device "basicConstraints=critical,CA:FALSE" "keyUsage=critical,digitalSignature" \
  "authorityKeyIdentifier=keyid"
ext device-clientauth "basicConstraints=critical,CA:FALSE" "keyUsage=critical,digitalSignature" \
  "extendedKeyUsage=clientAuth" "authorityKeyIdentifier=keyid"
ext device-serverauth "basicConstraints=critical,CA:FALSE" "keyUsage=critical,digitalSignature" \
  "extendedKeyUsage=serverAuth" "authorityKeyIdentifier=keyid"
ext device-nodigsig "basicConstraints=critical,CA:FALSE" "keyUsage=critical,keyEncipherment" \
  "authorityKeyIdentifier=keyid"
ext tls "basicConstraints=critical,CA:FALSE"
ext crl-signer "basicConstraints=critical,CA:FALSE" "keyUsage=critical,digitalSignature" \
  "authorityKeyIdentifier=keyid"

key root; key ica; key device; key device-1024 1024; key tls; key tls-other
key other-root; key other-ica; key crl-root; key crl-signer

# The trusted test root and its intermediate, as Cast Root CA and a Cast ICA.
cert root root "CastKit Test Root CA" self root root 20150101000000Z 20450101000000Z 1
cert ica ica "CastKit Test ICA" root root ica 20150101000000Z 20400101000000Z 2

# Device certificates (the device key signs the challenge).
cert device device "CastKit Test Device" ica ica device 20160101000000Z 20360101000000Z 100
cert device-clientauth device "CastKit Test Device" ica ica device-clientauth 20160101000000Z 20360101000000Z 101
cert device-serverauth device "CastKit Test Device" ica ica device-serverauth 20160101000000Z 20360101000000Z 102
cert device-nodigsig device "CastKit Test Device" ica ica device-nodigsig 20160101000000Z 20360101000000Z 103
cert device-1024 device-1024 "CastKit Test Device" ica ica device 20160101000000Z 20360101000000Z 104
# Expired after one year: no grace.
cert device-expired device "CastKit Test Device" ica ica device 20200101000000Z 20210101000000Z 105
# A ten-year certificate that expired five months before the test time:
# Chromium's long-term grace (b/416790717) still accepts it.
cert device-longterm-expired device "CastKit Test Device" ica ica device 20150601000000Z 20260101000000Z 106

# The same chain signed with SHA-1, as older Cast devices have it.
cert ica-sha1 ica "CastKit Test ICA" root root ica 20150101000000Z 20400101000000Z 3 -sha1
cert device-sha1 device "CastKit Test Device" ica-sha1 ica device 20160101000000Z 20360101000000Z 107 -sha1

# The same chain signed with RSASSA-PSS (SHA-256), which Chromium's path builder accepts.
# shellcheck disable=SC2086
cert ica-pss ica "CastKit Test ICA" root root ica 20150101000000Z 20400101000000Z 4 -sha256 $pss
# shellcheck disable=SC2086
cert device-pss device "CastKit Test Device" ica-pss ica device 20160101000000Z 20360101000000Z 108 -sha256 $pss

# An intermediate restricted to audio-only devices (Cast policy 1.3.6.1.4.1.11129.2.5.2).
cert ica-audio ica "CastKit Test Audio ICA" root root ica-audio 20150101000000Z 20400101000000Z 5
cert device-audio device "CastKit Test Device" ica-audio ica device 20160101000000Z 20360101000000Z 109

# A chain to a root nobody trusts, with the real device key.
cert other-root other-root "Untrusted Root CA" self other-root root 20150101000000Z 20450101000000Z 1
cert other-ica other-ica "Untrusted ICA" other-root other-root ica 20150101000000Z 20400101000000Z 2
cert other-device device "CastKit Test Device" other-ica other-ica device 20160101000000Z 20360101000000Z 110

# The receiver's self-signed TLS certificates: two days, as Cast devices make
# them, around the test time; another one; one that runs ten days.
cert tls tls "CastKit Test TLS" self tls tls 20260531120000Z 20260602120000Z 1
cert tls-other tls-other "CastKit Test TLS" self tls-other tls 20260531120000Z 20260602120000Z 2
cert tls-long tls "CastKit Test TLS" self tls tls 20260531120000Z 20260610120000Z 3

# The CRL root and the signer of CRL bundles.
cert crl-root crl-root "CastKit Test CRL Root CA" self crl-root root 20150101000000Z 20450101000000Z 1
cert crl-signer crl-signer "CastKit Test CRL Signer" crl-root crl-root crl-signer 20160101000000Z 20360101000000Z 2

# Private keys the tests sign with, as PKCS#1 DER (what SecKeyCreateWithData takes).
for k in device device-1024 crl-signer; do
  openssl rsa -in "$WORK/$k.key" -traditional -outform DER -out "$k.key.der" 2>/dev/null
done

echo "fixtures written to $(pwd)"

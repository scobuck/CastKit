import Foundation

/// Google's Cast trust anchors, taken byte for byte from Chromium
/// (chromium/src main, 2026-11-14), directory
/// components/media_router/common/providers/cast/certificate/.
///
/// The SHA-256 fingerprints were checked against two copies that don't come
/// from Chromium's source: the certificates Google's Android Chromecast app
/// ships (assets/certs/cast_root_ca.crt, chromecast_ca.crt) and the ones in
/// Google Play Services' Cast code. Open Screen's copies are byte-identical.
/// CastDeviceAuthTests pins the fingerprints, so an edit here fails the tests.
enum CastTrustRoots {
  /// CN=Cast Root CA, OU=Cast, O=Google Inc. Valid 2014-04-02 to 2034-03-28.
  /// From cast_root_ca_cert_der-inc.h (kCastRootCaDer).
  /// SHA-256 80:9A:F1:47:00:B3:FE:26:11:AD:59:7E:B1:58:4D:63:54:31:3B:64:CC:DB:33:90:F0:97:FA:3E:58:26:D6:CA
  static let castRootCA = Data(base64Encoded: """
    MIIDxTCCAq2gAwIBAgIBAjANBgkqhkiG9w0BAQUFADB1MQswCQYDVQQGEwJVUzETMBEGA1UECAwK
    Q2FsaWZvcm5pYTEWMBQGA1UEBwwNTW91bnRhaW4gVmlldzETMBEGA1UECgwKR29vZ2xlIEluYzEN
    MAsGA1UECwwEQ2FzdDEVMBMGA1UEAwwMQ2FzdCBSb290IENBMB4XDTE0MDQwMjE3MzQyNloXDTM0
    MDMyODE3MzQyNlowdTELMAkGA1UEBhMCVVMxEzARBgNVBAgMCkNhbGlmb3JuaWExFjAUBgNVBAcM
    DU1vdW50YWluIFZpZXcxEzARBgNVBAoMCkdvb2dsZSBJbmMxDTALBgNVBAsMBENhc3QxFTATBgNV
    BAMMDENhc3QgUm9vdCBDQTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALrZZZ3aOdPB
    d/bU0K6PWAhoOUqV7XDP/XkIqarl6binLaBnR4qeyc9wswWHaRHscJiXw+bDw+u9xrA9/E/BXjif
    2s9zMAZbeTfBXoyHR5SaQZIq1pXEcVwnXQixgMaSvRvjQZeh7HWfVZ4+n48cx2VkB9OzlqEEn5HE
    3gp7bNnIwHgxoBlCqeiD48788c7CLiRGlQkZysBGsuUButdP87/2aa2ZBPqgBzkO5t9RRwfA5Klc
    S5TFL7OgMH/nlWuyrzIN8YzVbct7R6cIq8sno03PSlrxBdH4YsUQKnRpquZLlvub2GPkWGbTrYpu
    /3te+aVWHi2CMVvw4iTmQUofrhMCAwEAAaNgMF4wDwYDVR0TBAgwBgEB/wIBAjAdBgNVHQ4EFgQU
    fJoefd95VLzXzF7KmYZFeWV0KBkwHwYDVR0jBBgwFoAUfJoefd95VLzXzF7KmYZFeWV0KBkwCwYD
    VR0PBAQDAgEGMA0GCSqGSIb3DQEBBQUAA4IBAQCA9Fr7PSgZUSDX1PsSl0pl8lg1kncwavHXtlEa
    f5rNx3sDQq1VagCv8OEGwr1reHXb/kERU0o5u5o6xlk0Lywz47LWXH/deOtxWznag5DFMeI/I+/a
    6ystd17ew0PSyWtZgsrV7fqhZFvL8Q0aYuGc6KcYcPBfF5b47Ybbrh3gzz5dLu4WbZUrPP2X8wVa
    JGhNObb45Fi69eAmeFHFW11OCeVsR4t6Wi6JU+bMNlsmPPhyQwKC0ivN8NOj7BM+UtWDPQfcHUNl
    ejMCAaPOt9ZgUTsJwiOKMv6YGWBik4XNNEbb1SMPedp3ACoCbYNYzgN3NeGjIJPCSqKkRhx1LB9N
    """, options: .ignoreUnknownCharacters)!

  /// CN=Eureka Root CA, OU=Google TV, O=Google Inc. Valid 2012-12-17 to 2032-12-12.
  /// From eureka_root_ca_der-inc.h (kEurekaRootCaDer).
  /// SHA-256 CA:F6:D1:E3:7B:53:22:03:E0:1A:76:BF:07:18:7B:B7:31:CC:D3:88:01:56:5A:B2:21:1A:2C:0A:B7:F3:BC:46
  static let eurekaRootCA = Data(base64Encoded: """
    MIIDwzCCAqugAwIBAgIBATANBgkqhkiG9w0BAQUFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECAwK
    Q2FsaWZvcm5pYTEWMBQGA1UEBwwNTW91bnRhaW4gVmlldzETMBEGA1UECgwKR29vZ2xlIEluYzES
    MBAGA1UECwwJR29vZ2xlIFRWMRcwFQYDVQQDDA5FdXJla2EgUm9vdCBDQTAeFw0xMjEyMTcyMjM5
    MzNaFw0zMjEyMTIyMjM5MzNaMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIDApDYWxpZm9ybmlhMRYw
    FAYDVQQHDA1Nb3VudGFpbiBWaWV3MRMwEQYDVQQKDApHb29nbGUgSW5jMRIwEAYDVQQLDAlHb29n
    bGUgVFYxFzAVBgNVBAMMDkV1cmVrYSBSb290IENBMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIB
    CgKCAQEAuRHQ6hLcMuHfXDNrGXMdnZ7QOXa/pYQJpv1ubencjzZO6YgCvZ/06ET9TPWaAlZqRypj
    bFhFzHxmJNx5ecMqpLKLoPeitc0Gftu+7AyG8g0kYHSEyikjhALYp+078ewmR1TjsS3mZA/2csXp
    mFIXwPzyLCDIQPhHyTKeO5exi/WYJHBjZhnBUugEBT1fjbzYS693mG8feNG2UCdN5OwUaWcfWK+p
    oBEmPJQyB3/X6Wkfrj9PY4qPidbyGXhcIY6xtlfYwOHufW7d8ToKavG6//mDL9y1pCAXYzbvyGIZ
    zFbOsuoxiUt4WMG/AxOZ4BLyiKqblNrddnkXHjTRCsQHRQIDAQABo1AwTjAdBgNVHQ4EFgQURE4q
    R1jYuUiR9k/OdKkdMpqNjekwHwYDVR0jBBgwFoAURE4qR1jYuUiR9k/OdKkdMpqNjekwDAYDVR0T
    BAUwAwEB/zANBgkqhkiG9w0BAQUFAAOCAQEAP8gmoG5cBUB5oZipM95odIXurrccM1mwEd6f9E/T
    61EJfUd+blGF9FTNg5glsbqwV+yT2xLi7FFJepZzm8iWbYWM0+E8+jLiWAx3bYcMNAGqMKl24MDn
    214b6RAwpOAJSSa5WM1aB+VQdd6aO/ZTfrFTXkUnTxfjCDOyUAq79PwllyneQXUw+nc4qmWKc0/q
    EXvrfBdgJw68PnZS2IvtGvjrN7sR/a5wFwr+4K0Gsx9pinIEwsAzC9YvY0wzERS4YjaIxQNlARmj
    7wC7bw6S/zQcodYx0Fxen5l9x8q9fHIL9Fylfm4EqNKZLFEBFP6iSPB+voQNtNPi8w593ov1Mw==
    """, options: .ignoreUnknownCharacters)!

  /// CN=Cast CRL Root CA, OU=Cast, O=Google Inc. Valid 2016-08-01 to 2036-07-27.
  /// The root of the certificates that sign Cast CRLs.
  /// From cast_crl_root_ca_cert_der-inc.h (kCastCRLRootCaDer).
  /// SHA-256 8B:77:C6:02:91:F9:D6:27:64:61:30:83:F4:97:50:B1:C5:CA:AC:2D:9E:FB:E5:A2:8E:DF:30:1F:9D:84:83:1D
  static let castCRLRootCA = Data(base64Encoded: """
    MIIDzjCCAragAwIBAgICAJkwDQYJKoZIhvcNAQELBQAweTELMAkGA1UEBhMCVVMxEzARBgNVBAgM
    CkNhbGlmb3JuaWExFjAUBgNVBAcMDU1vdW50YWluIFZpZXcxEzARBgNVBAoMCkdvb2dsZSBJbmMx
    DTALBgNVBAsMBENhc3QxGTAXBgNVBAMMEENhc3QgQ1JMIFJvb3QgQ0EwHhcNMTYwODAxMjE0NzQ3
    WhcNMzYwNzI3MjE0NzQ3WjB5MQswCQYDVQQGEwJVUzETMBEGA1UECAwKQ2FsaWZvcm5pYTEWMBQG
    A1UEBwwNTW91bnRhaW4gVmlldzETMBEGA1UECgwKR29vZ2xlIEluYzENMAsGA1UECwwEQ2FzdDEZ
    MBcGA1UEAwwQQ2FzdCBDUkwgUm9vdCBDQTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEB
    AMJ/wAkh02CJKLWWbv6mrf6u4GY1vZlu6JOFKbreRF2oa/zmzDfdHQ/PHjoyLH/gG8m7TDSpHJe1
    +G1CnE0GaqAtlVU/eB1cq+k6pgg7Wq/0q1N3FJprsjcuzW7qvCJdVlVz/b0DL1Ref4vBdDYaGB9k
    3r8IgEoSDElTuMc721/cWXcvuDoFiva3RyqbdGMIMRLme0TRwXzIh7hQY22f17o2U3JHX9xDQ+vX
    LhHRinqkA/Jq04jmp7idgbKwiCTIofqwqtsIZD6LKgdcWoIFmcLVylJ1Iaf6xaHarPf+0MdEdprr
    a9O99Hoxpq0vWsQxOm3x3XtEgTfPE4Vdlq57lisCAwEAAaNgMF4wDwYDVR0TBAgwBgEB/wIBATAd
    BgNVHQ4EFgQUGmUStKm5tPyRDJ5n4FvZya1EHLkwHwYDVR0jBBgwFoAUGmUStKm5tPyRDJ5n4FvZ
    ya1EHLkwCwYDVR0PBAQDAgIEMA0GCSqGSIb3DQEBCwUAA4IBAQCvX4vA98UmiLms9+xND3ar4nSa
    RDwz9nQ9BCpZdqIFJ8TjosjCr379vrnK6VuoKs2nHg438W+EXqpCH7rwRLrbh2FokbsdXDrwjgIg
    dqpHmcdzDZAySrnj/RGLXb0iTQV1F2Gipk+wPVKOqsm0jQVaHDbBe4f3+OSBNifsNa65zhVH4RDJ
    Fmk6Io5jGDHMO1ZpxtQk3ZUlzzTmAK7hhx7uDBTcDYKBMR+PbdLA4XwS953KAuN2NkRTOodxfe0y
    TKSW5uUsxw23lsDzfeVYMvclJcATdtB2bHOrPRXNxeiFFZoCUulhQeJmAcVx5dvApbNMHqyTijVM
    TdpXIiQdOva9
    """, options: .ignoreUnknownCharacters)!

  /// Chromium's fallback CRL bundle (cast_fallback_crl.h, kCastFallbackCRLs):
  /// the revocations Chromium applies when a device sends no CRL of its own.
  /// SHA-256 25:76:BA:74:90:22:21:BD:1A:23:1A:67:CC:4F:C6:86:2B:D8:5D:43:8E:DE:C2:68:81:FA:1F:5D:FE:5E:25:FC
  static let fallbackCRL = Data(base64Encoded: """
    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
    T3865/FENn74SzbNxhQ6VfypmAFDbFFC
    """, options: .ignoreUnknownCharacters)!

  /// When the fallback CRL's signer chain is checked (cast_fallback_crl.h,
  /// kCastFallbackCRLTimestamp: 2023-08-17 07:00 UTC). The signer certificate
  /// has long expired; Chromium checks it at this time instead of now.
  static let fallbackCRLSignerCheckTime = Date(timeIntervalSince1970: 1_692_255_600)
}

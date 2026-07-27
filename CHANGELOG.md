# Changelog

## 0.3.0

- CORS support, handled in-plugin rather than via the stock `cors` plugin:
  this plugin exits in the access phase, so a short-circuited response is not
  guaranteed to reach another plugin's `header_filter`.
  - `OPTIONS` preflight answered before any auth check, since browsers never
    send credentials on a preflight.
  - New config: `cors_enabled`, `cors_origins`, `cors_methods`,
    `cors_headers`, `cors_expose_headers`, `cors_max_age`.
  - `Location` is exposed by default so a browser can read the 307 target.
- **Routes must list `OPTIONS`** in `methods`, or preflights never reach the
  plugin and the browser sees a 404.

## 0.2.1

- Removed the `do-not-touch-adam-poc` tag from the example and deployment
  configs; `s3-presign` is now the only tag, and the `--select-tag` examples
  in the README and config comments match it.
- No functional change to the plugin.

## 0.2.0

- List response now mirrors the S3 ListObjectsV2 shape field for field
  (`Name`, `Prefix`, `KeyCount`, `MaxKeys`, `IsTruncated`, `Contents[]`),
  rendered as JSON. No delimiter is sent, so listings are flat and
  `CommonPrefixes` / `folders` is gone.
- Continuation token passthrough: `?continuation-token=` and `?max-keys=`
  are forwarded, and `NextContinuationToken` is returned when truncated.
- Download returns **307** with `Location` set to the presigned URL, keeping
  the JSON body. Clients that follow redirects get the object in one round
  trip; clients that want the URL read the body.
- `s3_endpoint` is now validated as `https://` only.
- XML entity decoding on `Key`, `ETag` and `NextContinuationToken` - fixes
  ETag coming back with literal quotes.
- Object metadata changed:
  - `x-amz-meta-uploadedby` now comes from the token's client_id, via the
    header named in `client_id_header`
  - `x-amz-meta-clientipattimeofupload` from `client_ip_header` (X-Real-Ip)
  - `x-amz-meta-client-cert-thumbprint` added, from `cert_thumbprint_header`
  - `x-amz-meta-objectowneremail` removed
  - `x-amz-meta-developerfirstcompany` removed
- New config: `client_id_header`, `client_ip_header`,
  `cert_thumbprint_header`, `max_keys`.
- `Cache-Control: no-store` set by the plugin on all responses.

## 0.1.0

- Initial release.

# kong-plugin-s3-presign

Mints presigned S3 URLs and lists bucket contents natively in Kong. Developed
against a Pure Storage FlashBlade object store; should work with any
S3-compatible endpoint that supports SigV4.

    POST <base_path>          -> presigned upload form (POST policy)
    GET  <base_path>          -> ListObjectsV2 response as JSON
    GET  <base_path>/<key>    -> 307 to a presigned download URL

The plugin terminates in the access phase; no upstream is contacted.

## Responses

**Upload** — `POST /files` with `{"filename":"a.txt","contentType":"text/plain"}`

```json
{
  "key": "files/a.txt",
  "expiresIn": 300,
  "maxBytes": 5000000,
  "upload": { "url": "https://…/bucket", "fields": { "…": "…" } }
}
```

Post the fields plus `file` as multipart. Use `--form-string` for the fields
and `-F` only for the file: curl reads `=@` and `=<` in `-F` as file
references, which breaks on the policy blob.

**List** — `GET /files`, mirroring ListObjectsV2:

```json
{
  "Name": "example-bucket",
  "Prefix": "files/",
  "MaxKeys": 1000,
  "KeyCount": 1,
  "IsTruncated": false,
  "Contents": [
    { "Key": "files/a.txt", "LastModified": "…", "ETag": "…",
      "Size": 58, "StorageClass": "STANDARD" }
  ]
}
```

Flat listing — no delimiter is sent, so there are no `CommonPrefixes`.
`?prefix=`, `?max-keys=` and `?continuation-token=` are accepted;
`NextContinuationToken` comes back when `IsTruncated` is true.

**Download** — `GET /files/a.txt` returns **307** with `Location` set to the
presigned URL and this body:

```json
{
  "key": "files/a.txt",
  "download": { "url": "https://…", "expiresIn": 900 }
}
```

`curl -L` fetches the object in one round trip; omit `-L` to read the URL.

## Config

| Field | Default | Notes |
|---|---|---|
| `s3_endpoint` | - | must be `https://` |
| `bucket` | - | |
| `region` | `ap-southeast-2` | must match what the store expects |
| `base_path` | `/files` | must match the route prefix |
| `base_prefix` | `files/` | folder inside the bucket |
| `access_key` / `secret_key` | - | vault-referenceable |
| `client_id_header` | `X-Authenticated-Client-Id` | → `x-amz-meta-uploadedby` |
| `client_ip_header` | `X-Real-Ip` | → `x-amz-meta-clientipattimeofupload` |
| `cert_thumbprint_header` | `X-Client-Cert-Thumbprint` | → `x-amz-meta-client-cert-thumbprint` |
| `upload_mode` | `post` | `post` = POST policy with size cap; `put` = presigned PUT |
| `upload_ttl` | `300` | seconds |
| `download_ttl` | `900` | seconds |
| `max_bytes` | `5000000` | only enforced in `post` mode |
| `max_keys` | `1000` | per listing page |
| `ssl_verify` | `true` | for the plugin's own call to the store |

The three header settings must name headers **Kong** sets, not ones a client
can supply — strip inbound copies with `request-transformer`, or the
provenance metadata is attacker-controlled.

## Install

    luarocks install kong-plugin-s3-presign

Then on each node — every data plane needs the handler, and the control plane
needs it too since it validates plugin config against the schema:

    # /etc/kong/kong.conf
    plugins = bundled,s3-presign

    # so the client IP stamped into metadata is the client's, not the
    # load balancer's
    trusted_ips = <load balancer addresses>
    real_ip_header = X-Real-Ip
    real_ip_recursive = on

    kong check /etc/kong/kong.conf && kong restart
    curl -s localhost:8001 | jq '.plugins.available_on_server."s3-presign"'

## Configure

Copy `files-service.example.yaml` to `files-service.yaml`, fill in your
endpoints, then:

    deck gateway diff  files-service.yaml --select-tag do-not-touch-adam-poc
    deck gateway apply files-service.yaml

`apply` rather than `sync` — sync reconciles the whole config against one
file and will delete anything not in it.

## Known limits

- One listing page per request. `NextContinuationToken` is returned but the
  plugin does not follow it — clients paginate.
- Object tagging is NotImplemented on FlashBlade, so provenance is carried as
  `x-amz-meta-*`. Metadata cannot be referenced in bucket policy conditions
  and is fixed at write time.
- `upload_mode: post` relies on POST-to-bucket form uploads. Confirmed
  working on FlashBlade including `content-length-range`, but not universal
  across S3-compatible stores — switch to `put` if yours returns
  `NotImplemented`, and add request-size-limiting for the size cap.
- Response-phase plugins may not run on a response short-circuited in the
  access phase. The plugin sets `Cache-Control: no-store` itself for that
  reason; verify anything you add via response-transformer actually lands.
- `encrypted = true` on the key fields needs the Kong EE keyring configured.
  Drop the flag from schema.lua if it is not, and rely on the vault reference.
- The SigV4 implementation is hand-rolled and has no test suite. Keys with
  spaces or non-ASCII characters, and data-plane clock drift, are the likely
  first failure modes.

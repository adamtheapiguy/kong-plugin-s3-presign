# kong-plugin-s3-presign

Mints presigned S3 URLs and lists bucket contents natively in Kong. Developed
against a Pure Storage FlashBlade object store; should work with any
S3-compatible endpoint that supports SigV4.

    POST <base_path>          -> presigned upload (POST policy, or PUT)
    GET  <base_path>          -> list objects under the base prefix, as JSON
    GET  <base_path>/<path>   -> presigned download URL

The plugin terminates in the access phase; no upstream is contacted.

## Layout

    kong/plugins/s3-presign/handler.lua   operation routing and responses
    kong/plugins/s3-presign/schema.lua    config schema
    kong/plugins/s3-presign/sigv4.lua     SigV4 presign / POST policy / signing
    kong-plugin-s3-presign-0.1.0-1.rockspec
    files-service.example.yaml            decK config, sanitised

## Config

| Field | Default | Notes |
|---|---|---|
| `s3_endpoint` | - | scheme + host, no path |
| `bucket` | - | |
| `region` | `ap-southeast-2` | any value works, must match what the array expects |
| `base_path` | `/files` | must match the route prefix |
| `base_prefix` | `files/` | folder inside the bucket |
| `access_key` / `secret_key` | - | vault-referenceable |
| `upload_mode` | `post` | `post` = POST policy with size cap; `put` = presigned PUT |
| `upload_ttl` | `300` | seconds |
| `download_ttl` | `900` | seconds |
| `max_bytes` | `5000000` | only enforced in `post` mode |
| `ssl_verify` | `true` | for the plugin's own call to the array |

`base_path` and `base_prefix` are separate so the API surface and the object
layout can diverge later without a code change.

## Publish to GitHub

Replace `adamtheapiguy` in the rockspec, then from this directory:

    git init -b main
    git add .
    git commit -m "Kong plugin: presigned S3 URLs and bucket listing"

    gh repo create kong-plugin-s3-presign --private --source=. \
      --remote=origin --push

    git tag v0.1.0 && git push origin v0.1.0

Build a self-contained rock and commit it, so target hosts need no toolchain:

    luarocks make --pack-binary-rock kong-plugin-s3-presign-0.1.0-1.rockspec
    mkdir -p rocks && mv kong-plugin-s3-presign-0.1.0-1.all.rock rocks/
    git add -f rocks/ && git commit -m "rock 0.1.0" && git push

`files-service.yaml` is gitignored - keep site-specific endpoints out of the
repo and publish only the `.example.yaml`.

Check for a name collision before you publish - `s3-presign` is an obvious
enough name that someone may already have it on LuaRocks.

## Install from GitHub

Prebuilt rock, no git needed on the host:

    luarocks install https://github.com/adamtheapiguy/kong-plugin-s3-presign/raw/main/rocks/kong-plugin-s3-presign-0.1.0-1.all.rock

Or from the rockspec, which clones the tagged source:

    luarocks install https://raw.githubusercontent.com/adamtheapiguy/kong-plugin-s3-presign/main/kong-plugin-s3-presign-0.1.0-1.rockspec

Neither works against a private repo - raw URLs need a token. Use the offline
path below if the repo stays private, or if the hosts cannot reach github.com.

## Install offline

Copy the zip or a clone to each node. Every data plane needs the handler; the
control plane needs it too, because it validates plugin config against the
schema and will reject the entity otherwise. In hybrid mode that means both.

    cd kong-plugin-s3-presign
    luarocks make kong-plugin-s3-presign-0.1.0-1.rockspec

Add to `kong.conf` on each node:

    plugins = bundled,s3-presign

While you are in there, these are needed for the client IP that gets stamped
into object metadata (the load balancer sets X-Real-IP; without
this Kong replaces it with the balancer's own address):

    trusted_ips = <load balancer addresses>
    real_ip_header = X-Real-IP
    real_ip_recursive = on

Restart, then confirm the plugin loaded:

    kong restart
    curl -s localhost:8001 | jq '.plugins.available_on_server."s3-presign"'

## Configure

Export the secrets the vault references resolve against:

    export S3_ACCESS_KEY=... S3_SECRET_KEY=...
    # plus whatever your auth and logging plugins reference

Then:

    export DECK_KONG_ADDR=https://kong-control-plane:8001
    deck gateway diff files-service.yaml --select-tag s3-presign
    deck gateway sync files-service.yaml --select-tag s3-presign

Copy `files-service.example.yaml` to `files-service.yaml` and fill in your own
endpoints. The unsuffixed name is gitignored so site-specific config stays out
of the repo.

Always pass `--select-tag`. A bare sync reconciles the whole config against
this one file and would delete the existing PoC entities.

## Test

    TOKEN=<access token from your OIDC IdP>
    GW=https://api.myprototype.io

    # list
    curl -k --http1.1 -H "Authorization: Bearer $TOKEN" $GW/files

    # upload - returns url + fields
    curl -k --http1.1 -X POST -H "Authorization: Bearer $TOKEN" \
      -H 'Content-Type: application/json' \
      -d '{"filename":"file.txt","contentType":"text/plain"}' \
      $GW/files

    # download
    curl -k --http1.1 -H "Authorization: Bearer $TOKEN" $GW/files/file.txt

If you front this with a sideband authorization plugin, check whether it
supports HTTP/2 - some are HTTP/1.1 only and need `--http1.1`.

Feed the upload response into curl with `--form-string` for every field and
`-F` only for the file. curl treats `=<` and `=@` in `-F` as file references,
which will bite on any value that starts with one.

## Known limits

- Listing stops at 1000 keys; the response carries `truncated: true` and the
  continuation token is not followed.
- `upload_mode: post` depends on POST-to-bucket form uploads, which are not
  supported by every S3-compatible implementation. If they return NotImplemented, switch to
  `upload_mode: put` and add request-size-limiting to the upload route.
- Object tagging is NotImplemented on FlashBlade, so provenance is carried as
  `x-amz-meta-*`. Metadata cannot be referenced in bucket policy conditions.
- Whether `response-transformer` applies to a `kong.response.exit` response is
  worth verifying - check that `Cache-Control: no-store` actually lands.
- `encrypted = true` on the key fields needs the Kong EE keyring configured.
  Drop the flag from schema.lua if it is not, and rely on the vault reference.
- The SigV4 implementation here is hand-rolled and has no test suite. Keys
  with spaces or non-ASCII characters, and data-plane clock drift, are the
  likely first failure modes.

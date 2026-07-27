local typedefs = require "kong.db.schema.typedefs"

return {
  name = "s3-presign",
  fields = {
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          -- HTTPS only: the plugin's own call to the object store carries the
          -- Authorization header, and presigned URLs are bearer credentials.
          { s3_endpoint = typedefs.url {
              required = true,
              match = "^https://",
              err = "s3_endpoint must be an https:// URL",
          } },

          { bucket = { type = "string", required = true } },
          { region = { type = "string", default = "ap-southeast-2" } },

          -- base_path must match the route prefix; base_prefix is the folder
          -- inside the bucket. Separate so the API surface and the object
          -- layout can diverge later without a code change.
          { base_path   = { type = "string", default = "/files" } },
          { base_prefix = { type = "string", default = "files/" } },

          -- referenceable: accepts {vault://env/...} so the secret never
          -- appears in decK YAML. encrypted: at rest in the DB (Kong EE;
          -- needs the keyring configured, drop the flag if it is not).
          { access_key = { type = "string", required = true,
              referenceable = true, encrypted = true } },
          { secret_key = { type = "string", required = true,
              referenceable = true, encrypted = true } },

          -- Headers the upstream auth plugins set. Values from these are
          -- stamped into object metadata, so they must be headers Kong
          -- controls - strip any client-supplied copies with
          -- request-transformer.
          { client_id_header = { type = "string",
              default = "X-Authenticated-Client-Id" } },
          { client_ip_header = { type = "string",
              default = "X-Real-Ip" } },
          { cert_thumbprint_header = { type = "string",
              default = "X-Client-Cert-Thumbprint" } },

          { upload_ttl   = { type = "integer", default = 300,
              between = { 30, 604800 } } },
          { download_ttl = { type = "integer", default = 900,
              between = { 30, 604800 } } },
          { max_bytes    = { type = "integer", default = 5000000, gt = 0 } },
          { max_keys     = { type = "integer", default = 1000,
              between = { 1, 1000 } } },

          -- "post": presigned POST policy, size cap enforced by S3.
          -- "put":  presigned PUT, for stores without POST-to-bucket support.
          --         No server-side size cap - use request-size-limiting.
          { upload_mode = { type = "string", default = "post",
              one_of = { "post", "put" } } },

          { timeout    = { type = "integer", default = 10000 } },
          { ssl_verify = { type = "boolean", default = true } },

          -- CORS. Handled in-plugin because this plugin exits in the access
          -- phase, so another plugin's header_filter may never run. Preflight
          -- also requires OPTIONS in the route's methods list.
          { cors_enabled = { type = "boolean", default = false } },
          { cors_origins = {
              type = "array",
              elements = { type = "string" },
              default = { "*" },
              description = "Exact origins, or a single \"*\". No wildcards "
                         .. "within an origin.",
          } },
          { cors_methods = {
              type = "array",
              elements = { type = "string" },
              default = { "GET", "POST", "OPTIONS" },
          } },
          { cors_headers = {
              type = "array",
              elements = { type = "string" },
              default = { "Authorization", "Content-Type" },
          } },
          { cors_expose_headers = {
              type = "array",
              elements = { type = "string" },
              -- Location must be exposed or a browser cannot read the 307
              -- target; Content-Disposition for filename hints.
              default = { "Location", "Cache-Control", "Content-Disposition" },
          } },
          { cors_max_age = { type = "integer", default = 3600 } },
        },
      },
    },
  },
}

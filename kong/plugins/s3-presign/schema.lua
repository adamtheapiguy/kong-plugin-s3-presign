local typedefs = require "kong.db.schema.typedefs"

return {
  name = "s3-presign",
  fields = {
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          { s3_endpoint = typedefs.url { required = true } },
          { bucket      = { type = "string", required = true } },
          { region      = { type = "string", default = "us-east-1" } },

          -- base_path must match the route prefix; base_prefix is the folder
          -- inside the bucket. They are separate so the API surface and the
          -- object layout can diverge later without a code change.
          { base_path   = { type = "string", default = "/files" } },
          { base_prefix = { type = "string", default = "files/" } },

          -- referenceable: accepts {vault://env/...} so the secret never
          -- appears in decK YAML. encrypted: at rest in the DB (Kong EE;
          -- needs the keyring configured, drop the flag if it is not).
          { access_key = { type = "string", required = true,
              referenceable = true, encrypted = true } },
          { secret_key = { type = "string", required = true,
              referenceable = true, encrypted = true } },

          { upload_ttl   = { type = "integer", default = 300,
              between = { 30, 604800 } } },
          { download_ttl = { type = "integer", default = 900,
              between = { 30, 604800 } } },
          { max_bytes    = { type = "integer", default = 5000000, gt = 0 } },

          -- "post": presigned POST policy, size cap enforced by S3.
          -- "put":  presigned PUT, for arrays without POST-to-bucket support.
          --         No server-side size cap - use request-size-limiting.
          { upload_mode  = { type = "string", default = "post",
              one_of = { "post", "put" } } },

          { timeout      = { type = "integer", default = 10000 } },
          { ssl_verify   = { type = "boolean", default = true } },
        },
      },
    },
  },
}

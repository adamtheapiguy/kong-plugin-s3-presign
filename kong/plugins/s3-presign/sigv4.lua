-- SigV4 helpers for the s3-presign plugin.
--
-- Custom plugins are not subject to the serverless-function sandbox, so these
-- requires work with no kong.conf change.

local hmac   = require "resty.openssl.hmac"
local sha256 = require "resty.sha256"
local to_hex = require("resty.string").to_hex
local cjson  = require "cjson.safe"

local _M = {}

local ALGO = "AWS4-HMAC-SHA256"


local function hex_sha256(s)
  local d = sha256:new()
  d:update(s or "")
  return to_hex(d:final())
end


local function hmac_sha256(key, msg)
  local h = hmac.new(key, "sha256")
  h:update(msg)
  return h:final()
end


-- AWS percent-encoding: unreserved set is A-Z a-z 0-9 - _ . ~
-- Slashes stay literal in a canonical URI, encoded everywhere else.
local function uri_encode(s, keep_slash)
  return (tostring(s):gsub("[^%w%-%._~]", function(c)
    if c == "/" and keep_slash then
      return "/"
    end
    return string.format("%%%02X", string.byte(c))
  end))
end
_M.uri_encode = uri_encode


local function signing_key(secret, datestamp, region)
  local k = hmac_sha256("AWS4" .. secret, datestamp)
  k = hmac_sha256(k, region)
  k = hmac_sha256(k, "s3")
  return hmac_sha256(k, "aws4_request")
end


local function stamps()
  local now = ngx.time()
  return os.date("!%Y%m%dT%H%M%SZ", now), os.date("!%Y%m%d", now), now
end


-- ---------------------------------------------------------------------------
-- Presigned URL (query-string auth). Used for downloads, and for uploads when
-- upload_mode = "put".
--
-- `extra` is an optional map of additional headers to fold into the signature.
-- Signing a header forces the client to send it with exactly that value, which
-- is how provenance metadata stays tamper-proof on a presigned PUT.
-- ---------------------------------------------------------------------------
function _M.presign(cfg, method, key, expires, extra)
  local amzdate, datestamp = stamps()
  local scope = datestamp .. "/" .. cfg.region .. "/s3/aws4_request"
  local canonical_uri = "/" .. cfg.bucket .. "/" .. uri_encode(key, true)

  -- Canonical headers are sorted by lowercased name.
  local names, values = { "host" }, { host = cfg.host }
  for name, value in pairs(extra or {}) do
    local lname = name:lower()
    names[#names + 1] = lname
    values[lname] = value
  end
  table.sort(names)

  local canonical_headers = {}
  for i, name in ipairs(names) do
    canonical_headers[i] = name .. ":" .. values[name]
  end
  local signed = table.concat(names, ";")

  -- Query parameters must be in ascending order; these already are.
  local qs = "X-Amz-Algorithm=" .. ALGO
    .. "&X-Amz-Credential=" .. uri_encode(cfg.access_key .. "/" .. scope)
    .. "&X-Amz-Date=" .. amzdate
    .. "&X-Amz-Expires=" .. expires
    .. "&X-Amz-SignedHeaders=" .. uri_encode(signed)

  local canonical = method .. "\n" .. canonical_uri .. "\n" .. qs .. "\n"
    .. table.concat(canonical_headers, "\n") .. "\n\n"
    .. signed .. "\nUNSIGNED-PAYLOAD"

  local sts = ALGO .. "\n" .. amzdate .. "\n" .. scope .. "\n" .. hex_sha256(canonical)
  local sig = to_hex(hmac_sha256(signing_key(cfg.secret_key, datestamp, cfg.region), sts))

  return cfg.scheme .. "://" .. cfg.host .. canonical_uri .. "?" .. qs
    .. "&X-Amz-Signature=" .. sig
end


-- ---------------------------------------------------------------------------
-- Header-based signature. Used for the ListObjectsV2 call the plugin makes.
-- ---------------------------------------------------------------------------
function _M.sign_headers(cfg, method, path, query)
  local amzdate, datestamp = stamps()
  local scope = datestamp .. "/" .. cfg.region .. "/s3/aws4_request"
  local payload_hash = hex_sha256("")
  local signed = "host;x-amz-content-sha256;x-amz-date"

  local canonical = method .. "\n" .. path .. "\n" .. (query or "")
    .. "\nhost:" .. cfg.host
    .. "\nx-amz-content-sha256:" .. payload_hash
    .. "\nx-amz-date:" .. amzdate
    .. "\n\n" .. signed .. "\n" .. payload_hash

  local sts = ALGO .. "\n" .. amzdate .. "\n" .. scope .. "\n" .. hex_sha256(canonical)
  local sig = to_hex(hmac_sha256(signing_key(cfg.secret_key, datestamp, cfg.region), sts))

  return {
    ["Host"]                 = cfg.host,
    ["x-amz-date"]           = amzdate,
    ["x-amz-content-sha256"] = payload_hash,
    ["Authorization"]        = ALGO .. " Credential=" .. cfg.access_key .. "/" .. scope
                               .. ", SignedHeaders=" .. signed
                               .. ", Signature=" .. sig,
  }
end


-- ---------------------------------------------------------------------------
-- POST policy. The conditions travel with the upload and are enforced by S3.
-- ---------------------------------------------------------------------------
function _M.presign_post(cfg, key, content_type, meta, max_bytes, ttl)
  local amzdate, datestamp, now = stamps()
  local scope = datestamp .. "/" .. cfg.region .. "/s3/aws4_request"
  local credential = cfg.access_key .. "/" .. scope

  local conditions = {
    { bucket = cfg.bucket },
    { key = key },
    { ["Content-Type"] = content_type },
    { "content-length-range", 1, max_bytes },
    { ["x-amz-algorithm"] = ALGO },
    { ["x-amz-credential"] = credential },
    { ["x-amz-date"] = amzdate },
  }

  local fields = {
    key                  = key,
    ["Content-Type"]     = content_type,
    ["x-amz-algorithm"]  = ALGO,
    ["x-amz-credential"] = credential,
    ["x-amz-date"]       = amzdate,
  }

  -- Object tagging is NotImplemented on this array, so provenance goes in
  -- x-amz-meta-* instead. Each value is asserted in the policy, so a client
  -- cannot alter one without invalidating the signature.
  for name, value in pairs(meta or {}) do
    conditions[#conditions + 1] = { [name] = value }
    fields[name] = value
  end

  local policy = cjson.encode({
    expiration = os.date("!%Y-%m-%dT%H:%M:%SZ", now + ttl),
    conditions = conditions,
  })

  local b64 = ngx.encode_base64(policy)
  fields.policy = b64
  fields["x-amz-signature"] =
    to_hex(hmac_sha256(signing_key(cfg.secret_key, datestamp, cfg.region), b64))

  return {
    url    = cfg.scheme .. "://" .. cfg.host .. "/" .. cfg.bucket,
    fields = fields,
  }
end


return _M

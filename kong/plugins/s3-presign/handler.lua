-- s3-presign: mints presigned S3 URLs and lists bucket contents natively in
-- Kong. Terminates in the access phase; no upstream is ever contacted.

local http  = require "resty.http"
local cjson = require "cjson.safe"
local sigv4 = require "kong.plugins.s3-presign.sigv4"

local S3Presign = {
  -- Below openid-connect (1050), any sideband authorization plugin, and
  -- request-transformer (801), so authentication, authorization and header
  -- scrubbing all run first.
  PRIORITY = 750,
  VERSION  = "0.3.0",
}

local SAFE_NAME = "^[A-Za-z0-9._%-]+$"
local NO_STORE  = "no-store, no-cache, must-revalidate"


-- ---------------------------------------------------------------------------
-- CORS
--
-- Handled here rather than by the stock cors plugin because this plugin exits
-- in the access phase: a short-circuited response may never reach a
-- header_filter, so headers added by another plugin are not guaranteed to
-- land. Preflights also need the route to accept OPTIONS - add it to the
-- route's methods list or the request never reaches this plugin at all.
-- ---------------------------------------------------------------------------

local function cors_headers(conf)
  if not conf.cors_enabled then
    return {}
  end

  local origin = kong.request.get_header("Origin")
  local allow

  for _, candidate in ipairs(conf.cors_origins or {}) do
    if candidate == "*" then
      allow = "*"
      break
    elseif origin and candidate == origin then
      allow = origin
      break
    end
  end

  if not allow then
    return {}
  end

  return {
    ["Access-Control-Allow-Origin"]   = allow,
    ["Access-Control-Expose-Headers"] = table.concat(conf.cors_expose_headers, ", "),
    ["Vary"]                          = "Origin",
  }
end


-- Merge CORS headers into a response header table.
local function with_cors(conf, headers)
  local out = headers or {}
  for name, value in pairs(cors_headers(conf)) do
    out[name] = value
  end
  return out
end


local function preflight(conf)
  local headers = cors_headers(conf)

  if not headers["Access-Control-Allow-Origin"] then
    return kong.response.exit(403, { error = "origin not allowed" })
  end

  headers["Access-Control-Allow-Methods"] = table.concat(conf.cors_methods, ", ")
  headers["Access-Control-Allow-Headers"] = table.concat(conf.cors_headers, ", ")
  headers["Access-Control-Max-Age"]       = tostring(conf.cors_max_age)

  return kong.response.exit(204, nil, headers)
end


local function s3_config(conf)
  local scheme, host = conf.s3_endpoint:match("^(https?)://([^/]+)")
  return {
    scheme     = scheme,
    host       = host,
    region     = conf.region,
    bucket     = conf.bucket,
    access_key = conf.access_key,
    secret_key = conf.secret_key,
  }
end


-- Single header value. Kong lowercases header names; repeated headers arrive
-- as a table, in which case take the first.
local function header(name, default)
  local v = kong.request.get_header(name)
  if type(v) == "table" then v = v[1] end
  if v == nil or v == "" then return default end
  return v
end


-- Provenance stamped onto every upload. Values come only from headers Kong
-- itself set - request-transformer strips any client-supplied copies first -
-- and each one is asserted in the POST policy, so a client cannot alter a
-- value without invalidating the signature.
local function provenance(conf)
  return {
    ["x-amz-meta-uploadedby"] =
      header(conf.client_id_header, "unknown"),
    ["x-amz-meta-clientipattimeofupload"] =
      header(conf.client_ip_header, "unknown"),
    ["x-amz-meta-client-cert-thumbprint"] =
      header(conf.cert_thumbprint_header, "unknown"),
    ["x-amz-meta-uploadedat"] =
      os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }
end


-- ---------------------------------------------------------------------------
-- 1. upload
-- ---------------------------------------------------------------------------
local function op_upload(conf, cfg)
  local body = kong.request.get_body("application/json") or {}
  local filename = body.filename
  local content_type = body.contentType or "application/octet-stream"

  if type(filename) ~= "string"
     or #filename == 0 or #filename > 128
     or not filename:match(SAFE_NAME) then
    return kong.response.exit(400, {
      error = "filename must match [A-Za-z0-9._-] and be 1-128 characters",
    }, with_cors(conf))
  end

  local key = conf.base_prefix .. filename
  local meta = provenance(conf)

  -- PUT mode: fallback for object stores without POST-to-bucket form uploads.
  -- Metadata headers are folded into the signature so they stay tamper-proof,
  -- but S3 cannot enforce a size limit on a presigned PUT - cap it with the
  -- request-size-limiting plugin on the upload route instead.
  if conf.upload_mode == "put" then
    local headers = { ["content-type"] = content_type }
    for name, value in pairs(meta) do
      headers[name] = value
    end

    return kong.response.exit(200, {
      key       = key,
      expiresIn = conf.upload_ttl,
      upload    = {
        method          = "PUT",
        url             = sigv4.presign(cfg, "PUT", key, conf.upload_ttl, headers),
        requiredHeaders = headers,
      },
    }, with_cors(conf, { ["Cache-Control"] = NO_STORE }))
  end

  -- POST mode: the policy document travels with the upload, so S3 enforces
  -- content-length-range server-side.
  local post = sigv4.presign_post(cfg, key, content_type, meta,
                                  conf.max_bytes, conf.upload_ttl)

  return kong.response.exit(200, {
    key       = key,
    expiresIn = conf.upload_ttl,
    maxBytes  = conf.max_bytes,
    upload    = post,
  }, with_cors(conf, { ["Cache-Control"] = NO_STORE }))
end


-- ---------------------------------------------------------------------------
-- 2. download
--
-- 307 with Location set to the presigned URL, and the JSON body retained. A
-- client that follows redirects gets the object in one round trip; a client
-- that wants the URL reads the body and ignores the redirect. 307 (not 302)
-- so the method is preserved on the way through.
-- ---------------------------------------------------------------------------
local function op_download(conf, cfg, rest)
  if rest:find("%.%.") then
    return kong.response.exit(400, { error = "invalid path" }, with_cors(conf))
  end

  local key = conf.base_prefix .. rest
  local url = sigv4.presign(cfg, "GET", key, conf.download_ttl)

  return kong.response.exit(307, {
    key      = key,
    download = { url = url, expiresIn = conf.download_ttl },
  }, with_cors(conf, {
    ["Location"]      = url,
    ["Cache-Control"] = NO_STORE,
  }))
end


-- ---------------------------------------------------------------------------
-- 3. list
--
-- Mirrors the S3 ListObjectsV2 response, field for field, rendered as JSON.
-- No delimiter is sent, so the listing is flat and there are no CommonPrefixes.
-- ---------------------------------------------------------------------------
local function op_list(conf, cfg)
  local args = kong.request.get_query()

  local extra = args.prefix
  if type(extra) ~= "string" or extra:find("%.%.") then
    extra = ""
  end
  local prefix = conf.base_prefix .. extra

  local token = type(args["continuation-token"]) == "string"
                and args["continuation-token"] or nil
  local max_keys = tonumber(args["max-keys"]) or conf.max_keys

  -- Canonical query string must be sorted by parameter name; the order below
  -- is already ascending.
  local parts = {}
  if token then
    parts[#parts + 1] = "continuation-token=" .. sigv4.uri_encode(token)
  end
  parts[#parts + 1] = "list-type=2"
  parts[#parts + 1] = "max-keys=" .. max_keys
  parts[#parts + 1] = "prefix=" .. sigv4.uri_encode(prefix)
  local query = table.concat(parts, "&")

  local path    = "/" .. cfg.bucket
  local headers = sigv4.sign_headers(cfg, "GET", path, query)

  local httpc = http.new()
  httpc:set_timeout(conf.timeout)

  local res, err = httpc:request_uri(
    cfg.scheme .. "://" .. cfg.host .. path .. "?" .. query,
    { method = "GET", headers = headers, ssl_verify = conf.ssl_verify }
  )

  if not res then
    kong.log.err("s3 list failed: ", err)
    return kong.response.exit(502, { error = "object store unreachable" },
                              with_cors(conf))
  end

  if res.status ~= 200 then
    kong.log.err("s3 list returned ", res.status, ": ", res.body)
    return kong.response.exit(502, {
      error = "object store error", status = res.status,
    }, with_cors(conf))
  end

  -- ListBucketResult is flat enough that pattern matching beats pulling in an
  -- XML parser. Nested or namespaced responses would need a real one.
  local function unescape(s)
    if not s then return nil end
    return (s:gsub("&quot;", '"'):gsub("&lt;", "<"):gsub("&gt;", ">")
             :gsub("&apos;", "'"):gsub("&amp;", "&"))
  end

  local contents = {}
  for block in res.body:gmatch("<Contents>(.-)</Contents>") do
    local key = unescape(block:match("<Key>(.-)</Key>")) or ""
    if not key:match("/$") then          -- skip directory markers
      contents[#contents + 1] = {
        Key          = key,
        LastModified = block:match("<LastModified>(.-)</LastModified>"),
        ETag         = unescape(block:match("<ETag>(.-)</ETag>")),
        Size         = tonumber(block:match("<Size>(.-)</Size>")) or 0,
        StorageClass = block:match("<StorageClass>(.-)</StorageClass>"),
      }
    end
  end

  local truncated = res.body:match("<IsTruncated>(.-)</IsTruncated>") == "true"

  local out = {
    Name        = cfg.bucket,
    Prefix      = prefix,
    MaxKeys     = max_keys,
    KeyCount    = #contents,
    IsTruncated = truncated,
    Contents    = setmetatable(contents, cjson.array_mt),
  }

  if token then
    out.ContinuationToken = token
  end
  if truncated then
    out.NextContinuationToken =
      unescape(res.body:match("<NextContinuationToken>(.-)</NextContinuationToken>"))
  end

  return kong.response.exit(200, out, with_cors(conf, { ["Cache-Control"] = NO_STORE }))
end


-- ---------------------------------------------------------------------------

function S3Presign:access(conf)
  local cfg    = s3_config(conf)
  local method = kong.request.get_method()
  local path   = kong.request.get_path()

  -- Everything after the base path, or nil for the collection itself.
  local escaped = conf.base_path:gsub("([%-%.%+%[%]%(%)%$%^%%%?%*])", "%%%1")
  local rest = path:match("^" .. escaped .. "/(.+)$")

  -- Preflight is answered before authentication would matter: browsers never
  -- send credentials on an OPTIONS, so a 401 here breaks every browser client.
  if method == "OPTIONS" and conf.cors_enabled then
    return preflight(conf)
  end

  if method == "POST" and not rest then
    return op_upload(conf, cfg)
  elseif method == "GET" and rest then
    return op_download(conf, cfg, rest)
  elseif method == "GET" and not rest then
    return op_list(conf, cfg)
  end

  return kong.response.exit(405, { error = "method not allowed" }, with_cors(conf))
end


return S3Presign

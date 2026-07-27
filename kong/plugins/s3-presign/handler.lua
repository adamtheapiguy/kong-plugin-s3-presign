-- s3-presign: mints presigned S3 URLs and lists bucket contents natively in
-- Kong. Terminates in the access phase; no upstream is ever contacted.

local http  = require "resty.http"
local cjson = require "cjson.safe"
local sigv4 = require "kong.plugins.s3-presign.sigv4"

local S3Presign = {
  -- Below openid-connect (1050), ping-auth and request-transformer (801) so
  -- authentication, authorization and header scrubbing all run first.
  PRIORITY = 750,
  VERSION  = "0.1.0",
}

local SAFE_NAME = "^[A-Za-z0-9._%-]+$"


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


-- Identity comes from headers Kong itself set. The request-transformer strips
-- any client-supplied copies first, so these cannot be spoofed - provided the
-- data plane is only reachable through the load balancer.
local function caller()
  local h = kong.request.get_headers()
  local function one(name, default)
    local v = h[name]
    if type(v) == "table" then v = v[1] end
    return v or default
  end
  return {
    sub     = one("x-authenticated-userid", "unknown"),
    email   = one("x-authenticated-email", "unknown"),
    company = one("x-authenticated-company", "unknown"),
    ip      = one("x-real-ip") or kong.client.get_forwarded_ip() or "unknown",
  }
end


local function provenance()
  local who = caller()
  return {
    ["x-amz-meta-objectowneremail"]       = who.email,
    ["x-amz-meta-developerfirstcompany"]  = who.company,
    ["x-amz-meta-clientipattimeofupload"] = who.ip,
    ["x-amz-meta-uploadedby"]             = who.sub,
    ["x-amz-meta-uploadedat"]             = os.date("!%Y-%m-%dT%H:%M:%SZ"),
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
    })
  end

  local key = conf.base_prefix .. filename
  local meta = provenance()

  -- PUT mode: fallback for arrays that do not implement POST-to-bucket form
  -- uploads. The metadata headers are folded into the signature so they stay
  -- tamper-proof, but S3 cannot enforce a size limit on a presigned PUT -
  -- cap it with the request-size-limiting plugin on the route instead.
  if conf.upload_mode == "put" then
    local headers = { ["content-type"] = content_type }
    for name, value in pairs(meta) do
      headers[name] = value
    end

    local url = sigv4.presign(cfg, "PUT", key, conf.upload_ttl, headers)

    return kong.response.exit(200, {
      key       = key,
      expiresIn = conf.upload_ttl,
      upload    = {
        method          = "PUT",
        url             = url,
        requiredHeaders = headers,
      },
    })
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
  })
end


-- ---------------------------------------------------------------------------
-- 2. download
-- ---------------------------------------------------------------------------
local function op_download(conf, cfg, rest)
  if rest:find("%.%.") then
    return kong.response.exit(400, { error = "invalid path" })
  end

  local key = conf.base_prefix .. rest
  local url = sigv4.presign(cfg, "GET", key, conf.download_ttl)

  return kong.response.exit(200, {
    key      = key,
    download = { url = url, expiresIn = conf.download_ttl },
  })
end


-- ---------------------------------------------------------------------------
-- 3. list
-- ---------------------------------------------------------------------------
local function op_list(conf, cfg)
  local args = kong.request.get_query()
  local extra = args.prefix
  if type(extra) ~= "string" or extra:find("%.%.") then
    extra = ""
  end
  local prefix = conf.base_prefix .. extra

  -- Canonical query string must be in ascending key order.
  local query = "delimiter=%2F&list-type=2&prefix=" .. sigv4.uri_encode(prefix)
  local path  = "/" .. cfg.bucket

  local headers = sigv4.sign_headers(cfg, "GET", path, query)

  local httpc = http.new()
  httpc:set_timeout(conf.timeout)

  local res, err = httpc:request_uri(
    cfg.scheme .. "://" .. cfg.host .. path .. "?" .. query,
    { method = "GET", headers = headers, ssl_verify = conf.ssl_verify }
  )

  if not res then
    kong.log.err("s3 list failed: ", err)
    return kong.response.exit(502, { error = "object store unreachable" })
  end

  if res.status ~= 200 then
    kong.log.err("s3 list returned ", res.status, ": ", res.body)
    return kong.response.exit(502, { error = "object store error", status = res.status })
  end

  -- ListBucketResult is flat enough that pattern matching beats pulling in an
  -- XML parser. Nested or namespaced responses would need a real one.
  local objects, folders = {}, {}

  for block in res.body:gmatch("<Contents>(.-)</Contents>") do
    local key = block:match("<Key>(.-)</Key>") or ""
    if not key:match("/$") then          -- skip directory markers
      objects[#objects + 1] = {
        key          = key,
        name         = key:sub(#conf.base_prefix + 1),
        size         = tonumber(block:match("<Size>(.-)</Size>")) or 0,
        lastModified = block:match("<LastModified>(.-)</LastModified>"),
        etag         = (block:match("<ETag>(.-)</ETag>") or ""):gsub("&quot;", ""),
      }
    end
  end

  for block in res.body:gmatch("<CommonPrefixes>(.-)</CommonPrefixes>") do
    local p = block:match("<Prefix>(.-)</Prefix>")
    if p then
      folders[#folders + 1] = p:sub(#conf.base_prefix + 1)
    end
  end

  local truncated = res.body:match("<IsTruncated>(.-)</IsTruncated>") == "true"
  if truncated then
    kong.log.warn("s3 listing truncated at 1000 keys for prefix ", prefix)
  end

  return kong.response.exit(200, {
    prefix    = prefix,
    count     = #objects,
    truncated = truncated,
    folders   = setmetatable(folders, cjson.array_mt),
    objects   = setmetatable(objects, cjson.array_mt),
  })
end


-- ---------------------------------------------------------------------------

function S3Presign:access(conf)
  local cfg    = s3_config(conf)
  local method = kong.request.get_method()
  local path   = kong.request.get_path()

  -- Everything after the base path, or nil for the collection itself.
  local escaped = conf.base_path:gsub("([%-%.%+%[%]%(%)%$%^%%%?%*])", "%%%1")
  local rest = path:match("^" .. escaped .. "/(.+)$")

  if method == "POST" and not rest then
    return op_upload(conf, cfg)
  elseif method == "GET" and rest then
    return op_download(conf, cfg, rest)
  elseif method == "GET" and not rest then
    return op_list(conf, cfg)
  end

  return kong.response.exit(405, { error = "method not allowed" })
end


return S3Presign

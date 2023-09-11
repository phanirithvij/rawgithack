local json = require("cjson")
local http = require("resty.http")
local cfg = require("config")

local function error(desc)
   ngx.status = ngx.HTTP_BAD_REQUEST
   ngx.say(json.encode({success = false, response = desc}))
   ngx.exit(ngx.status)
end


local function validate_files(raw_files)
   if not raw_files then error("wrong number of URLs") end

   local files, invalid_files = {}, {}
   for l in raw_files:gmatch('[^\r\n]+') do
      local url = l:gsub('^%s*(.*)%s*$', '%1') -- trailing whitespaces
      local valid = url:match('^https?://%w+cdn%.armyofrats%.in')
      table.insert(valid and files or invalid_files, url)
   end

   if #invalid_files > 0 then error("invalid URLs: " .. table.concat(invalid_files, ', ')) end
   if #files < 1 or #files > 30 then error("wrong number of URLs") end

   return files
end


local function cdn_purge(files)
   local headers = {
      ['Content-Type'] = 'application/json',
      ['X-Auth-Email'] = cfg.cf.username,
      ['X-Auth-Key'] = cfg.cf.api_key
   }
   local purge_url = 'https://api.cloudflare.com/client/v4/zones/' .. cfg.cf.zone .. '/purge_cache'
   local params = {
       method='POST',
       headers=headers,
       body=json.encode({files=files})}
   local res = http.new():request_uri(purge_url, params)
   if res.status ~= 200 then
      ngx.log(ngx.ERR, "CDN response error: " .. res.body)
      return false
   end
   return true
end


local function url_to_cache_key(url)
   local map = {
      ['^https?://glcdn%.armyofrats%.in'] = 'gitlab.com',
      ['^https?://bbcdn%.armyofrats%.in'] = 'bitbucket.org',
      ['^https?://rawcdn%.armyofrats%.in'] = 'raw.githubusercontent.com',
      ['^https?://gistcdn%.armyofrats%.in'] = 'gist.githubusercontent.com',
      ['^https?://srhtcdn%.armyofrats%.in'] = 'git.sr.ht',
      ['^https?://srhgtcdn%.armyofrats%.in'] = 'hg.sr.ht'
   }
   for pattern, origin in pairs(map) do
      local cache_key, n = url:gsub(pattern, origin, 1)
      if n == 1 then return cache_key end
   end
end


local function local_purge(files)
   local dir = '/var/cache/nginx/rawgithack'
   local keys = {}
   for _, f in pairs(files) do
      keys[#keys] = ngx.md5(url_to_cache_key(f))
   end
   for _, key in pairs(keys) do
      -- TODO support arbitrary logic of cache path
      local path = table.concat({dir, key:sub(-1), key:sub(-3, -2), key}, '/')
      local _, err = os.remove(path)
      if err then
         ngx.log(ngx.WARN, "unable to remove cache file " .. path .. ", err:" .. err)
      end
   end
end


local function purge_request()
   local args, err = ngx.req.get_post_args()
   if err == "truncated" then error("truncated request") end

   local files = validate_files(args.files)
   ngx.log(ngx.WARN, "got a request to purge #" .. #files .. " files")
   local_purge(files) 
   if not cdn_purge(files) then error("CDN response error") end
   ngx.say(json.encode({success = true, response = 'cache was successfully invalidated!'}))
end


return {
   purge_request = purge_request
}

local urlparse = require("socket.url")
local http = require("socket.http")
local https = require("ssl.https")
local cjson = require("cjson")
local utf8 = require("utf8")
local base64 = require("base64")

local item_dir = os.getenv("item_dir")
local warc_file_base = os.getenv("warc_file_base")
local concurrency = tonumber(os.getenv("concurrency"))
local item_type = nil
local item_name = nil
local item_value = nil
local item_user = nil

local url_count = 0
local tries = 0
local downloaded = {}
local seen_200 = {}
local addedtolist = {}
local abortgrab = false
local killgrab = false
local logged_response = false

local discovered_outlinks = {}
local discovered_items = {}
local bad_items = {}
local ids = {}

local thread_counts = {}

local retry_url = false
local is_initial_url = true

abort_item = function(item)
  abortgrab = true
  --killgrab = true
  if not item then
    item = item_name
  end
  if not bad_items[item] then
    io.stdout:write("Aborting item " .. item .. ".\n")
    io.stdout:flush()
    bad_items[item] = true
  end
end

kill_grab = function(item)
  io.stdout:write("Aborting crawling.\n")
  killgrab = true
end

read_file = function(file)
  if file then
    local f = assert(io.open(file))
    local data = f:read("*all")
    f:close()
    return data
  else
    return ""
  end
end

processed = function(url)
  if downloaded[url] or addedtolist[url] then
    return true
  end
  return false
end

discover_item = function(target, item)
  if not target[item] then
--print('discovered', item)
    target[item] = true
    return true
  end
  return false
end

find_item = function(url)
  local value = nil
  local type_ = nil
  for pattern, name in pairs({
    ["^https?://api%-beta%.taringa%.net/story/([0-9a-z]+)$"]="story",
    ["^https?://api%-beta%.taringa%.net/user/([^/]+)/about$"]="user",
    ["^https?://api%-beta%.taringa%.net/c/([^/]+)/about$"]="channel",
    ["^https?://api%-beta%.taringa%.net/comment/([0-9a-z]+)$"]="comment",
    ["^https?://media%.taringa%.net/knn/identity/([^%?&]+)$"]="media",
    ["^https?://[^/]*taringa%.net/tags/([^/%?&]+)$"]="tag",
    ["^https?://[^/]*taringa%.net/%+([^/]+/[^%?&]+_[0-9a-z][0-9a-z]*[0-9a-z]*[0-9a-z]*[0-9a-z]*[0-9a-z]*)$"]="storyhtml"
  }) do
    value = string.match(url, pattern)
    type_ = name
    if value then
      break
    end
  end
  if value and type_ then
    return {
      ["value"]=value,
      ["type"]=type_
    }
  end
end

set_item = function(url)
  found = find_item(url)
  if found then
    item_type = found["type"]
    item_value = found["value"]
    item_name_new = item_type .. ":" .. item_value
    if item_name_new ~= item_name then
      ids = {}
      ids[item_value] = true
      abortgrab = false
      tries = 0
      retry_url = false
      is_initial_url = true
      item_name = item_name_new
      print("Archiving item " .. item_name)
    end
  end
end

allowed = function(url, parenturl)
  if ids[url] then
    return true
  end

  if string.match(url, "^https?://[^/]*kn3%.net/.")
    or string.match(url, "^https?://[^/]*t26%.net/.") then
    local path = string.match(url, "^https?://[^/]+(/[^%?&]+)")
    allowed("gs://kn3" .. path)
    if not string.match(path, "^/taringa/") then
      allowed("gs://kn3/taringa" .. path)
    end
  end
  if string.match(url, "^gs://") then
    local encoded = base64.encode(url)
    allowed("https://media.taringa.net/knn/dummy/" .. string.match(encoded, "^([^=]+)"))
    return allowed("https://media.taringa.net/knn/dummy/" .. encoded)
  end

  local found = false
  local skip = false
  for pattern, type_ in pairs({
    ["^https?://media%.taringa%.net/knn/[^/]+/([^%?&/]+)"]="media",
    ["^https?://[^/]+taringa%.net/tags/([^/%?&]+)"]="tag",
    ["^https?://taringa%.net/%+([a-zA-Z0-9]+)"]="channel",
    ["^https?://www%.taringa%.net/%+([a-zA-Z0-9]+)"]="channel",
    ["^https?://taringa%.net/([^%+][^%?&/]+)$"]="user",
    ["^https?://www%.taringa%.net/([^%+][^%?&/]+)$"]="user",
    ["^https?://taringa%.net/[^/]+/.+_([0-9a-z][0-9a-z]?[0-9a-z]?[0-9a-z]?[0-9a-z]?[0-9a-z]?)$"]="story",
    ["^https?://www%.taringa%.net/[^/]+/.+_([0-9a-z][0-9a-z]?[0-9a-z]?[0-9a-z]?[0-9a-z]?[0-9a-z]?)$"]="story",
    ["[%?&]commentId=([0-9a-z]+)"]="comment",
    ["^https?://([^/]*t26%.net/.*)$"]="asset",
    ["^https?://[^/]*taringa%.net/%+([^/]+/[^%?&]+_[0-9a-z][0-9a-z]*[0-9a-z]*[0-9a-z]*[0-9a-z]*[0-9a-z]*)$"]="storyhtml"
  }) do
    match = string.match(url, pattern)
    if match then
      local new_item = type_ .. ":" .. match
      if new_item ~= item_name then
        discover_item(discovered_items, new_item)
        found = true
        if type_ == "storyhtml" then
          skip = true
        end
      end
    end
  end
  if skip then
    return false
  end
  --[[if found and item_type ~= "channel"
    and item_type ~= "user"
    and item_type ~= "story" then
    return false
  end]]
  
  if string.match(url, "^https?://[^/]*kn3.net/.") then
    return false
  end
  
  if not string.match(url, "^https?://[^/]*taringa%.net/")
    and not string.match(url, "^https?://[^/]*t26%.net/") then
    discover_item(discovered_outlinks, url)
  end

  for _, pattern in pairs({
    "[^0-9a-z]([0-9a-z]+)",
    "([^%?&;/]+)",
    "^https?://[^/]*taringa%.net/%+([^/]+/[^%?&]+_[0-9a-z][0-9a-z]*[0-9a-z]*[0-9a-z]*[0-9a-z]*[0-9a-z]*)$"
  }) do
    for s in string.gmatch(url, pattern) do
      if ids[s] then
        return true
      end
    end
  end

  return false
end

wget.callbacks.download_child_p = function(urlpos, parent, depth, start_url_parsed, iri, verdict, reason)
  local url = urlpos["url"]["url"]
  local html = urlpos["link_expect_html"]

  if allowed(url, parent["url"])
    and not processed(url)
    and string.match(url, "^https://")
    and not addedtolist[url] then
    addedtolist[url] = true
    return true
  end

  return false
end

decode_codepoint = function(newurl)
  newurl = string.gsub(
    newurl, "\\[uU]([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])",
    function (s)
      return utf8.char(tonumber(s, 16))
    end
  )
  return newurl
end

percent_encode_url = function(newurl)
  result = string.gsub(
    newurl, "(.)",
    function (s)
      local b = string.byte(s)
      if b < 32 or b > 126 then
        return string.format("%%%02X", b)
      end
      return s
    end
  )
  return result
end

wget.callbacks.get_urls = function(file, url, is_css, iri)
  local urls = {}
  local html = nil
  local json = nil
  
  downloaded[url] = true

  if abortgrab then
    return {}
  end

  local function fix_case(newurl)
    if not newurl then
      newurl = ""
    end
    if not string.match(newurl, "^https?://[^/]") then
      return newurl
    end
    if string.match(newurl, "^https?://[^/]+$") then
      newurl = newurl .. "/"
    end
    local a, b = string.match(newurl, "^(https?://[^/]+/)(.*)$")
    return string.lower(a) .. b
  end

  local function check(newurl)
    if not newurl then
      newurl = ""
    end
    newurl = decode_codepoint(newurl)
    newurl = fix_case(newurl)
    local origurl = url
    if string.len(url) == 0 or string.len(newurl) == 0 then
      return nil
    end
    local url = string.match(newurl, "^([^#]+)")
    local url_ = string.match(url, "^(.-)[%.\\]*$")
    while string.find(url_, "&amp;") do
      url_ = string.gsub(url_, "&amp;", "&")
    end
    if not processed(url_)
      and not processed(url_ .. "/")
      and allowed(url_, origurl) then
--print('queued', url_)
      table.insert(urls, {
        url=url_
      })
      addedtolist[url_] = true
      addedtolist[url] = true
    end
  end

  local function checknewurl(newurl)
    if not newurl then
      newurl = ""
    end
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "['\"><]") then
      return nil
    end
    if string.match(newurl, "^https?:////") then
      check(string.gsub(newurl, ":////", "://"))
    elseif string.match(newurl, "^https?://") then
      check(newurl)
    elseif string.match(newurl, "^https?:\\/\\?/") then
      check(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^\\/\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^//") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^/") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^%.%./") then
      if string.match(url, "^https?://[^/]+/[^/]+/") then
        check(urlparse.absolute(url, newurl))
      else
        checknewurl(string.match(newurl, "^%.%.(/.+)$"))
      end
    elseif string.match(newurl, "^%./") then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function checknewshorturl(newurl)
    if not newurl then
      newurl = ""
    end
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "^%?") then
      check(urlparse.absolute(url, newurl))
    elseif not (
      string.match(newurl, "^https?:\\?/\\?//?/?")
      or string.match(newurl, "^[/\\]")
      or string.match(newurl, "^%./")
      or string.match(newurl, "^[jJ]ava[sS]cript:")
      or string.match(newurl, "^[mM]ail[tT]o:")
      or string.match(newurl, "^vine:")
      or string.match(newurl, "^android%-app:")
      or string.match(newurl, "^ios%-app:")
      or string.match(newurl, "^data:")
      or string.match(newurl, "^irc:")
      or string.match(newurl, "^%${")
    ) then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function set_new_params(newurl, data)
    for param, value in pairs(data) do
      if value == nil then
        value = ""
      elseif type(value) == "string" then
        value = "=" .. value
      end
      if string.match(newurl, "[%?&]" .. param .. "[=&]") then
        newurl = string.gsub(newurl, "([%?&]" .. param .. ")=?[^%?&;]*", "%1" .. value)
      else
        if string.match(newurl, "%?") then
          newurl = newurl .. "&"
        else
          newurl = newurl .. "?"
        end
        newurl = newurl .. param .. value
      end
    end
    return newurl
  end

  local function increment_param(newurl, param, default, step)
    local value = string.match(newurl, "[%?&]" .. param .. "=([0-9]+)")
    if value then
      value = tonumber(value)
      value = value + step
      return check_new_params(newurl, param, tostring(value))
    else
      return check_new_params(newurl, param, default)
    end
  end

  local function flatten_json(json)
    local result = ""
    for k, v in pairs(json) do
      result = result .. " " .. k
      local type_v = type(v)
      if type_v == "string" then
        v = string.gsub(v, "\\", "")
        result = result .. " " .. v .. ' "' .. v .. '"'
      elseif type_v == "table" then
        result = result .. " " .. flatten_json(v)
      end
    end
    return result
  end

  local function extract_from_json(json)
    local new_type = json["type"]
    if new_type then
      new_type = string.match(new_type, "^([a-z]+)")
      local actual_type = nil
      if new_type == "comment"
        or new_type == "story"
        or new_type == "user"
        or new_type == "channel" then
        actual_type = new_type
      end
      if actual_type then
        local type_to_value = {
          comment="id",
          story="id",
          channel="name",
          user="username"
        }
        local new_value = json[type_to_value[actual_type]]
        if new_value then
          discover_item(discovered_items, actual_type .. ":" .. new_value)
        end
      end
    end
    for k, v in pairs(json) do
      if type(v) == "table" then
        extract_from_json(v)
      end
      if k == "keywords"
      	or k == "usertags"
      	or k == "tags" then
      	for _, word in pairs(v) do
      	  discover_item(discovered_items, "tag:" .. percent_encode_url(word))
      	end
      end
    end
  end
  
  if item_type == "media" then
    for _, size in pairs({
      "crop",
      "crop:62x62",
      "crop:90x90",
      "crop:120x120",
      "crop:150x115",
      "crop:1260x800",
      "fit:360x170",
      "fit:550",
      "identity",
    }) do
      check("https://media.taringa.net/knn/" .. size .. "/" .. item_value)
    end
  end

  if allowed(url)
    and status_code < 300 then
    html = read_file(file)
    if string.match(url, "^https?://api%-beta%.taringa%.net/") then
      json = cjson.decode(percent_encode_url(decode_codepoint(html)))
      extract_from_json(json)
    end
    if string.match(url, "^https?://api%-beta%.taringa%.net/story/([0-9a-z]+)$") then
      json = cjson.decode(html)
      check("https://www.taringa.net/+" .. json["channel"]["name"] .. "/" .. json["slug"])
      --check("https://api-beta.taringa.net/story/" .. item_value .. "/related?count=12")
      if json["comments"] > 0 then
        check("https://api-beta.taringa.net/story/" .. item_value .. "/comments?sort=created-desc&count=50&repliesCount=10&repliesSort=created-asc&page=0&after=")
      end
    end
    if string.match(url, "/story/[0-9a-z]+/comments%?")
      or string.match(url, "/user/[^/]+/comments%?")
      or string.match(url, "/user/[^/]+/followers%?")
      or string.match(url, "/user/[^/]+/following%?")
      or string.match(url, "/c/[^/]+/feed%?") then
      json = cjson.decode(html)
      local last_id = nil
      for _, data in pairs(json["items"]) do
        last_id = data["id"]
      end
      if last_id then
        local newurl = set_new_params(url, {after=last_id})
        if string.match(url, "/c/[^/]+/feed%?") then
          newurl = string.gsub(newurl, "([%?&])withTips=true&?", "%1")
          newurl = string.match(newurl, "^(.-)[%?&]+")
        end
        if string.match(url, "/user/[^/]+/comments%?")
          or string.match(url, "/c/[^/]+/feed%?") then
          newurl = increment_param(newurl, "page", "1", 1)
        end
        check(newurl)
      end
    end
    if string.match(url, "/user/[^/]+/feed%?") then
      if string.len(json["before"]) > 0 or string.len(json["after"]) > 0 then
        local newurl = increment_param(newurl, "page", "1", 1)
        newurl = increment_param(newurl, "count", tostring(json["count"]), json["count"])
        newurl = string.gsub(newurl, "([%?&])sharedBy=true&?", "%1")
        newurl = string.match(newurl, "^(.-)[%?&]+") 
        newurl = set_new_param(newurl, {
          after=json["after"],
          before=json["before"],
          q="",
          sort="",
          period=nil,
          seed=nil,
          referrer=nil
        })
        check(newurl)
      end
    end
    if string.match(url, "^https?://api%-beta%.taringa%.net/c/[^/]+/about$") then
      check("https://api-beta.taringa.net/c/" .. item_value .. "/feed?count=20&filter=article&sort=bigbang1d&withTips=true")
      check("https://api-beta.taringa.net/c/" .. item_value .. "/tops/week?count=20&filter=article&sort=tops&nsfw=false")
      check("https://api-beta.taringa.net/c/" .. item_value .. "/stickies?count=20")
    end
    if string.match(url, "^https?://api%-beta%.taringa%.net/user/[^/]+/about$") then
      check("https://www.taringa.net/" .. item_value .. "/comentarios")
      check("https://www.taringa.net/" .. item_value)
      check("https://api-beta.taringa.net/user/" .. item_value .. "/comments?count=20")
      check("https://api-beta.taringa.net/user/" .. item_value .. "/followers?count=6")
      check("https://api-beta.taringa.net/user/" .. item_value .. "/following?count=6")
      check("https://api-beta.taringa.net/user/" .. item_value .. "/subscriptions?count=6&sort=subscribed-desc")
      check("https://api-beta.taringa.net/user/" .. item_value .. "/subscriptions?count=20&role=true")
      check("https://api-beta.taringa.net/user/" .. item_value .. "/feed?count=20&withTips=true&filter=article&sharedBy=false")
      check("https://api-beta.taringa.net/user/" .. item_value .. "/feed?count=20&withTips=true&filter=article&sharedBy=false")
      check("https://api-beta.taringa.net/user/" .. item_value .. "/feed?count=20&withTips=true&filter=image%2Cvideo%2Ctext%2Clink%2Cshare&sharedBy=true")
      for _, range in pairs({"all-time", "year", "month", "week"}) do
        check("https://api-beta.taringa.net/user/" .. item_value .. "/tops/" .. range .. "?count=5&filter=article")
      end
    end
    if string.match(html, "^%s*{") then
      if not json then
        json = cjson.decode(percent_encode_url(decode_codepoint(html)))
      end
      extract_from_json(json)
      html = html .. flatten_json(json)
    end
    for newurl in string.gmatch(string.gsub(html, "&quot;", '"'), '([^"]+)') do
      if string.match(newurl, "^gs://") then
      	allowed(newurl)
      end
      checknewurl(newurl)
    end
    for newurl in string.gmatch(string.gsub(html, "&#039;", "'"), "([^']+)") do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(html, "[^%-]href='([^']+)'") do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, '[^%-]href="([^"]+)"') do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, ":%s*url%(([^%)]+)%)") do
      checknewurl(newurl)
    end
    if not string.match(url, "%.mpd$") then
      html = string.gsub(html, "&gt;", ">")
      html = string.gsub(html, "&lt;", "<")
      for newurl in string.gmatch(html, ">%s*([^<%s]+)") do
        checknewurl(newurl)
      end
    end
  end

  return urls
end

wget.callbacks.write_to_warc = function(url, http_stat)
  status_code = http_stat["statcode"]
  set_item(url["url"])
  url_count = url_count + 1
  io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
  io.stdout:flush()
  logged_response = true
  if not item_name then
    error("No item name found.")
  end
  is_initial_url = false
  if string.match(url["url"], "^https?://api%-beta%.taringa%.net/") then
    local html = read_file(http_stat["local_file"])
    if not (
        string.match(html, "^%s*{")
        and string.match(html, "}%s*$")
      ) then
      print("Did not get JSON data.")
      retry_url = true
      return false
    end
    local json = cjson.decode(percent_encode_url(decode_codepoint(html)))
  elseif string.match(url["url"], "^https?://taringa%.net/")
    or string.match(url["url"], "^https?://www%.taringa%.net/") then
    local html = read_file(http_stat["local_file"])
    if not string.match(html, '"datePublished"')
      or not string.match(html, '"author"') then
      print("Got bad 200 response.")
      retry_url = true
      return false
    end
  end
  if http_stat["statcode"] ~= 200 then
    retry_url = true
    return false
  end
  if abortgrab then
    print("Not writing to WARC.")
    return false
  end
  retry_url = false
  tries = 0
  return true
end

wget.callbacks.httploop_result = function(url, err, http_stat)
  status_code = http_stat["statcode"]
  
  if not logged_response then
    url_count = url_count + 1
    io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
    io.stdout:flush()
  end
  logged_response = false

  if killgrab then
    return wget.actions.ABORT
  end

  set_item(url["url"])
  if not item_name then
    error("No item name found.")
  end

  if status_code >= 300 and status_code <= 399 then
    local newloc = urlparse.absolute(url["url"], http_stat["newloc"])
    if processed(newloc) or not allowed(newloc, url["url"]) then
      tries = 0
      return wget.actions.EXIT
    end
  end

  if seen_200[url["url"]] then
    print("Received data incomplete.")
    abort_item()
    return wget.actions.EXIT
  end

  if abortgrab then
    abort_item()
    return wget.actions.EXIT
  end

  if status_code == 0 or retry_url then
    io.stdout:write("Server returned bad response. ")
    io.stdout:flush()
    tries = tries + 1
    local maxtries = 6
    if status_code == 404 then
      maxtries = 0
    end
    if tries > maxtries then
      io.stdout:write(" Skipping.\n")
      io.stdout:flush()
      tries = 0
      abort_item()
      return wget.actions.EXIT
    end
    local sleep_time = math.random(
      math.floor(math.pow(2, tries-0.5)),
      math.floor(math.pow(2, tries))
    )
    io.stdout:write("Sleeping " .. sleep_time .. " seconds.\n")
    io.stdout:flush()
    os.execute("sleep " .. sleep_time)
    return wget.actions.CONTINUE
  else
    if status_code == 200 then
      seen_200[url["url"]] = true
    end
    downloaded[url["url"]] = true
  end

  tries = 0

  return wget.actions.NOTHING
end

wget.callbacks.finish = function(start_time, end_time, wall_time, numurls, total_downloaded_bytes, total_download_time)
  local function submit_backfeed(items, key)
    local tries = 0
    local maxtries = 5
    while tries < maxtries do
      if killgrab then
        return false
      end
      local body, code, headers, status = http.request(
        "https://legacy-api.arpa.li/backfeed/legacy/" .. key,
        items .. "\0"
      )
      if code == 200 and body ~= nil and cjson.decode(body)["status_code"] == 200 then
        io.stdout:write(string.match(body, "^(.-)%s*$") .. "\n")
        io.stdout:flush()
        return nil
      end
      io.stdout:write("Failed to submit discovered URLs." .. tostring(code) .. tostring(body) .. "\n")
      io.stdout:flush()
      os.execute("sleep " .. math.floor(math.pow(2, tries)))
      tries = tries + 1
    end
    kill_grab()
    error()
  end

  local file = io.open(item_dir .. "/" .. warc_file_base .. "_bad-items.txt", "w")
  for url, _ in pairs(bad_items) do
    file:write(url .. "\n")
  end
  file:close()
  for key, data in pairs({
    ["taringa-a8tqqypzt1kszz7y"] = discovered_items,
    ["urls-lmcom49fobarf4wy"] = discovered_outlinks
  }) do
    print('queuing for', string.match(key, "^(.+)%-"))
    local items = nil
    local count = 0
    for item, _ in pairs(data) do
      print("found item", item)
      if items == nil then
        items = item
      else
        items = items .. "\0" .. item
      end
      count = count + 1
      if count == 100 then
        submit_backfeed(items, key)
        items = nil
        count = 0
      end
    end
    if items ~= nil then
      submit_backfeed(items, key)
    end
  end
end

wget.callbacks.before_exit = function(exit_status, exit_status_string)
  if killgrab then
    return wget.exits.IO_FAIL
  end
  if abortgrab then
    abort_item()
  end
  return exit_status
end



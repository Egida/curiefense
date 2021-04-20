module(..., package.seeall)

local acl           = require "lua.acl"
local waf           = require "lua.waf"
local globals       = require "lua.globals"
local utils         = require "lua.utils"
local tagprofiler   = require "lua.tagprofiler"
local flowcontrol   = require "lua.flowcontrol"
local restysha1     = require "lua.resty.sha1"
local limit         = require "lua.limit"
local accesslog     = require "lua.accesslog"
local challenge     = require "lua.challenge"
local utils         = require "lua.utils"

local curiefense  = require "curiefense"


local cjson       = require "cjson"

local init          = globals.init

local waf_check         = waf.check
local acl_check         = acl.check
local acl_check_bot     = acl.check_bot
local limit_check       = limit.check
local flowcontrol_check = flowcontrol.check

local ACLNoMatch    = globals.ACLNoMatch
local ACLForceDeny  = globals.ACLForceDeny
local ACLBypass     = globals.ACLBypass
local ACLAllowBot   = globals.ACLAllowBot
local ACLDenyBot    = globals.ACLDenyBot
local ACLAllow      = globals.ACLAllow
local ACLDeny       = globals.ACLDeny

local WAFPass       = globals.WAFPass
local WAFBlock      = globals.WAFBlock

local re_match      = utils.re_match
local map_request   = utils.map_request
local tag_request   = utils.tag_request
local deny_request  = utils.deny_request
local custom_response  = utils.custom_response

local tag_lists     = tagprofiler.tag_lists

local log_request   = accesslog.log_request

local challenge_verified = challenge.verified
local challenge_phase01 = challenge.phase01
local challenge_phase02 = challenge.phase02

local sfmt = string.format

function match_urlmap(host, url, request_map)
    local default_map = nil
    local selected_map = nil
    local matched_path = "/"
    local handle = request_map.handle

    for _, profile in pairs(globals.URLMap) do
        if profile.match == "__default__" then
            default_map = profile
        else
            -- handle:logDebug(sfmt("URLMap - try %s with %s", host, profile.match))
            if re_match(host, profile.match) then
                -- handle:logInfo(sfmt("URLMap matched with: %s", profile.match))
                selected_map = profile
                break
            end
        end
    end

    if not selected_map then
        selected_map = default_map
    end

    for _, map_entry in ipairs(selected_map.map) do
        local path = map_entry.match
        if re_match(url, path) then
            if path:len() > matched_path:len() then
                matched_path = path
            end
        end
    end

    for _, map_entry in ipairs(selected_map.map) do
        if matched_path == map_entry.match then
            return map_entry, selected_map
        end
    end

    return default_map.map[1], default_map

end


function internal_url(url)
    return false
end

function print_request_map(request_map)
    for _, entry in ipairs({"headers", "cookies", "args", "attrs"}) do
        for k,v in pairs(request_map[entry]) do
            -- request_map.handle:logDebug(sfmt("%s: %s\t%s", entry, k, v))
        end
    end
end

function map_tags(request_map, urlmap_name, urlmapentry_name, acl_id, acl_name, waf_id, waf_name)

    tag_request(request_map, {
        "all",
        "curieaccesslog",
        globals.ContainerID,
        acl_id,
        acl_name,
        waf_id,
        waf_name,
        urlmap_name,
        urlmapentry_name,
        sfmt("ip:%s", request_map.attrs.ip),
        sfmt("geo:%s", request_map.geo.country.name),
        -- TODO: add city as tags
        sfmt("asn:%s", request_map.geo.asn)
    })

end

local gettime = socket.gettime

-- function addentry(t, msg)
--     table.insert(t, {gettime()*1000, msg})
-- end



-------[[[ rust copy/ paste ]]]

function encode_request_map(request_map)
    local s_request_map = {
        headers = request_map.headers,
        cookies = request_map.cookies,
        attrs = request_map.attrs,
        args = request_map.args,
        geo = request_map.geo
    }

    return cjson.encode(s_request_map)

end

function rust_session_clean( session_uuid )
    if session_uuid then
        curiefense.session_clean(session_uuid)
        session_uuid = nil
    end
end

-------[[[ rust copy/ paste ]]]



function inspect(handle)

    local timeline = {}
    init(handle)
    local request_map = map_request(handle)
    local request_map_as_json = encode_request_map(request_map)
    local response, err = curiefense.inspect_request_map(request_map_as_json, grasshopper)
    if err then
        for _, r in ipairs(err) do
            handle:logErr(sfmt("curiefense.inspect_request_map error %s", r))
        end
    end
    if response then
        local response_table = cjson.decode(response)
        handle:logDebug("decision " .. response)
        request_map = response_table["request_map"]
        request_map.handle = handle
        if response_table["action"] == "custom_response" then
            custom_response(request_map, response_table["response"])
        end
    end
    log_request(request_map)

end


-- test related code
-- we can't directly call these functions from the test code because of side effects when imports are resolved

function get_acl_profile(acl_profile_id)
    return globals.ACLProfiles[acl_profile_id]
end

function get_waf_profile(waf_profile_id)
    return globals.WAFProfiles[waf_profile_id]
end

function global_init(handle)
    return init(handle)
end
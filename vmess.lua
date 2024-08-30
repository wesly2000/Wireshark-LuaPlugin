---
--- Generated by EmmyLua(https://github.com/EmmyLua)
--- Created by ylx.
--- DateTime: 2024/7/16 16:06
--- Version: 0.0.1
---

local tls_dissector = Dissector.get("tls")

local string_r = require('utils.string_r')

local debug_level = {
    DISABLED = 0,
    LEVEL_1  = 1,
    LEVEL_2  = 2
}

local DEBUG = debug_level.LEVEL_1

local default_settings =
{
    debug_level = DEBUG,
    ports = { 20332 },   -- the default TCP port for Trojan
    reassemble = true, -- whether we try reassembly or not
    info_text = true,  -- show our own Info column data or TCP defaults
    ports_in_info = true, -- show TCP ports in Info column
}

---
--- Search for a specific byte string in tvb. For example, given tvb = {01 16 03 03 22 A2 F0 16 03 03}
--- and string = 16 03 03, the return should be {2, 8} (Note that Lua starts with 1, not 0).
--- @param tvb, the buffer.
--- @param str, the target string for searching.
--- @return table the table that contains all the start positions for string in tvb.
---
local tvb_search_str

---
--- The wrapper function for tvb_search_string. It searches in tvb each string of the string table, and groups
--- the returns into a single table.
--- @param tvb, the buffer.
--- @param str_table, the string table.
--- @return table the table that contains all the returns of tvb_search_string.
---
local tvb_search_str_table

local print_search_group

---
--- Merge and sort (in ascending order) the search group into a single sequence.
---
local merge_search_group

local vmess = Proto("VMess", "VMess Protocol")
-- for some reason the protocol name is shown in UPPERCASE in Protocol column
-- (and in Proto.name), so let's define a string to override that
local PROTOCOL_NAME = "VMess"

local pf_request = ProtoField.bytes("vmess.request", "VMess Request")
local pf_auth = ProtoField.bytes("vmess.auth", "VMess Auth")
local pf_response_header = ProtoField.bytes("vmess.response_header", "VMess Response Header")
local pf_length = ProtoField.uint16("vmess.length", "Length")
local pf_payload = ProtoField.bytes("vmess.payload", "VMess Payload")

vmess.fields = {
    pf_request, pf_auth, pf_response_header, pf_length, pf_payload
}

local f_frame_number = Field.new("frame.number")
local f_tcp_payload = Field.new("tcp.payload")
local f_tcp_segment_data = Field.new("tcp.segment_data")


local TLS_signature = {
    CHANGE_CIPHER_SPEC="\x14\x03\x03",
    ALERT = "\x15\x03\x03",
    HANDSHAKE = "\x16\x03\x03",
    HANDSHAKE_LEGACY = "\x16\x03\x01",
    APPLICATION_DATA = "\x17\x03\x03"
}

local auth = "\xb0\xb2\x5c\xda\x68\x1c\x15\x53\x74\xb3\x5b\x5f\xcc\x3f\x81\xe7"

local function dissect_request(tvb, pktinfo, root)
    --- Currently, we do not dissect VMess request without decryption.
    local tree = root:add(vmess, tvb(0))
    pktinfo.cols.info = "VMess Request"
    local request_tree = tree:add(pf_request, tvb(0))
    request_tree:add(pf_auth, tvb(0, 16))
end

local function dissect_response(tvb, pktinfo, root)
    pktinfo.cols.info = "VMess Response"
    local tree = root:add(vmess, tvb(0))
    local response_tree = tree:add(pf_response_header, tvb(0, 38))
    tree:add(pf_length, tvb(38, 2))
    tree:add(pf_payload, tvb(40))

end

local function dissect_data(tvb, pktinfo, root)
    pktinfo.cols.info = "VMess Data"
    local tree = root:add(vmess, tvb(0))
    tree:add(pf_length, tvb(0, 2))
    tree:add(pf_payload, tvb(2))

    --local t = next_tvb(tvb)

end

function vmess.dissector(tvb, pktinfo, root)
    --if f_frame_number().value == 14 then
    --    io.write("Frame Number ", f_frame_number().value, ": ")
    --    print(string_r.tohex(tvb():string())) -- print nothing
    --    print(string_r.tohex(tvb:raw())) -- print the actual buffer content
    --end

    local is_request = false

    --if f_frame_number().value == 4 then
    --    print("Frame Number ", f_frame_number().value, ": , auth: ", string.tohex(tvb:raw()))
    --end

    if tvb:len() > 61 and string.sub(tvb:raw(), 1, 16) == auth then is_request = true end

    if is_request then
        dissect_request(tvb, pktinfo, root)
        return
    end

    if not is_request then
        --if f_frame_number().value == 51 then
        --    print("TVB: ", string.tohex(tvb:raw()))
        --end
        local is_response_header = false

        local search_group = tvb_search_str_table(tvb, TLS_signature)
        local merged_search_group = merge_search_group(search_group)

        if #merged_search_group > 0 and merged_search_group[1] == 40 then is_response_header = true end

        local chunk_offset, chunk_length, bytes_needed

        if is_response_header then
            chunk_offset = merged_search_group[1] - 2
        else
            chunk_offset = 0
        end

        chunk_length = tvb(chunk_offset, 2):int()

        if is_response_header then
            bytes_needed = chunk_length + 2 + 38
        else
            bytes_needed = chunk_length + 2
        end

        local bytes_provided = tvb:len()

        if bytes_provided < bytes_needed and default_settings.reassemble then
            pktinfo.desegment_offset = 0
            pktinfo.desegment_len = bytes_needed - bytes_provided
            -- This message should be overwritten by later dissection.
            pktinfo.cols.info = "[Partial VMess data, enable TCP subdissector reassembly]"
            return
        end

        if is_response_header then
            dissect_response(tvb, pktinfo, root)
        else
            dissect_data(tvb, pktinfo, root)
        end
    end
end

local function enableDissector()
    for _, port in ipairs(default_settings.ports) do
        --DissectorTable.get("tcp.port"):add(port, trojan)
        -- supports also TLS decryption if the session keys are configured in Wireshark
        DissectorTable.get("tcp.port"):add(port, vmess)
    end
end
-- call it now, because we're enabled by default
enableDissector()


-- register our preferences
vmess.prefs.reassemble = Pref.bool("Reassemble VMess messages spanning multiple TCP segments",
        default_settings.reassemble, "Whether the VMess dissector should reassemble messages " ..
                "spanning multiple TCP segments. To use this option, you must also enable \"Allow subdissectors to " ..
                "reassemble TCP streams\" in the TCP protocol settings")

vmess.prefs.info_text = Pref.bool("Show VMess protocol data in Info column",
        default_settings.info_text, "Disable this to show the default TCP protocol data in the Info column")

vmess.prefs.ports_in_info = Pref.bool("Show TCP ports in Info column",
        default_settings.ports_in_info, "Disable this to have only VMess data in the Info column")

-- the function for handling preferences being changed
function vmess.prefs_changed()
    if default_settings.reassemble ~= vmess.prefs.reassemble then
        default_settings.reassemble = vmess.prefs.reassemble
        -- capture file reload needed
        reload()
    elseif default_settings.info_text ~= vmess.prefs.info_text then
        default_settings.info_text = vmess.prefs.info_text
        -- capture file reload needed
        reload()
    elseif default_settings.ports_in_info ~= vmess.prefs.ports_in_info then
        default_settings.ports_in_info = vmess.prefs.ports_in_info
        -- capture file reload needed
        reload()
    elseif default_settings.ports ~= vmess.prefs.ports then
        disableDissector()
        default_settings.ports = vmess.prefs.ports
        enableDissector()
    end
end


tvb_search_str = function(tvb, str)
    --local tvb_string = tvb():string() -- tvb():string() may return an empty string for some unknown reason
    local tvb_string = tvb:raw() -- use raw instead.
    local tvb_firsts = {}
    local firsts, _ = string_r.find_all(tvb_string, str)
    if #firsts == 0 then
        return firsts
    end
    -- Since tvb begin with 0, each element in firsts should minus 1.
    for i = 1, #firsts do
        tvb_firsts[i] = firsts[i] - 1
    end
    return tvb_firsts
end

tvb_search_str_table = function(tvb, str_table)
    local search_group = {}
    for sig_name, sig_value in pairs(str_table) do
        local tvb_firsts = tvb_search_str(tvb, sig_value)
        search_group[sig_name] = tvb_firsts
    end
    return search_group
end

print_search_group = function(search_group)
    io.write("{")
    for k, v in pairs(search_group) do
        io.write(k, ": ")
        string_r.print_seq(v)
        io.write(", ")
    end
    io.write("}")
end

merge_search_group = function(search_group)
    local result = {}
    for _, v in pairs(search_group) do
        for _, s in ipairs(v) do
            result[#result + 1] = s
        end
    end
    table.sort(result)
    return result
end
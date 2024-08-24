---
--- Generated by EmmyLua(https://github.com/EmmyLua)
--- Created by ylx.
--- DateTime: 2024/7/6 11:33
--- Version: 0.0.2
---

--local coarseTLS12 = require('coarseTLS12')
--local coarseTLS13 = require('coarseTLS13')

-- do not modify this table
local debug_level = {
    DISABLED = 0,
    LEVEL_1  = 1,
    LEVEL_2  = 2
}

local DEBUG = debug_level.LEVEL_1

local GUARD = "\x0d\x0a" -- the guard bytes for locating Trojan bytes

local default_settings =
{
    debug_level = DEBUG,
    ports = { 45447, 23003, 433 },   -- the default TCP port for Trojan
    reassemble = true, -- whether we try reassembly or not
    info_text = true,  -- show our own Info column data or TCP defaults
    ports_in_info = true, -- show TCP ports in Info column
}

---
--- Check if an element belongs to a table
--- @param value, the value to check
--- @param table, the table to traverse
--- @return boolean if the table contains the value
---
local find_in_table

---
--- Find the length of Trojan Request. Note that
---   TrojanRequest=CMD+ATYP+DST.ADDR+DST.PORT
--- @param tvb, the buffer on which we find the guard bytes (x0d0a)
--- @return number the length of Trojan Request
---
local get_request_length

---
--- Print the content of a table to the given file
---
local print_table_to_file

---
--- Print Dissector.list() to the given file
---
local print_dissector_table_to_file


function string.tohex(str)
    return (str:gsub('.', function (c)
        return string.format('%02X', string.byte(c))
    end))
end



local trojan = Proto("Trojan", "Trojan Protocol")
-- for some reason the protocol name is shown in UPPERCASE in Protocol column
-- (and in Proto.name), so let's define a string to override that
local PROTOCOL_NAME = "Trojan"

local pf_passwd = ProtoField.bytes("trojan.passwd", "Trojan Password")

local pf_request = ProtoField.bytes("trojan.request", "Trojan Request")
local pf_cmd = ProtoField.uint8("trojan.cmd", "Trojan Command")
local pf_atype = ProtoField.uint8("trojan.atype", "Trojan Address Type")
local pf_dst_addr = ProtoField.string("trojan.dst_addr", "Trojan Destination Address")
local pf_dst_port = ProtoField.uint16("trojan.dst_port", "Trojan Destination Port")
local pf_payload = ProtoField.bytes("trojan.payload", "Trojan Payload")

local pf_tunnel_data = ProtoField.bytes("trojan.tunnel_data", "Trojan Tunneled Data")
local pf_tunnel_TLS = ProtoField.bytes("trojan.tunnel_data.tunnel_tls", "Tunneled TLS")
local pf_TLS_content_type = ProtoField.uint8("trojan.tls_content_type", "Content Type")
local pf_TLS_app_data = ProtoField.bytes("trojan.tls_app_data", "Application Data")


trojan.fields = {
    pf_passwd, pf_tunnel_data, pf_request, pf_cmd, pf_atype, pf_dst_addr,
    pf_dst_port, pf_payload
}

local f_tls_content_type = Field.new("tls.record.content_type")
local f_data = Field.new("data.data")
local f_http_content_length = Field.new("http.content_length")

local function doDissect(tvb, pktinfo, root)
    -- Application Data packet has been encountered. The following Application Data
    -- packets are handled as tunneled packets.

    -- ############################################################
    -- # Passwd(56B) # X0D0A # CMD(1B) # ATYP(1B) # DST.ADDR(VAR) #
    -- ############################################################
    -- # DST.PORT(2B) # X0D0A #            Payload(VAR)           #
    -- ############################################################
    -- local frame_num = f_frame_num().value

    local info_text

    if tvb:len() > 64 and
            (tvb(56, 2):string() == GUARD) and
            (tvb(58, 1):int() == 1) then
        root:add(pf_passwd, tvb(0, 56))

        --print(string.tohex(tvb(0):string()))
        local remaining_tvb = tvb(58)
        local request_length = get_request_length(remaining_tvb)
        local request_tree = root:add(pf_request, remaining_tvb(0, request_length))
        request_tree:add(pf_cmd, remaining_tvb(0, 1))
        request_tree:add(pf_atype, remaining_tvb(1, 1))
        -- Before URL, it seems that there is a special byte.
        request_tree:add(pf_dst_addr, remaining_tvb(3, request_length - 7))
        request_tree:add(pf_dst_port, remaining_tvb(request_length - 4, 2))
        --request_tree:add(pf_payload, remaining_tvb(request_length))

        pktinfo.cols.info = "Trojan Request"

        --print("Frame: .." .. frame_num .. " Request Length: " .. request_length)
    else
        -- Inner payload is actually the tunneled TLS packet.

        local tunnel_tree = root:add(pf_tunnel_data, tvb(0))
        pktinfo.cols.info = "Trojan Tunneled Data "

        local save_port_type = pktinfo.port_type
        pktinfo.port_type = _EPAN.PT_NONE
        local save_can_desegment = pktinfo.can_desegment
        pktinfo.can_desegment = 2
        Dissector.get("tls"):call(tvb, pktinfo, tunnel_tree)

        ---
        --- The following code chunk
        ---     can't reassemble HTTP/2 conversation, only the header MAGIC will be recognized properly
        ---     can't recognize HTTP/1.1 response
        ---

        if f_data() ~= nil then
            local data_tvb = f_data().range:tvb()
            local app_tree = tunnel_tree:add(pf_TLS_app_data, data_tvb)
            local save_inner_port_type = pktinfo.port_type
            pktinfo.port_type = _EPAN.PT_SCTP
            local save_inner_can_desegment = pktinfo.can_desegment
            pktinfo.can_desegment = 2
            Dissector.get("http"):call(data_tvb, pktinfo, app_tree)
        end

        pktinfo.port_type = save_port_type
        pktinfo.can_desegment = save_can_desegment

        ---
        --- The following code chunk gives many Continuation on HTTP/1.1

        --if f_data() ~= nil then
        --    local data_tvb = f_data().range:tvb()
        --    local app_tree = tunnel_tree:add(pf_TLS_app_data, data_tvb)
        --    Dissector.get("http"):call(data_tvb, pktinfo, app_tree)
        --end


        ---
        --- The following code chunk gives
        ---     many Continuation on HTTP/1.1
        ---     many Ignored Unknown Record or Malformed Frame on HTTP/2
        ---
        --Dissector.get("http"):call(tvb, pktinfo, tunnel_tree)

        ---
        --- If we call built-in TLS dissector upon tunneled data, Wireshark
        --- only recognizes the Handshake messages, and fails to recognize
        --- Application Data. Furthermore, it fails to decrypt the outer TLS shell,
        --- which ruins the whole dissection structure built previously.
        --- Two ways for handling this:
        ---     1. Inspect the heuristic call stack of TLS, and find why this strange
        ---        behaviour incurs.
        ---     2. Create a customized coarse-grained TLS dissector. Since we only need
        ---        to understand some of the TLS content when deal with Trojan traffic.
        ---     3. Export the inner payload as EXPORTED_PDU, and re-dissect the export
        ---        PDU files.
        --- Currently, I'm struggling with 3.
        ---
        --- TLS 1.2 handling routine
        --- TODO: Implement coarse-grained TLS 1.2 dissector.
        ---

        --- TLS 1.3 handling routine
        --- TODO: Implement coarse-grained TLS 1.3 dissector.
        ---

        --print("Frame: .." .. frame_num .. " Segment Data Length: " .. tvb:len() .. " TVB Length: " .. tvb(0):tvb():len())
    end


end

function trojan.dissector(tvb, pktinfo, root)

    --- ################ Trojan Check ###############
    --- ################    TCP Check   ###############

    --- In regular routine, TCP Check is disabled.

    --- ################ TCP Check End  ###############
    --- ################   TLS Check    ###############

    -- If the packet is a not a TLS packet, skip.

    -- Use fieldInfo.value to fetch the value of the field. For MyTrojan, only
    -- Application Data (content_type == 23) records need to be handled.
    if f_tls_content_type() == nil or f_tls_content_type().value ~= 23 then
        return 0
    end

    --local frame_num = f_frame_num().value

    --- ################ TLS Check End  ###############
    --- ################ Trojan Check End ###############

    pktinfo.cols.protocol:set(PROTOCOL_NAME)

    local tree = root:add(trojan, tvb)
    -- set the default text for Info column, it will be overridden later if possible
    if default_settings.info_text then
        pktinfo.cols.info = "Trojan data"
    end

    doDissect(tvb, pktinfo, tree)

end

--- Due to TLS-ALPN, the Upgrade mechanism of HTTP will force Wireshark to trigger
--- HTTP/2 (HTTP/1.1) heuristic dissector for Trojan dissection. Therefore, it seems
--- that regular MyTrojan dissector registration (i.e., through add port to TCP/TLS
--- DissectorTable) will be overridden by HTTP dissectors (the dissector written in
--- C would have similar effect).
--- Moreover, it seems that such behaviour would not be affected by disabling HTTP
--- protocol.
--- Therefore, instead of regular registration, we register the plugin as a post-dissector,
--- which handles the lower layer data when all built-in dissectors are applied.

---
--- UPDATE: The default heuristic HTTP dissectors could be disabled by commenting the following
--- lines of epan/dissectors/packet-http2.c:
---     dissector_add_string("tls.alpn", "h2", http2_handle);
---     dissector_add_string("http.upgrade", "h2", http2_handle);
---     dissector_add_string("http.upgrade", "h2c", http2_handle);
---     heur_dissector_add("tls", dissect_http2_heur_ssl, "HTTP2 over TLS", "http2_tls", proto_http2, HEURISTIC_ENABLE);
--- and rebuild the source. Even upon inspecting 'h2' or 'http/1.1' in Client Hello, the
--- relevant HTTP-family dissectors should not be triggered.
---
--- Therefore, we could get rid of register_postdissector and use the regular registering
--- routine.
---

--register_postdissector(trojan)

local function enableDissector()
    for _, port in ipairs(default_settings.ports) do
        --DissectorTable.get("tcp.port"):add(port, trojan)
        -- supports also TLS decryption if the session keys are configured in Wireshark
        DissectorTable.get("tls.port"):add(port, trojan)
        DissectorTable.get("tls.alpn"):add("h2", trojan)
        DissectorTable.get("tls.alpn"):add("http/1.1", trojan)
    end
end
-- call it now, because we're enabled by default
enableDissector()


print_table_to_file = function (table, filename, mode)
    local file
    if mode == nil then
        file = io.open(filename, 'w')
    else
        file = io.open(filename, mode)
    end

    for _, v in ipairs(table) do
        print(v)
        file:write(v .. "\n")
    end

    file:close()
end

print_dissector_table_to_file = function(filename, mode)
    print_table_to_file(Dissector:list(), filename, mode)
end

find_in_table = function (value, table)
    for _, v in ipairs(table) do
        if v == value then
            return true
        end
    end
    return false
end

get_request_length =  function (tvb)
    local begin, _ = string.find(tvb:string(), GUARD)
    --print(string.tohex(tvb:string()))
    --print(begin)
    return begin - 1
end

---
--- Using this to get all the dissector registered in Wireshark and save it
--- for later usage (since calling Dissector:list() is an expensive operation).
---
--print_dissector_table_to_file("Dissector.txt")

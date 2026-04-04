local json = require("json")
local pollnet = require("pollnet")
local np = require("noitapatcher")
local ffi = require("ffi")

ffi.cdef([[
void* GetModuleHandleA(const char*);
]])
local base = ffi.cast("size_t", ffi.C.GetModuleHandleA(nil))


local function StartNewRun()
	GameAddFlagRun("pause_game_bingo")
	np.SetPauseState(4)
end


local imgui = nil
if load_imgui then
    local ok, result = pcall(load_imgui, { mod = "evaisa.bingo", version = "1.0.0" })
    if ok then imgui = result end
end

local TEAM_COLORS = {
    { r = 0.86, g = 0.20, b = 0.20 },
    { r = 0.20, g = 0.39, b = 0.86 },
    { r = 0.20, g = 0.78, b = 0.31 },
    { r = 0.86, g = 0.78, b = 0.20 },
    { r = 0.70, g = 0.20, b = 0.86 },
    { r = 0.86, g = 0.51, b = 0.20 },
    { r = 0.20, g = 0.78, b = 0.82 },
    { r = 0.86, g = 0.20, b = 0.59 },
}

local TEAM_NAMES = { "Red", "Blue", "Green", "Yellow", "Purple", "Orange", "Cyan", "Pink" }

local SERVER_URL = "ws://localhost:7860"

local b = {}

b.phase = "disconnected"
b.ws = nil
b.connect_error = nil
b.pending_action = nil

b.player_id = tostring(ModSettingGet("bingo_player_id") or "")
b.player_name = tostring(ModSettingGet("bingo_player_name") or "Player")
b.saved_lobby_code = tostring(ModSettingGet("bingo_lobby_code") or "")

b.lobby = nil

b.ui_name_input = b.player_name
b.ui_code_input = ""

b.current_seed = nil
b.run_start_time = nil
b.playing_cell = nil

b.notification = nil
b.notification_timer = 0

b.win_info = nil

local function team_color(team_idx)
    if type(team_idx) ~= "number" then return { r = 0.18, g = 0.18, b = 0.22 } end
    local c = TEAM_COLORS[(team_idx % #TEAM_COLORS) + 1]
    return c or { r = 0.18, g = 0.18, b = 0.22 }
end

local function team_name(team_idx)
    if type(team_idx) ~= "number" then return "None" end
    return TEAM_NAMES[(team_idx % #TEAM_NAMES) + 1] or ("Team " .. tostring(team_idx + 1))
end

local function fmt_ms(ms)
    if type(ms) ~= "number" then return "--:--" end
    local s_total = math.floor(ms / 1000)
    local m = math.floor(s_total / 60)
    local s = s_total % 60
    local cs = math.floor((ms % 1000) / 10)
    return string.format("%d:%02d.%02d", m, s, cs)
end

local function send_msg(t)
    if b.ws and b.ws:status() == "open" then
        b.ws:send(json.stringify(t))
    end
end

local function set_notif(msg)
    b.notification = msg
    b.notification_timer = 240
end

local function disconnect()
    if b.ws then
        b.ws:close()
        b.ws = nil
    end
    b.lobby = nil
    b.phase = "disconnected"
    b.connect_error = nil
    b.pending_action = nil
    ModSettingSet("bingo_lobby_code", "")
    b.saved_lobby_code = ""
end

local function on_connected()
    if b.pending_action then
        local action = b.pending_action
        b.pending_action = nil
        action()
    else
        b.phase = "lobby_select"
    end
end

local function connect_then(action)
    disconnect()
    b.phase = "connecting"
    b.connect_error = nil
    b.ws = pollnet.open_ws(SERVER_URL)
    b.pending_action = action
end

local function get_or_create_id()
    if b.player_id and b.player_id ~= "" then return b.player_id end
    local id = pollnet.nanoid()
    b.player_id = id
    ModSettingSet("bingo_player_id", id)
    return id
end

local function do_create()
    send_msg({ type = "create_lobby", player_id = get_or_create_id(), player_name = b.player_name })
end

local function do_join(code)
    send_msg({ type = "join_lobby", code = code, player_id = get_or_create_id(), player_name = b.player_name })
end

local function process_msg(raw)
    local ok, msg = pcall(json.parse, raw)
    if not ok or type(msg) ~= "table" then return end

    if msg.type == "joined" then
        b.player_id = msg.player_id
        ModSettingSet("bingo_player_id", msg.player_id)
        ModSettingSet("bingo_lobby_code", msg.lobby.code)
        b.saved_lobby_code = msg.lobby.code
        b.lobby = msg.lobby
        if b.lobby.state == "in_game" then
            b.phase = "in_game"
        elseif b.lobby.state == "finished" then
            b.phase = "game_over"
        else
            b.phase = "in_lobby"
        end

    elseif msg.type == "lobby_state" then
        b.lobby = msg.lobby
        if b.lobby.state == "in_game" and b.phase == "in_lobby" then
            b.phase = "in_game"
        elseif b.lobby.state == "finished" and b.phase ~= "game_over" then
            b.phase = "game_over"
        end

    elseif msg.type == "game_started" then
        b.lobby = msg.lobby
        b.phase = "in_game"
        b.win_info = nil
        local player = get_player()
        if player and player ~= 0 then
            EntityKill(player)
        end
        set_notif("Game started! You have been killed. Start a new run to begin playing!")

    elseif msg.type == "cell_updated" then
        if b.lobby and b.lobby.board then
            local cell = b.lobby.board[msg.cell_index + 1]
            if cell then
                cell.owner_team = msg.cell.owner_team
                cell.best_time = msg.cell.best_time
                cell.best_player = msg.cell.best_player
            end
        end

    elseif msg.type == "bingo_win" then
        b.lobby = msg.lobby
        b.phase = "game_over"
        b.win_info = {
            team = msg.team,
            team_name = msg.team_name,
            winning_line = msg.winning_line or {},
        }
        set_notif(string.format("BINGO! Team %s wins!", tostring(msg.team_name or "?")))

    elseif msg.type == "error" then
        b.connect_error = msg.message
        set_notif("Server: " .. tostring(msg.message or "error"))
    end
end

local function poll_network()
    if not b.ws then return end

    local ok, msg = b.ws:poll()
    local status = b.ws:status()

    if b.phase == "connecting" then
        if status == "open" then
            b.phase = "lobby_select"
            on_connected()
        elseif status == "error" then
            b.connect_error = "Could not connect to " .. SERVER_URL
            b.phase = "disconnected"
            b.ws = nil
        end
        return
    end

    if not ok then
        if status == "error" or status == "closed" then
            b.connect_error = "Connection lost"
            b.phase = "disconnected"
            b.ws = nil
            b.lobby = nil
        end
        return
    end

    if msg and msg ~= "" then
        process_msg(msg)
    end
end

local function in_winning_line(cell_1based)
    if not b.win_info or not b.win_info.winning_line then return false end
    for _, v in ipairs(b.win_info.winning_line) do
        if v + 1 == cell_1based then return true end
    end
    return false
end

local function push_team_button_colors(tc, mul)
    mul = mul or 1.0
    imgui.PushStyleColor(imgui.Col.Button,        tc.r * mul * 0.8, tc.g * mul * 0.8, tc.b * mul * 0.8, 1.0)
    imgui.PushStyleColor(imgui.Col.ButtonHovered, tc.r * mul,       tc.g * mul,       tc.b * mul,       1.0)
    imgui.PushStyleColor(imgui.Col.ButtonActive,  tc.r * mul * 1.1, tc.g * mul * 1.1, tc.b * mul * 1.1, 1.0)
end

local function draw_connect_screen()
    imgui.SetNextWindowPos(100, 100, imgui.Cond.FirstUseEver)
    imgui.SetNextWindowSize(440, 220, imgui.Cond.FirstUseEver)
    local vis = imgui.Begin("Speedrunner Bingo")
    if not vis then imgui.End() return end

    imgui.Text("Your Name ")
    imgui.SameLine()
    imgui.SetNextItemWidth(200)
    local pn_ch, pn_new = imgui.InputText("##pn", b.ui_name_input, 32)
    if pn_ch then
        b.ui_name_input = pn_new
        b.player_name = pn_new
        ModSettingSet("bingo_player_name", pn_new)
    end

    imgui.Separator()

    if b.phase == "connecting" then
        imgui.TextDisabled("Connecting...")
    else
        if imgui.Button("Create Lobby", 120, 0) then
            connect_then(do_create)
        end

        imgui.SameLine()
        imgui.SetNextItemWidth(140)
        local lc_ch, lc_new = imgui.InputText("##lcode", b.ui_code_input, 8)
        if lc_ch then b.ui_code_input = lc_new end

        imgui.SameLine()
        if imgui.Button("Join Lobby", 90, 0) then
            local code = (b.ui_code_input or ""):upper()
            if code ~= "" then
                connect_then(function() do_join(code) end)
            end
        end
    end

    if b.connect_error then
        imgui.PushStyleColor(imgui.Col.Text, 1.0, 0.35, 0.35, 1.0)
        imgui.TextWrapped(b.connect_error)
        imgui.PopStyleColor()
    end

    imgui.End()
end

local function draw_lobby_screen()
    if not b.lobby then return end
    local lobby = b.lobby
    local settings = lobby.settings or { teams = 2, grid_size = 5 }
    local players = lobby.players or {}
    local is_host = lobby.host_id == b.player_id

    imgui.SetNextWindowPos(100, 100, imgui.Cond.FirstUseEver)
    imgui.SetNextWindowSize(520, 560, imgui.Cond.FirstUseEver)
    local vis = imgui.Begin("Bingo Lobby")
    if not vis then imgui.End() return end

    imgui.Text("Lobby Code: ")
    imgui.SameLine()
    imgui.PushStyleColor(imgui.Col.Text, 0.4, 1.0, 0.4, 1.0)
    imgui.Text(lobby.code)
    imgui.PopStyleColor()
    imgui.SameLine()
    if imgui.Button("Copy##cpcode") then
        imgui.SetClipboardText(lobby.code)
    end
    imgui.SameLine()
    if imgui.Button("Leave") then
        send_msg({ type = "leave_lobby" })
        disconnect()
    end

    imgui.Separator()

    if is_host then
        imgui.Text("Settings")
        imgui.SetNextItemWidth(100)
        local tc_ch, tc_new = imgui.InputInt("Teams (2-8)", settings.teams)
        if tc_ch then
            tc_new = math.max(2, math.min(8, tc_new))
            if tc_new ~= settings.teams then
                send_msg({ type = "update_settings", teams = tc_new, grid_size = settings.grid_size })
            end
        end
        imgui.SetNextItemWidth(100)
        local gs_ch, gs_new = imgui.InputInt("Grid Size (3-7)", settings.grid_size)
        if gs_ch then
            gs_new = math.max(3, math.min(7, gs_new))
            if gs_new ~= settings.grid_size then
                send_msg({ type = "update_settings", teams = settings.teams, grid_size = gs_new })
            end
        end
    else
        imgui.Text(string.format("Teams: %d   Grid: %dx%d", settings.teams, settings.grid_size, settings.grid_size))
    end

    imgui.Separator()

    local my_team = nil
    for _, p in ipairs(players) do
        if p.id == b.player_id then my_team = p.team break end
    end

    for ti = 0, settings.teams - 1 do
        local tc = team_color(ti)
        local tn = team_name(ti)
        local btn_label = (my_team == ti) and (tn .. "##jt" .. ti) or (tn .. " [join]##jt" .. ti)

        push_team_button_colors(tc)
        if imgui.Button(btn_label) then
            send_msg({ type = "move_player", player_id = b.player_id, team = ti })
        end
        imgui.PopStyleColor(3)

        local any = false
        for _, p in ipairs(players) do
            if p.team == ti then
                any = true
                local label = "  " .. p.name
                if p.id == b.player_id then label = label .. " (you)" end
                if p.id == lobby.host_id then label = label .. " [host]" end
                imgui.Text(label)
                if is_host and p.id ~= b.player_id then
                    for mt = 0, settings.teams - 1 do
                        if mt ~= ti then
                            local mc = team_color(mt)
                            local mn = team_name(mt)
                            push_team_button_colors(mc)
                            if imgui.Button("->" .. mn .. "##mv" .. p.id .. tostring(mt)) then
                                send_msg({ type = "move_player", player_id = p.id, team = mt })
                            end
                            imgui.PopStyleColor(3)
                            imgui.SameLine()
                        end
                    end
                    imgui.NewLine()
                end
            end
        end
        if not any then
            imgui.TextDisabled("  (empty)")
        end
    end

    imgui.Separator()

    if is_host then
        imgui.PushStyleColor(imgui.Col.Button,        0.15, 0.65, 0.15, 1.0)
        imgui.PushStyleColor(imgui.Col.ButtonHovered, 0.20, 0.85, 0.20, 1.0)
        imgui.PushStyleColor(imgui.Col.ButtonActive,  0.10, 0.50, 0.10, 1.0)
        if imgui.Button("Start Game!", 180, 36) then
            send_msg({ type = "start_game" })
        end
        imgui.PopStyleColor(3)
    else
        imgui.TextDisabled("Waiting for host to start the game...")
    end

    if b.notification and b.notification_timer > 0 then
        imgui.PushStyleColor(imgui.Col.Text, 0.9, 0.9, 0.2, 1.0)
        imgui.TextWrapped(b.notification)
        imgui.PopStyleColor()
    end

    imgui.End()
end

local function draw_game_screen()
    if not b.lobby or not b.lobby.board then return end
    local lobby = b.lobby
    local board = lobby.board
    local settings = lobby.settings or { teams = 2, grid_size = 5 }
    local grid = settings.grid_size or 5
    local teams = lobby.teams or {}
    local game_over = b.phase == "game_over"

    local cell_w = 108
    local cell_h = 108
    local win_w = grid * (cell_w + 8) + 28
    local win_h = grid * (cell_h + 8) + 160

    imgui.SetNextWindowPos(80, 60, imgui.Cond.FirstUseEver)
    imgui.SetNextWindowSize(win_w, win_h, imgui.Cond.FirstUseEver)
    local vis = imgui.Begin("Bingo Board")
    if not vis then imgui.End() return end

    if b.win_info then
        local wc = team_color(b.win_info.team)
        imgui.PushStyleColor(imgui.Col.Text, wc.r, wc.g, wc.b, 1.0)
        imgui.Text(string.format("*** BINGO! Team %s wins! ***", b.win_info.team_name or "?"))
        imgui.PopStyleColor()
        imgui.Separator()
    end

    if b.notification and b.notification_timer > 0 then
        imgui.PushStyleColor(imgui.Col.Text, 0.9, 0.9, 0.2, 1.0)
        imgui.TextWrapped(b.notification)
        imgui.PopStyleColor()
    end

    imgui.Separator()

    for row = 0, grid - 1 do
        for col = 0, grid - 1 do
            local idx = row * grid + col + 1
            local cell = board[idx]

            if not cell then
                imgui.Button("???##emptycell" .. idx, cell_w, cell_h)
            else
                local has_owner = type(cell.owner_team) == "number"
                local in_line = in_winning_line(idx)
                local is_active = b.playing_cell == idx - 1
                local tc = has_owner and team_color(cell.owner_team) or { r = 0.15, g = 0.15, b = 0.20 }
                local bt_m = has_owner and (in_line and 1.3 or 0.75) or 0.9
                local hv_m = has_owner and (in_line and 1.5 or 0.95) or 1.15

                imgui.PushStyleColor(imgui.Col.Button,        tc.r * bt_m, tc.g * bt_m, tc.b * bt_m, 1.0)
                imgui.PushStyleColor(imgui.Col.ButtonHovered, tc.r * hv_m, tc.g * hv_m, tc.b * hv_m, 1.0)
                imgui.PushStyleColor(imgui.Col.ButtonActive,  tc.r,        tc.g,        tc.b,        1.0)

                if is_active then
                    imgui.PushStyleColor(imgui.Col.Border, 1.0, 1.0, 1.0, 1.0)
                    imgui.PushStyleVar(imgui.StyleVar.FrameBorderSize, 3)
                end

                local seed_str = tostring(cell.seed or "?")
                local btime = type(cell.best_time) == "number" and cell.best_time or nil
                local time_str = fmt_ms(btime)
                local btn_label = seed_str .. "\n" .. time_str .. "##cell" .. idx

                if imgui.Button(btn_label, cell_w, cell_h) then
                    if not game_over and cell.seed then
                        SetWorldSeed(cell.seed)
                        b.playing_cell = idx - 1
						print("Seed now is: "..(ModSettingGet("bingo_next_seed") or "nil"))
						StartNewRun()
					end
                end

                if is_active then
                    imgui.PopStyleVar()
                    imgui.PopStyleColor()
                end

                imgui.PopStyleColor(3)
            end

            if col < grid - 1 then imgui.SameLine() end
        end
    end

    imgui.Separator()

    for _, team in ipairs(teams) do
        local tc = team_color(team.index)
        local owned = 0
        for _, cell in ipairs(board) do
            if type(cell.owner_team) == "number" and cell.owner_team == team.index then
                owned = owned + 1
            end
        end
        imgui.PushStyleColor(imgui.Col.Text, tc.r, tc.g, tc.b, 1.0)
        imgui.Text(string.format("[%s: %d]  ", team.name, owned))
        imgui.PopStyleColor()
        imgui.SameLine()
    end
    imgui.NewLine()

    imgui.End()
end

function b.draw_ui()
    if not imgui then return end
    local phase = b.phase
    if phase == "disconnected" or phase == "connecting" or phase == "lobby_select" then
        draw_connect_screen()
    elseif phase == "in_lobby" then
        draw_lobby_screen()
    elseif phase == "in_game" or phase == "game_over" then
        draw_game_screen()
    end
end

function b.update()
    poll_network()

    if b.notification_timer > 0 then b.notification_timer = b.notification_timer - 1 end

    b.draw_ui()
end

function b.on_magic_seed_init()
    local seed = tonumber(StatsGetValue("world_seed"))
    print("[bingo] on_magic_seed_init world_seed=" .. tostring(seed) .. " bingo_next_seed=" .. tostring(ModSettingGet("bingo_next_seed")))
    b.current_seed = seed
    b.run_start_time = GameGetRealWorldTimeSinceStarted()
    b.playing_cell = nil

    if b.lobby and b.lobby.board then
        for i, cell in ipairs(b.lobby.board) do
            if cell.seed == seed then
                print("[bingo] matched board cell " .. tostring(i-1) .. " seed=" .. tostring(cell.seed))
                b.playing_cell = i - 1
                break
            end
        end
    else
        print("[bingo] no lobby/board available at seed init")
    end
    print("[bingo] final playing_cell=" .. tostring(b.playing_cell))
end

function b.on_player_died()
    if GameHasFlagRun("ending_game_completed") then
        if b.playing_cell ~= nil and b.run_start_time ~= nil then
            local elapsed = GameGetRealWorldTimeSinceStarted() - b.run_start_time
            if elapsed > 0 then
                send_msg({
                    type = "submit_time",
                    cell_index = b.playing_cell,
                    time_ms = math.floor(elapsed),
                })
            end
        end
        b.playing_cell = nil
        b.run_start_time = nil
    end
end

b.OnPausePreUpdate = function()
	if GameHasFlagRun("pause_game_bingo") and not GameHasFlagRun("pause_game_bingo_done") then
		GameAddFlagRun("pause_game_bingo_done")
		print("Forced bingo pause state")

		ffi.cast("int*", 0x0120761c)[0] = 0 -- game mode nr
		require("ffi").cast("void(__fastcall*)()", base + 0x005a2d70)()
	end
end


if b.saved_lobby_code and b.saved_lobby_code ~= "" and b.player_id and b.player_id ~= "" then
    local code = b.saved_lobby_code
    connect_then(function() do_join(code) end)
end

return b

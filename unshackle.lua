local bingo = dofile("mods/evaisa.bingo/files/bingo.lua")
function get_player()
	local player_entities = EntityGetWithTag("player_unit")
	if player_entities and #player_entities > 0 then
		return player_entities[1]
	end
end

function DoesLobbyExist( lobby_id )
	return true
end

function GetCurrentLobbyID()
	return tostring(ModSettingGet("bingo_lobby_id") or 0)
end

function SetWorldSeed( seed )
	print("[bingo] SetWorldSeed called with: " .. tostring(seed))
	ModSettingSet("bingo_next_seed", tostring(seed))
	ModSettingSetNextValue("bingo_next_seed", tostring(seed), false)
end

function OnModPostInit()
	local seed = ModSettingGet("bingo_next_seed")
	print("[bingo] OnModPostInit, bingo_next_seed = " .. tostring(seed))
	if seed and tostring(seed) ~= "" then
		local content = '<MagicNumbers _DEBUG_DONT_SAVE_MAGIC_NUMBERS="1" WORLD_SEED="' .. tostring(seed) .. '"/>'
		print("[bingo] writing worldseed.xml: " .. content)
		ModTextFileSetContent("mods/evaisa.bingo/worldseed.xml", content)
		ModMagicNumbersFileAdd("mods/evaisa.bingo/worldseed.xml")
	end
end

function OnMagicNumbersAndWorldSeedInitialized()
	bingo.on_magic_seed_init()
end

function OnWorldPostUpdate()
	bingo.update()
end

function OnPausePreUpdate()
	bingo.draw_ui()
end

function OnPlayerDied( player_entity )
	bingo.on_player_died()
end

function OnPausePreUpdate()
	bingo.OnPausePreUpdate()
end
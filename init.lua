local gui = GuiCreate()

local function draw_centered_banner(gui, text, r, g, b_color)
    local sw, sh = GuiGetScreenDimensions(gui)
    GuiBeginAutoBox(gui)
	GuiZSetForNextWidget(gui, -10000)
    local tw, th = GuiGetTextDimensions(gui, text, 1, 2, "data/fonts/font_pixel_huge.xml")
    local x = (sw - tw) * 0.5
    local y = sh * 0.2
    GuiColorSetForNextWidget(gui, r, g, b_color, 1.0)
    GuiText(gui, x, y, text, 1, "data/fonts/font_pixel_huge.xml")
	GuiZSetForNextWidget(gui, -9999)
    GuiEndAutoBoxNinePiece(gui, 2, 0, 0, false, 0, "mods/evaisa.bingo/files/3piece_important_msg.png")
end

function OnWorldPostUpdate()
	GuiStartFrame(gui)
	if not ModIsEnabled("evaisa.unshackle") then
		draw_centered_banner(gui, "Unshackle is not enabled! Please enable it.", 1.0, 0.3, 0.3)
	elseif not ModIsEnabled("NoitaDearImGui") then
		draw_centered_banner(gui, "NoitaDearImGui is not enabled! Please enable it.", 1.0, 0.3, 0.3)
	end
end
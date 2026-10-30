-- busted helper: exposes the shared test utilities as globals.
local toc = require("toc")
local load = require("load")

read_toc = toc.read_toc
load_files = load.load_files
load_addon = load.load_addon
run_cmd = load.run_cmd

-- WoW API and Ace3 stub layer (see wow_stubs.lua).
install_wow_stubs = require("wow_stubs")

-- 1b crafting world (see crafting_world.lua).
make_world = require("crafting_world")

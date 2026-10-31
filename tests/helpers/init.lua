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

-- Fake Blizzard_Professions frames (see professions_frame.lua).
fake_professions_frame = require("professions_frame")

-- Phase-3 fixture environment (see phase3_fakes.lua): phase3_env(opts) -> ns, env, W; NOW and WS clock constants.
local P3 = require("tests.helpers.phase3_fakes")
phase3_env = P3.phase3_env
NOW = P3.NOW
WS = P3.WS

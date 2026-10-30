-- busted helper: exposes the shared test utilities as globals.
local toc = require("toc")
local load = require("load")

read_toc = toc.read_toc
load_files = load.load_files
load_addon = load.load_addon
run_cmd = load.run_cmd

-- Filled in by Task 2 (WoW API stubs).
install_wow_stubs = function() end

--- Compare two files or directories (selected/hovered, two selections, or two tabs).

local FINAL_NOTIFY_SECS = 10
local WORKING_NOTIFY_SECS = 120

local function log(msg)
	ya.dbg("[compare] ", msg)
	local cache = os.getenv("XDG_CACHE_HOME") or (os.getenv("HOME") .. "/.cache")
	local path = cache .. "/yazi/compare/debug.log"
	local f = io.open(path, "a")
	if f then
		f:write(os.date("%Y-%m-%d %H:%M:%S"), " ", tostring(msg), "\n")
		f:close()
	end
end

local function plugin_dir()
	local config = os.getenv("YAZI_CONFIG_HOME")
	if not config or config == "" then
		config = (os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")) .. "/yazi"
	end
	return config .. "/plugins/compare.yazi"
end

local function basename(path)
	return tostring(path):match("([^/]+)/?$") or path
end

local function summary_lines(report)
	local lines = {}
	for line in report:gmatch("[^\r\n]+") do
		if line:match("^RESULT:")
			or line:match("^  Only in")
			or line:match("^  Shared files")
			or line:match("^  A files:")
			or line:match("^Type:")
			or line:match("^ERROR:")
		then
			lines[#lines + 1] = line
		end
	end
	if #lines == 0 then
		return report:sub(1, 400)
	end
	return table.concat(lines, "\n")
end

local resolve_paths = ya.sync(function(_, mode)
	if mode == "tabs" then
		if #cx.tabs < 2 then
			return nil, nil, "Need at least 2 tabs"
		end
		return tostring(cx.tabs[1].current.cwd), tostring(cx.tabs[2].current.cwd)
	end

	local paths = {}
	for _, f in pairs(cx.active.selected) do
		local u = f.url or f
		paths[#paths + 1] = tostring(u.path or u)
	end
	table.sort(paths)

	local hovered = cx.active.current.hovered
	local hover_path = hovered and tostring(hovered.path) or nil

	if #paths >= 2 then
		return paths[1], paths[2]
	end

	if #paths == 1 and hover_path and paths[1] ~= hover_path then
		return paths[1], hover_path
	end

	if #paths == 1 then
		return nil, nil, "Select one item and hover another, or select two items"
	end

	if hover_path then
		return nil, nil, "Select one item to compare with the hovered item"
	end

	return nil, nil, "Nothing to compare"
end)

local prepare_script = ya.sync(function()
	local src_path = plugin_dir() .. "/compare-script.lua"
	local f, err = io.open(src_path, "r")
	if not f then
		return nil, "cannot open compare-script.lua: " .. tostring(err)
	end
	local content = f:read("*a")
	f:close()

	local prefix = "return [==["
	if content:sub(1, #prefix) ~= prefix then
		return nil, "compare-script.lua format not recognized"
	end
	local rest = content:sub(#prefix + 1)
	local end_pos = rest:find("]==]", 1, true)
	if not end_pos then
		return nil, "compare-script.lua missing closing delimiter"
	end
	local source = rest:sub(1, end_pos - 1)

	local cache = os.getenv("XDG_CACHE_HOME") or (os.getenv("HOME") .. "/.cache")
	local dir = cache .. "/yazi/compare"
	local path = dir .. "/compare.sh"

	local existing = io.open(path, "r")
	if existing then
		local old = existing:read("*a")
		existing:close()
		if old == source then
			log("reuse cached compare.sh")
			return path
		end
	end

	os.execute('mkdir -p "' .. dir:gsub('"', '\\"') .. '"')
	local out = io.open(path, "w")
	if not out then
		return nil, "Cannot write " .. path
	end
	out:write(source)
	out:close()
	os.execute('chmod +x "' .. path:gsub('"', '\\"') .. '"')
	log("wrote cached compare.sh")
	return path
end)

local notify = ya.sync(function(_, title, content, level, timeout)
	ya.notify {
		title = title or "Compare",
		content = content,
		timeout = timeout or FINAL_NOTIFY_SECS,
		level = level or "info",
	}
end)

local finish = ya.sync(function(_, a, b, report)
	local brief = summary_lines(report)
	if brief == "" then
		brief = "Compare finished."
	end
	local level = report:match("RESULT: IDENTICAL") and "info" or "warn"

	local report_path = os.tmpname() .. ".txt"
	local f = io.open(report_path, "w")
	if f then
		f:write(report)
		f:close()
		ya.clipboard(report_path)
	end

	log("done, notify user")
	ya.notify {
		title = "Compare — done",
		content = string.format(
			"%s ↔ %s\n\n%s\n\nReport: %s",
			basename(a),
			basename(b),
			brief,
			report_path
		),
		timeout = FINAL_NOTIFY_SECS,
		level = level,
	}
end)

local function run_job(a, b)
	log("A=" .. a)
	log("B=" .. b)

	notify(
		"Compare",
		string.format("Comparing…\n%s\n%s\n\n(Task spinner = still working)", basename(a), basename(b)),
		"info",
		WORKING_NOTIFY_SECS
	)

	local script, err = prepare_script()
	if not script then
		log("prepare failed: " .. tostring(err))
		return notify("Compare", err, "error", FINAL_NOTIFY_SECS)
	end

	log("running bash " .. script)
	local child, spawn_err = Command("bash"):arg({ script, a, b }):stdout(Command.PIPED):stderr(Command.PIPED):spawn()
	if not child then
		log("spawn failed: " .. tostring(spawn_err))
		return notify("Compare", "Failed to start compare: " .. tostring(spawn_err), "error", FINAL_NOTIFY_SECS)
	end

	local output, wait_err = child:wait_with_output()
	if not output then
		log("wait failed: " .. tostring(wait_err))
		return notify("Compare", "Compare failed: " .. tostring(wait_err), "error", FINAL_NOTIFY_SECS)
	end

	local report = output.stdout
	if output.stderr ~= "" then
		report = report .. "\n" .. output.stderr
	end
	if report == "" then
		report = "ERROR: compare produced no output"
	end
	log("bash done, bytes=" .. tostring(#report))
	finish(a, b, report)
end

local function entry(_st, job)
	log("entry start")
	local mode = job.args and job.args[1]

	ya.async(function()
		if mode == "--" then
			local a, b = job.args[2], job.args[3]
			if not a or not b then
				return notify("Compare", "Usage: plugin compare -- /path/a /path/b", "error", FINAL_NOTIFY_SECS)
			end
			return run_job(a, b)
		end

		local pick = mode == "tabs" and "tabs" or "selection"
		local a, b, err = resolve_paths(pick)
		if not a then
			log("path error: " .. tostring(err))
			return notify("Compare", err or "Missing paths", "error", FINAL_NOTIFY_SECS)
		end

		run_job(a, b)
	end)
end

return { entry = entry }

--- Compare two files or directories (selected/hovered, two selections, or two tabs).

local FINAL_NOTIFY_SECS = 12
local WORKING_NOTIFY_SECS = 300

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
		return report:sub(1, 500)
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

local ensure_script = ya.sync(function()
	local ok, source = pcall(require, ".compare-script")
	if not ok then
		return nil, "Failed to load compare-script: " .. tostring(source)
	end

	local cache = os.getenv("XDG_CACHE_HOME") or (os.getenv("HOME") .. "/.cache")
	local path = cache .. "/yazi/compare/compare.sh"

	local existing = io.open(path, "r")
	if existing then
		local content = existing:read("*a")
		existing:close()
		if content == source then
			return path
		end
	end

	local dir = path:match("^(.*)/[^/]+$")
	if dir then
		Command("mkdir"):arg("-p"):arg(dir):status()
	end

	local f = io.open(path, "w")
	if not f then
		return nil, "Cannot write compare script to " .. path
	end
	f:write(source)
	f:close()
	Command("chmod"):arg("+x"):arg(path):status()
	return path
end)

local save_report = ya.sync(function(_, report)
	local report_path = os.tmpname() .. ".txt"
	local f = io.open(report_path, "w")
	if f then
		f:write(report)
		f:close()
		ya.clipboard(report_path)
	end
	return report_path
end)

local function show_error(msg)
	ya.notify {
		title = "Compare",
		content = msg,
		timeout = FINAL_NOTIFY_SECS,
		level = "error",
	}
end

local function show_working(a, b)
	ya.notify {
		title = "Compare — working",
		content = string.format(
			"%s ↔ %s\n\nComparing… large folders can take a while.\nTask spinner (top) shows progress.",
			basename(a),
			basename(b)
		),
		timeout = WORKING_NOTIFY_SECS,
		level = "info",
	}
end

local function show_result(a, b, report, report_path)
	local brief = summary_lines(report)
	if brief == "" then
		brief = "Compare finished (no summary text)."
	end

	local level = report:match("RESULT: IDENTICAL") and "info" or "warn"
	local body = string.format(
		"%s ↔ %s\n\n%s\n\nReport copied:\n%s",
		basename(a),
		basename(b),
		brief,
		report_path or "(not saved)"
	)

	-- Toast (auto-dismiss)
	ya.notify {
		title = "Compare — done",
		content = body,
		timeout = FINAL_NOTIFY_SECS,
		level = level,
	}

	-- Center popup (hard to miss; press Enter/Esc to close)
	ya.confirm {
		pos = { "center", w = 72, h = 16 },
		title = "Compare — done",
		body = body,
	}
end

local function run_compare_job(a, b)
	local script, err = ensure_script()
	if not script then
		return show_error(err)
	end

	show_working(a, b)
	ya.dbg("[compare] A=", a, "B=", b)

	local child, spawn_err = Command("bash"):arg({ script, a, b }):stdout(Command.PIPED):stderr(Command.PIPED):spawn()
	if not child then
		return show_error("Failed to start compare: " .. tostring(spawn_err))
	end

	local output, wait_err = child:wait_with_output()
	if not output then
		return show_error("Compare failed: " .. tostring(wait_err))
	end

	local report = output.stdout
	if output.stderr ~= "" then
		report = report .. "\n" .. output.stderr
	end
	if report == "" then
		report = "ERROR: compare produced no output"
	end

	ya.dbg("[compare] report bytes=", #report)
	local report_path = save_report(report)
	show_result(a, b, report, report_path)
end

local function entry(_st, job)
	local mode = job.args and job.args[1]

	ya.async(function()
		if mode == "--" then
			local a, b = job.args[2], job.args[3]
			if not a or not b then
				return show_error("Usage: plugin compare -- /path/a /path/b")
			end
			return run_compare_job(a, b)
		end

		local pick_mode = mode == "tabs" and "tabs" or "selection"
		local a, b, err = resolve_paths(pick_mode)
		if not a then
			return show_error(err or "Missing paths")
		end

		run_compare_job(a, b)
	end)
end

return { entry = entry }

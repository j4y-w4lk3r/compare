--- Compare two files or directories (selected/hovered, two selections, or two tabs).

local FINAL_NOTIFY_SECS = 8

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
	local level = report:match("RESULT: IDENTICAL") and "info" or "warn"

	local report_path = os.tmpname() .. ".txt"
	local f = io.open(report_path, "w")
	if f then
		f:write(report)
		f:close()
		ya.clipboard(report_path)
	end

	local footer = "\n\nReport: " .. report_path
	ya.notify {
		title = "Compare",
		content = string.format("%s ↔ %s\n\n%s%s", basename(a), basename(b), brief, footer),
		timeout = FINAL_NOTIFY_SECS,
		level = level,
	}
end)

local function entry(_st, job)
	local mode = job.args and job.args[1]

	if mode == "--" then
		local a, b = job.args[2], job.args[3]
		if not a or not b then
			notify("Compare", "Usage: plugin compare -- /path/a /path/b", "error", FINAL_NOTIFY_SECS)
			return
		end

		ya.async(function()
			local script, err = ensure_script()
			if not script then
				return notify("Compare", err, "error", FINAL_NOTIFY_SECS)
			end

			notify("Compare", string.format("Comparing…\n%s\n%s", basename(a), basename(b)), "info", 2)

			local child, spawn_err = Command("bash"):arg({ script, a, b }):stdout(Command.PIPED):stderr(Command.PIPED):spawn()
			if not child then
				return notify("Compare", "Failed to start compare: " .. tostring(spawn_err), "error", FINAL_NOTIFY_SECS)
			end

			local output, wait_err = child:wait_with_output()
			if not output then
				return notify("Compare", "Compare failed: " .. tostring(wait_err), "error", FINAL_NOTIFY_SECS)
			end

			local report = output.stdout
			if output.stderr ~= "" then
				report = report .. "\n" .. output.stderr
			end

			finish(a, b, report)
		end)
		return
	end

	if mode == "tabs" then
		mode = "tabs"
	else
		mode = "selection"
	end

	ya.async(function()
		local a, b, err = resolve_paths(mode)
		if not a then
			return notify("Compare", err or "Missing paths", "error", FINAL_NOTIFY_SECS)
		end

		local script, script_err = ensure_script()
		if not script then
			return notify("Compare", script_err, "error", FINAL_NOTIFY_SECS)
		end

		notify("Compare", string.format("Comparing…\n%s\n%s", basename(a), basename(b)), "info", 2)
		ya.dbg("[compare] A=", a, "B=", b)

		local child, spawn_err = Command("bash"):arg({ script, a, b }):stdout(Command.PIPED):stderr(Command.PIPED):spawn()
		if not child then
			return notify("Compare", "Failed to start compare: " .. tostring(spawn_err), "error", FINAL_NOTIFY_SECS)
		end

		local output, wait_err = child:wait_with_output()
		if not output then
			return notify("Compare", "Compare failed: " .. tostring(wait_err), "error", FINAL_NOTIFY_SECS)
		end

		local report = output.stdout
		if output.stderr ~= "" then
			report = report .. "\n" .. output.stderr
		end

		finish(a, b, report)
	end)
end

return { entry = entry }

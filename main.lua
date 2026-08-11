--- @sync entry
--- Compare two files or directories (selected/hovered, two selections, or two tabs).

local SCRIPT_SOURCE = require(".compare-script")

local FINAL_NOTIFY_SECS = 8

local function cache_script_path()
	local cache = os.getenv("XDG_CACHE_HOME") or (os.getenv("HOME") .. "/.cache")
	return cache .. "/yazi/compare/compare.sh"
end

local function ensure_script()
	local path = cache_script_path()
	local existing = io.open(path, "r")
	if existing then
		local content = existing:read("*a")
		existing:close()
		if content == SCRIPT_SOURCE then
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
	f:write(SCRIPT_SOURCE)
	f:close()
	Command("chmod"):arg("+x"):arg(path):status()
	return path
end

local function basename(path)
	return tostring(path):match("([^/]+)/?$") or path
end

local function notify(title, content, level, timeout)
	ya.notify {
		title = title or "Compare",
		content = content,
		timeout = timeout or FINAL_NOTIFY_SECS,
		level = level or "info",
	}
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

local get_selection_paths = ya.sync(function()
	local paths = {}

	for _, f in pairs(cx.active.selected) do
		local u = f.url or f
		paths[#paths + 1] = tostring(u.path or u)
	end

	table.sort(paths)

	local hovered = cx.active.current.hovered
	local hover_path = hovered and tostring(hovered.path) or nil

	return { selected = paths, hovered = hover_path }
end)

local get_tab_paths = ya.sync(function()
	if #cx.tabs < 2 then
		return nil, "Need at least 2 tabs"
	end

	return {
		tostring(cx.tabs[1].current.cwd),
		tostring(cx.tabs[2].current.cwd),
	}
end)

local function resolve_paths(mode)
	if mode == "tabs" then
		local tabs, err = get_tab_paths()
		if not tabs then
			return nil, err
		end
		return tabs[1], tabs[2]
	end

	local sel = get_selection_paths()
	local selected, hovered = sel.selected, sel.hovered

	if #selected >= 2 then
		return selected[1], selected[2]
	end

	if #selected == 1 and hovered and selected[1] ~= hovered then
		return selected[1], hovered
	end

	if #selected == 1 then
		return nil, "Select one item and hover another, or select two items"
	end

	if hovered then
		return nil, "Select one item to compare with the hovered item"
	end

	return nil, "Nothing to compare"
end

local function run_compare(script, a, b)
	local output, err = Command("bash"):arg({ script, a, b }):output()
	if not output then
		return nil, "Failed to run compare script: " .. tostring(err)
	end

	local report = output.stdout
	if output.stderr ~= "" then
		report = report .. "\n" .. output.stderr
	end
	return report
end

local function entry(_st, job)
	local mode = job.args and job.args[1]
	local a, b

	if mode == "--" then
		a, b = job.args[2], job.args[3]
	elseif mode == "tabs" then
		a, b = resolve_paths("tabs")
	else
		a, b = resolve_paths("selection")
	end

	if not a or not b then
		return notify("Compare", b or "Missing paths", "error", FINAL_NOTIFY_SECS)
	end

	local script, err = ensure_script()
	if not script then
		return notify("Compare", err, "error", FINAL_NOTIFY_SECS)
	end

	notify(
		"Compare",
		string.format("Comparing…\n%s\n%s", basename(a), basename(b)),
		"info",
		2
	)

	ya.dbg("[compare] A=", a, "B=", b)

	local report, run_err = run_compare(script, a, b)
	if not report then
		return notify("Compare", run_err, "error", FINAL_NOTIFY_SECS)
	end

	local brief = summary_lines(report)
	local level = report:match("RESULT: IDENTICAL") and "info" or "warn"

	local report_path = os.tmpname() .. ".txt"
	local f = io.open(report_path, "w")
	if f then
		f:write(report)
		f:close()
		ya.clipboard(report_path)
	end

	local footer = report_path and ("\n\nReport: " .. report_path) or ""
	notify(
		"Compare",
		string.format("%s ↔ %s\n\n%s%s", basename(a), basename(b), brief, footer),
		level,
		FINAL_NOTIFY_SECS
	)
end

return { entry = entry }

--- @sync entry
--- Compare two files or directories (selected/hovered, two selections, or two tabs).

local FINAL_NOTIFY_SECS = 10

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

local function load_script_source()
	local path = plugin_dir() .. "/compare-script.lua"
	local f, err = io.open(path, "r")
	if not f then
		return nil, "cannot open compare-script.lua: " .. tostring(err)
	end
	local content = f:read("*a")
	f:close()

	local prefix = "return [==["
	local suffix = "]==]"
	if content:sub(1, #prefix) == prefix and content:sub(-#suffix) == suffix then
		return content:sub(#prefix + 1, -#suffix - 1)
	end

	return nil, "compare-script.lua format not recognized"
end

local function cache_script_path()
	local cache = os.getenv("XDG_CACHE_HOME") or (os.getenv("HOME") .. "/.cache")
	return cache .. "/yazi/compare/compare.sh"
end

local function ensure_script(source)
	local path = cache_script_path()
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

local function resolve_paths(mode)
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
end

local function run_compare(script, a, b)
	log("running bash " .. script)
	local output, err = Command("bash"):arg({ script, a, b }):output()
	if not output then
		return nil, "Failed to run compare script: " .. tostring(err)
	end

	local report = output.stdout
	if output.stderr ~= "" then
		report = report .. "\n" .. output.stderr
	end
	log("bash done, bytes=" .. tostring(#report))
	return report
end

local function entry(_st, job)
	log("entry start")
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
		log("path error: " .. tostring(b))
		return notify("Compare", b or "Missing paths", "error", FINAL_NOTIFY_SECS)
	end

	log("A=" .. a)
	log("B=" .. b)

	local source, req_err = load_script_source()
	if not source then
		log("require failed: " .. req_err)
		return notify("Compare", "Failed to load compare-script: " .. req_err, "error", FINAL_NOTIFY_SECS)
	end

	local script, err = ensure_script(source)
	if not script then
		log("ensure_script failed: " .. tostring(err))
		return notify("Compare", err, "error", FINAL_NOTIFY_SECS)
	end

	notify(
		"Compare",
		string.format("Comparing…\n%s\n%s", basename(a), basename(b)),
		"info",
		FINAL_NOTIFY_SECS
	)

	local report, run_err = run_compare(script, a, b)
	if not report then
		log("run_compare failed: " .. tostring(run_err))
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

	log("done, notify user")
	notify(
		"Compare",
		string.format(
			"%s ↔ %s\n\n%s\n\nReport: %s",
			basename(a),
			basename(b),
			brief,
			report_path
		),
		level,
		FINAL_NOTIFY_SECS
	)
end

return { entry = entry }

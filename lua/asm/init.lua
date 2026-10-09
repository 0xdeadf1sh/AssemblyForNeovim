local M = {}

local LEVELS = { "0", "1", "2", "3", "s" }

local RUSTC_INTEL = "-Cllvm-args=--x86-asm-syntax=intel"

local state = {}

local function warn(msg)
	vim.notify("asm: " .. msg, vim.log.levels.WARN)
end

local function find_up(from, name)
	return vim.fs.find(name, { path = from, upward = true, type = "file" })[1]
end

local function db_entry(path)
	local dirs = { find_up(vim.fs.dirname(path), "compile_commands.json") }
	local root = vim.fs.root(path, { ".git", "CMakeLists.txt", "Makefile", "meson.build" })
	if root then
		for _, sub in ipairs({ "build", "out", "builddir" }) do
			dirs[#dirs + 1] = root .. "/" .. sub .. "/compile_commands.json"
		end
	end

	local want = vim.fs.normalize(path)
	for _, db in ipairs(dirs) do
		if db and vim.uv.fs_stat(db) then
			local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(db), "\n"))
			if ok and type(data) == "table" then
				for _, e in ipairs(data) do
					local f = e.file or ""
					if not vim.startswith(f, "/") then
						f = (e.directory or ".") .. "/" .. f
					end
					if vim.fs.normalize(f) == want then
						return e
					end
				end
			end
		end
	end
end

local DROP_PAIR = { ["-o"] = true, ["-MF"] = true, ["-MT"] = true, ["-MQ"] = true }
local DROP = { ["-c"] = true, ["-MD"] = true, ["-MMD"] = true, ["-MP"] = true, ["-S"] = true }

local function strip(args)
	local out, skip = {}, false
	for _, a in ipairs(args) do
		if skip then
			skip = false
		elseif DROP_PAIR[a] then
			skip = true
		elseif not (DROP[a] or a:match("^%-O") or a:match("^%-g%d?$")) then
			out[#out + 1] = a
		end
	end
	return out
end

local function cc_base(path, ft)
	local e = db_entry(path)
	if e then
		return strip(e.arguments or vim.split(e.command or "", "%s+", { trimempty = true })), e.directory
	end
	return {
		ft == "cpp" and "c++" or "cc",
		ft == "cpp" and "-std=c++23" or "-std=c23",
		path,
	}, vim.fs.dirname(path)
end

local x86 = {}

local function targets_x86(probe, cwd)
	local key = probe[1] or ""
	if x86[key] == nil then
		local ok, res = pcall(function()
			return vim.system(probe, { cwd = cwd, text = true }):wait()
		end)
		local out = ok and res.code == 0 and res.stdout or ""
		x86[key] = out:find("x86") ~= nil or out:find("i%d86") ~= nil
	end
	return x86[key]
end

local function build(path, ft, level)
	if ft == "rust" then
		local out = vim.fn.tempname() .. ".s"
		local cargo = find_up(vim.fs.dirname(path), "Cargo.toml")
		local cwd = vim.fs.dirname(cargo or path)
		local flags = {
			"--emit",
			"asm=" .. out,
			"-Cdebuginfo=2",
			"-Ccodegen-units=1",
			"-Copt-level=" .. level,
		}
		if targets_x86({ "rustc", "--print", "cfg" }, cwd) then
			flags[#flags + 1] = RUSTC_INTEL
		end
		if cargo then
			local argv = { "cargo", "rustc", "--quiet", "--" }
			vim.list_extend(argv, flags)
			return argv, cwd, out
		end
		local argv = { "rustc", "--crate-type=lib" }
		vim.list_extend(argv, flags)
		argv[#argv + 1] = path
		return argv, cwd, out
	end

	local argv, cwd = cc_base(path, ft)
	vim.list_extend(argv, { "-S", "-g", "-O" .. level })
	if targets_x86({ argv[1], "-dumpmachine" }, cwd) then
		argv[#argv + 1] = "-masm=intel"
	end
	vim.list_extend(argv, { "-o", "-" })
	return argv, cwd, nil
end

local function our_file_ids(lines, path)
	local base, ids, seen = vim.fs.basename(path), {}, false
	for _, l in ipairs(lines) do
		local n, rest = l:match("^%s*%.file%s+(%d+)%s+(.*)$")
		if n then
			seen = true
			local name
			for q in rest:gmatch('"([^"]*)"') do
				name = q
			end
			if name and vim.fs.basename(name) == base then
				ids[tonumber(n)] = true
			end
		end
	end
	if not seen or vim.tbl_isempty(ids) then
		ids[1] = true
	end
	return ids
end

local demangled = {}

local function demangle(name)
	if demangled[name] == nil then
		local ok = vim.fn.executable("c++filt") == 1
		local res = ok and vim.system({ "c++filt", "--no-strip-underscore", name }, { text = true }):wait()
		demangled[name] = (res and res.code == 0 and vim.trim(res.stdout) ~= "") and vim.trim(res.stdout) or name
	end
	return demangled[name]
end

local function extract(lines, path, l1, l2, src)
	local ids = our_file_ids(lines, path)
	local items, inside, fn, prev = {}, false, nil, nil

	for _, l in ipairs(lines) do
		local fno, lno = l:match("^%s*%.loc%s+(%d+)%s+(%d+)")
		if fno then
			lno = tonumber(lno)
			inside = ids[tonumber(fno)] and lno >= l1 and lno <= l2
			if inside and lno ~= prev then
				items[#items + 1] = { kind = "src", line = lno, fn = fn }
				prev = lno
			end
		else
			local name = l:match('^"?([%w_$.@][%w_$.@]*)"?:')
			if name then
				if not vim.startswith(name, ".") then
					fn = name
				end
				if inside then
					items[#items + 1] = { kind = "label", name = name }
				end
			elseif inside and l:match("%S") and not l:match("^%s*%.") then
				items[#items + 1] = { kind = "insn", text = vim.trim(l:gsub("\t", " ")) }
			end
		end
	end

	local refd = {}
	for _, it in ipairs(items) do
		if it.kind == "insn" then
			for w in it.text:gmatch("[%.%w_$@]+") do
				refd[w] = true
			end
		end
	end

	local out, shown = {}, nil
	for _, it in ipairs(items) do
		if it.kind == "src" then
			if it.fn and it.fn ~= shown then
				if #out > 0 then
					out[#out + 1] = ""
				end
				out[#out + 1] = demangle(it.fn) .. ":"
				shown = it.fn
			end
			out[#out + 1] = ("  ; %d | %s"):format(it.line, vim.trim(src[it.line] or ""))
		elseif it.kind == "label" then
			if refd[it.name] then
				out[#out + 1] = "    " .. it.name .. ":"
			end
		else
			out[#out + 1] = "        " .. it.text
		end
	end
	return out
end

local function render(buf, lines)
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].modified = false
end

local function geometry()
	local w = math.min(100, math.floor(vim.o.columns * 0.8))
	local h = math.min(40, math.floor(vim.o.lines * 0.8))
	return {
		relative = "editor",
		width = w,
		height = h,
		row = math.floor((vim.o.lines - h) / 2) - 1,
		col = math.floor((vim.o.columns - w) / 2),
		style = "minimal",
		border = "rounded",
	}
end

local function retitle(s, tail)
	if not (s and vim.api.nvim_win_is_valid(s.win)) then
		return
	end
	local cfg = geometry()
	cfg.title = (" %s  %d-%d  -O%s  ·  %s "):format(vim.fs.basename(s.path), s.l1, s.l2, s.level, tail)
	cfg.title_pos = "left"
	vim.api.nvim_win_set_config(s.win, cfg)
end

local function run(buf)
	local s = state[buf]
	if not s then
		return
	end

	local argv, cwd, outfile = build(s.path, s.ft, s.level)
	s.gen = (s.gen or 0) + 1
	local gen = s.gen
	retitle(s, "compiling…")

	vim.system(argv, { cwd = cwd, text = true }, function(res)
		vim.schedule(function()
			if not vim.api.nvim_buf_is_valid(buf) or state[buf] ~= s or s.gen ~= gen then
				return
			end

			if res.code ~= 0 then
				vim.bo[buf].filetype = ""
				render(buf, vim.split(vim.trim(res.stderr or "compile failed"), "\n"))
				retitle(s, "failed")
				return
			end

			local asm
			if outfile then
				asm = vim.uv.fs_stat(outfile) and vim.fn.readfile(outfile) or {}
			else
				asm = vim.split(res.stdout or "", "\n")
			end

			local body = extract(asm, s.path, s.l1, s.l2, s.src)
			if #body == 0 then
				body = { ("; nothing maps to lines %d-%d"):format(s.l1, s.l2) }
				if s.ft == "rust" and s.level ~= "0" then
					vim.list_extend(body, {
						";",
						"; at -O a Rust-ABI `pub fn` in an rlib emits no asm — its body",
						"; ships as MIR for cross-crate inlining instead.",
						"; give it a call site, mark it #[no_mangle], or press - for -O0.",
					})
				end
			end

			vim.bo[buf].filetype = "asm"
			render(buf, body)
			retitle(s, "[+/-] level  [R] rerun  [q] close")
		end)
	end)
end

local function step(buf, delta)
	local s = state[buf]
	local i = 1
	for k, v in ipairs(LEVELS) do
		if v == s.level then
			i = k
		end
	end
	s.level = LEVELS[math.min(#LEVELS, math.max(1, i + delta))]
	run(buf)
end

function M.show(l1, l2)
	local src_buf = vim.api.nvim_get_current_buf()
	local ft = vim.bo[src_buf].filetype
	if ft ~= "c" and ft ~= "cpp" and ft ~= "rust" then
		return warn("no backend for filetype '" .. ft .. "'")
	end

	local path = vim.api.nvim_buf_get_name(src_buf)
	if path == "" or not vim.uv.fs_stat(path) then
		return warn("buffer has no file on disk")
	end
	if vim.bo[src_buf].modified then
		warn("buffer modified — reading the file on disk")
	end

	local src = vim.api.nvim_buf_get_lines(src_buf, 0, -1, false)

	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_open_win(buf, true, geometry())

	vim.bo[buf].bufhidden = "wipe"
	vim.wo[win].wrap = false
	vim.wo[win].cursorline = true

	state[buf] = { path = path, ft = ft, l1 = l1, l2 = l2, level = "2", win = win, src = src }

	local map = function(lhs, fn)
		vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
	end
	map("+", function()
		step(buf, 1)
	end)
	map("-", function()
		step(buf, -1)
	end)
	map("R", function()
		run(buf)
	end)
	local close = function()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end
	map("q", close)
	map("<Esc>", close)

	vim.api.nvim_create_autocmd("VimResized", {
		buffer = buf,
		callback = function()
			retitle(state[buf], "[+/-] level  [R] rerun  [q] close")
		end,
	})

	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		callback = function()
			state[buf] = nil
		end,
	})

	run(buf)
end

local function enclosing_fn()
	local ok, node = pcall(vim.treesitter.get_node)
	if not ok or not node then
		return nil
	end
	while node do
		local t = node:type()
		if t:match("function") or t:match("method") then
			local sr, _, er = node:range()
			return sr + 1, er + 1
		end
		node = node:parent()
	end
end

function M.setup()
	vim.api.nvim_create_user_command("Asm", function(o)
		M.show(o.line1, o.line2)
	end, { range = true, desc = "Assembly for the selected lines" })

	vim.keymap.set("x", "<leader>a", ":Asm<CR>", { silent = true, desc = "[A]ssembly for selection" })
	vim.keymap.set("n", "<leader>a", function()
		local l1, l2 = enclosing_fn()
		M.show(l1 or vim.fn.line("."), l2 or vim.fn.line("."))
	end, { desc = "[A]ssembly for the function under the cursor" })
end

return M

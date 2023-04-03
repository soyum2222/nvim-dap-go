local query = require "vim.treesitter.query"

local M = {}


local tests_query = [[
(function_declaration
name: (identifier) @testname
parameters: (parameter_list
. (parameter_declaration
type: (pointer_type) @type) .)
(#eq? @type "*testing.T")
(#match? @testname "^Test.+$")) @parent
]]

local subtests_query = [[
(call_expression
function: (selector_expression
	operand: (identifier)
	field: (field_identifier) @run)
	arguments: (argument_list
	(interpreted_string_literal) @testname
	(func_literal))
	(#eq? @run "Run")) @parent
	]]

local function load_module(module_name)
	local ok, module = pcall(require, module_name)
	assert(ok, string.format('dap-go dependency error: %s not installed', module_name))
	return module
end

local function local_debug_func(callback, config)
	local host = config.host or "127.0.0.1"
	local port = config.port or "38697"



	vim.api.nvim_exec('copen', true)
	vim.api.nvim_exec('AsyncRun dlv dap -l 127.0.0.1:' .. port, true)

	vim.defer_fn(
		function()
			callback({ type = "server", host = "127.0.0.1", port = port })
		end,
		2000)
end

local remote_debug_host = "127.0.0.1"
local remote_debug_port = "38697"

local function remote_debug_func(callback, config)
	local host = remote_debug_host or "127.0.0.1"
	local port = remote_debug_port or "38697"

	vim.defer_fn(
		function()
			callback({ type = "server", host = "127.0.0.1", port = port })
		end,
		2000)
end


local function setup_go_adapter(dap)
	dap.adapters.go = local_debug_func
end



local function setup_go_configuration(dap)
	dap.configurations.go = {
		{
			type = "go",
			name = "Debug",
			request = "launch",
			program = "${file}",
		},
		{
			type = "go",
			name = "Attach",
			mode = "local",
			request = "attach",
			processId = require('dap.utils').pick_process,
		},
		{
			type = "go",
			name = "Debug test",
			request = "launch",
			mode = "test",
			program = "${file}",
		},
		{
			type = "go",
			name = "Debug test (go.mod)",
			request = "launch",
			mode = "test",
			program = "./${relativeFileDirname}",
		}
	}
end

function M.setup()
	local dap = load_module("dap")
	setup_go_adapter(dap)
	setup_go_configuration(dap)
end

local function debug_test(testname)
	local dap = load_module("dap")
	dap.run({
		type = "go",
		name = testname,
		request = "launch",
		mode = "test",
		program = "./${relativeFileDirname}",
		args = { "-test.run", testname },
	})
end

local function get_closest_above_cursor(test_tree)
	local result
	for _, curr in pairs(test_tree) do
		if not result then
			result = curr
		else
			local node_row1, _, _, _ = curr.node:range()
			local result_row1, _, _, _ = result.node:range()
			if node_row1 > result_row1 then
				result = curr
			end
		end
	end
	if result.parent then
		return string.format("%s/%s", result.parent, result.name)
	else
		return result.name
	end
end


local function is_parent(dest, source)
	if not (dest and source) then
		return false
	end
	if dest == source then
		return false
	end

	local current = source
	while current ~= nil do
		if current == dest then
			return true
		end

		current = current:parent()
	end

	return false
end

local function get_closest_test()
	local stop_row = vim.api.nvim_win_get_cursor(0)[1]
	local ft = vim.api.nvim_buf_get_option(0, 'filetype')
	assert(ft == 'go', 'dap-go error: can only debug go files, not ' .. ft)
	local parser = vim.treesitter.get_parser(0)
	local root = (parser:parse()[1]):root()

	local test_tree = {}

	local test_query = vim.treesitter.parse_query(ft, tests_query)
	assert(test_query, 'dap-go error: could not parse test query')
	for _, match, _ in test_query:iter_matches(root, 0, 0, stop_row) do
		local test_match = {}
		for id, node in pairs(match) do
			local capture = test_query.captures[id]
			if capture == "testname" then
				local name = query.get_node_text(node, 0)
				test_match.name = name
			end
			if capture == "parent" then
				test_match.node = node
			end
		end
		table.insert(test_tree, test_match)
	end

	local subtest_query = vim.treesitter.parse_query(ft, subtests_query)
	assert(subtest_query, 'dap-go error: could not parse test query')
	for _, match, _ in subtest_query:iter_matches(root, 0, 0, stop_row) do
		local test_match = {}
		for id, node in pairs(match) do
			local capture = subtest_query.captures[id]
			if capture == "testname" then
				local name = query.get_node_text(node, 0)
				test_match.name = string.gsub(string.gsub(name, ' ', '_'), '"', '')
			end
			if capture == "parent" then
				test_match.node = node
			end
		end
		table.insert(test_tree, test_match)
	end

	table.sort(test_tree, function(a, b)
		return is_parent(a.node, b.node)
	end)

	for _, parent in ipairs(test_tree) do
		for _, child in ipairs(test_tree) do
			if is_parent(parent.node, child.node) then
				child.parent = parent.name
			end
		end
	end

	return get_closest_above_cursor(test_tree)
end

function M.debug_test()
	local testname = get_closest_test()
	local msg = string.format("starting debug session '%s'...", testname)
	print(msg)
	debug_test(testname)
end

local function local_debug(dap)
	dap.adapters.go = remote_debug_func

	vim.ui.input({
			prompt = "program arguments:",
			default = "",
		},
		function(args)
			if args ~= nil then
				for key, _ in ipairs(dap.configurations.go)
				do
					dap.configurations.go[key].args = vim.split(args, " ")
				end
			end
		end)

	vim.ui.select({ "1", "2" }, {
		prompt = "",
		format_item = function(item)
			if item == "1" then
				return "run program"
			end

			if item == "2" then
				return "run test file"
			end
		end
	}, function(item, idx)
		_ = idx
		if item == "1" then
			dap.continue()
		end

		if item == "2" then
			M.debug_test()
		end
	end)
end



local function remote_debug(dap)
	dap.adapters.go = remote_debug_func

	vim.ui.input({
		prompt = "remote host:",
		default = ""
	}, function(args)
		if args ~= nil then
			remote_debug_host = args
		end
	end)

	vim.ui.input({
		prompt = "remote port:",
		default = ""
	}, function(args)
		if args ~= nil then
			remote_debug_port = args
		end
	end)

	dap.continue()
end

function M.start_debug(dap)
	vim.ui.select({ "1", "2" }, {
		prompt = "",
		format_item = function(item)
			if item == "1" then
				return "local debug"
			end

			if item == "2" then
				return "remote debug"
			end
		end
	}, function(item, idx)
		_ = idx
		if item == "1" then
			local_debug(dap)
		end

		if item == "2" then
			remote_debug(dap)
		end
	end)
end

return M

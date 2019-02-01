-- Copyright 2016-2017 Xingwang Liao <kuoruan@gmail.com>
-- Licensed to the public under the Apache License 2.0.

local fs   = require "nixio.fs"
local sys  = require "luci.sys"
local uci  = require "luci.model.uci".cursor()
local util = require "luci.util"
local i18n = require "luci.i18n"

module("luci.model.kcptun", package.seeall)

local kcptun_api = "https://api.github.com/repos/xtaci/kcptun/releases/latest"
local luci_api = "https://api.github.com/repos/kuoruan/luci-app-kcptun/releases/latest"

local wget = "/usr/bin/wget"
local wget_args = { "--no-check-certificate", "--quiet", "--timeout=10", "--tries=2" }
local command_timeout = 40

local function _unpack(t, i)
	i = i or 1
	if t[i] ~= nil then
		return t[i], _unpack(t, i + 1)
	end
end

local function exec(cmd, args, writer, timeout)
	local os = require "os"
	local nixio = require "nixio"

	local fdi, fdo = nixio.pipe()
	local pid = nixio.fork()

	if pid > 0 then
		fdo:close()

		if writer or timeout then
			local starttime = os.time()
			while true do
				if timeout and os.difftime(os.time(), starttime) >= timeout then
					nixio.kill(pid, nixio.const.SIGTERM)
					return 1
				end

				if writer then
					local buffer = fdi:read(2048)
					if buffer and #buffer > 0 then
						writer(buffer)
					end
				end

				local wpid, stat, code = nixio.waitpid(pid, "nohang")

				if wpid and stat == "exited" then
					return code
				end

				if not writer and timeout then
					nixio.nanosleep(1)
				end
			end
		else
			local wpid, stat, code = nixio.waitpid(pid)
			return wpid and stat == "exited" and code
		end
	elseif pid == 0 then
		nixio.dup(fdo, nixio.stdout)
		fdi:close()
		fdo:close()
		nixio.exece(cmd, args, nil)
		nixio.stdout:close()
		os.exit(1)
	end
end

local function compare_versions(ver1, comp, ver2)
	local table = table

	local av1 = util.split(ver1, "[%.%-]", nil, true)
	local av2 = util.split(ver2, "[%.%-]", nil, true)

	local max = table.getn(av1)
	local n2 = table.getn(av2)
	if (max < n2) then
		max = n2
	end

	for i = 1, max, 1  do
		local s1 = av1[i] or ""
		local s2 = av2[i] or ""

		if comp == "~=" and (s1 ~= s2) then return true end
		if (comp == "<" or comp == "<=") and (s1 < s2) then return true end
		if (comp == ">" or comp == ">=") and (s1 > s2) then return true end
		if (s1 ~= s2) then return false end
	end

	return not (comp == "<" or comp == ">")
end

local function get_api_json(url)
	local jsonc = require "luci.jsonc"

	local output = { }
	exec(wget, { "-O-", url, _unpack(wget_args) },
		function(chunk) output[#output + 1] = chunk end)

	local json_content = util.trim(table.concat(output))

	if json_content == "" then
		return { }
	end

	return jsonc.parse(json_content) or { }
end

function get_config_option(option, default)
	return uci:get("kcptun", "general", option) or default
end

function get_current_log_file(type)
	local log_folder = get_config_option("log_folder", "/var/log/kcptun")
	return "%s/%s.%s.log" % { log_folder, type, "general" }
end

function is_running(client)
	if client and client ~= "" then
		local file_name = client:match(".*/([^/]+)$") or ""
		if file_name ~= "" then
			return sys.call("pidof %s >/dev/null" % file_name) == 0
		end
	end

	return false
end

function check_luci()
	local json = get_api_json(luci_api)

	if json.tag_name == nil then
		return {
			code = 1,
			error = i18n.translate("Get remote version info failed.")
		}
	end

	local remote_version = json.tag_name:match("[^v]+")

	local needs_update = compare_versions(get_luci_version(), "<", remote_version)
	local html_url, luci_url
	local i18n_urls = { }

	if needs_update then
		html_url = json.html_url
		for _, v in ipairs(json.assets) do
			local n = v.name
			if n then
				if n:match("luci%-app%-kcptun") then
					luci_url = v.browser_download_url
				elseif n:match("luci%-i18n%-kcptun") then
					i18n_urls[#i18n_urls + 1] = v.browser_download_url
				end
			end
		end
	end

	if needs_update and not luci_url then
		return {
			code = 1,
			version = remote_version,
			html_url = html_url,
			error = i18n.translate("New version found, but failed to get new version download url.")
		}
	end

	return {
		code = 0,
		update = needs_update,
		version = remote_version,
		url = {
			html = html_url,
			luci = luci_url,
			i18n = i18n_urls
		}
	}
end

function update_luci(url, save)
	if not url or url == "" then
		return {
			code = 1,
			error = i18n.translate("Download url is required.")
		}
	end

	sys.call("/bin/rm -f /tmp/luci_kcptun.*.ipk")

	local tmp_file = util.trim(util.exec("mktemp -u -t luci_kcptun.XXXXXX")) .. ".ipk"

	local result = exec("/usr/bin/wget", {
		"-O", tmp_file, url, _unpack(wget_args) }, nil, command_timeout) == 0

	if not result then
		exec("/bin/rm", { "-f", tmp_file })
		return {
			code = 1,
			error = i18n.translatef("File download failed or timed out: %s", url)
		}
	end

	local opkg_args = { "--force-downgrade", "--force-reinstall" }

	if save ~= "true" then
		opkg_args[#opkg_args + 1] = "--force-maintainer"
	end

	result = exec("/bin/opkg", { "install", tmp_file, _unpack(opkg_args) }) == 0

	if not result then
		exec("/bin/rm", { "-f", tmp_file })
		return {
			code = 1,
			error = i18n.translate("Package update failed.")
		}
	end

	exec("/bin/rm", { "-f", tmp_file })
	exec("/bin/rm", { "-rf", "/tmp/luci-indexcache", "/tmp/luci-modulecache" })

	return { code = 0 }
end

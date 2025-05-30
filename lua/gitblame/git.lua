local utils = require("gitblame.utils")
local M = {}

---@param callback fun(is_ignored: boolean)
function M.check_is_ignored(callback)
    local filepath = vim.api.nvim_buf_get_name(0)
    if filepath == "" then
        return true
    end

    utils.start_job("git check-ignore " .. vim.fn.shellescape(filepath), {
        on_exit = function(code)
            callback(code ~= 1)
        end,
    })
end

---@param url string
---@return string
local function get_http_domain(url)
    local domain = string.match(url, "https%:%/%/.*%@([^/]*)%/.*")
        or string.match(url, "https%:%/%/([^/]*)%/.*")
    return domain and domain:lower()
end

---@param sha string
---@param remote_url string
---@return string
local function get_commit_path(sha, repo_url)
    local domain = get_http_domain(repo_url)

    local forge = vim.g.gitblame_remote_domains[domain]
    if forge == "bitbucket" then
        return "/commits/" .. sha
    end

    return "/commit/" .. sha
end

---@param url string
---@return string
local function get_azure_url(url)
    -- HTTPS has a different URL format
    local org, project, repo = string.match(url, "(.*)/(.*)/_git/(.*)")
    if org and project and repo then
        return 'https://dev.azure.com/' .. org .. "/" .. project .. "/_git/" .. repo
    end

    org, project, repo = string.match(url, "(.*)/(.*)/(.*)")
    if org and project and repo then
        return 'https://dev.azure.com/' .. org .. "/" .. project .. "/_git/" .. repo
    end

    return url
end

---@param remote_url string
---@return string
local function get_repo_url(remote_url)
    local remote_url = string.gsub(remote_url, "/$", "")

    local domain, path = string.match(remote_url, ".*git%@(.*)%:(.*)%.git")
    if domain and path then
        return "https://" .. domain .. "/" .. path
    end

    local url = string.match(remote_url, ".*git@*ssh.dev.azure.com:v[0-9]/(.*)")
    if url then
        return get_azure_url(url)
    end

    local https_url = string.match(remote_url, ".*@dev.azure.com/(.*)")
    if https_url then
        return get_azure_url(https_url)
    end

    url = string.match(remote_url, ".*git%@(.*)%.git")
    if url then
        return "https://" .. url
    end

    https_url = string.match(remote_url, "(https%:%/%/.*)%.git")
    if https_url then
        return https_url
    end

    domain, path = string.match(remote_url, ".*git%@(.*)%:(.*)")
    if domain and path then
        return "https://" .. domain .. "/" .. path
    end

    url = string.match(remote_url, ".*git%@(.*)")
    if url then
        return "https://" .. url
    end

    https_url = string.match(remote_url, "(https%:%/%/.*)")
    if https_url then
        return https_url
    end

    return remote_url
end

---@param remote_url string
---@param ref_type "commit"|"branch"
---@param ref string
---@param filepath string
---@param line1 number?
---@param line2 number?
---@return string
local function get_file_url(remote_url, ref_type, ref, filepath, line1, line2)
    local repo_url = get_repo_url(remote_url)
    local domain = get_http_domain(repo_url)

    local forge = vim.g.gitblame_remote_domains[domain]

    local file_path = "/blob/" .. ref .. "/" .. filepath
    if forge == "sourcehut" then
        file_path = "/tree/" .. ref .. "/" .. filepath
    end
    if forge == "forgejo" then
        file_path = "/src/" .. ref_type .. "/" .. ref .. "/" .. filepath
    end
    if forge == "bitbucket" then
        file_path = "/src/" .. ref .. "/" .. filepath
    end
    if forge == "azure" then
        -- Can't use ref here if it's a commit sha
        -- FIXME: add branch names to the URL
        file_path = "?path=%2F" .. filepath
    end

    if line1 == nil then
        return repo_url .. file_path
    elseif line2 == nil or line1 == line2 then
        if forge == "azure" then
            return repo_url .. file_path .. "&line=" .. line1 .. "&lineEnd=" .. line1 + 1 .. "&lineStartColumn=1&lineEndColumn=1"
        end

        if forge == "bitbucket" then
            return repo_url .. file_path .. "#lines-" .. line1
        end

        return repo_url .. file_path .. "#L" .. line1
    else
        if forge == "sourcehut" then
            return repo_url .. file_path .. "#L" .. line1 .. "-" .. line2
        end

        if forge == "azure" then
            return repo_url .. file_path .. "&line=" .. line1 .. "&lineEnd=" .. line2 + 1 .. "&lineStartColumn=1&lineEndColumn=1"
        end

        if forge == "bitbucket" then
            return repo_url .. file_path .. "#lines-" .. line1 .. ":" .. line2
        end

        return repo_url .. file_path .. "#L" .. line1 .. "-L" .. line2
    end
end

---@param callback fun(branch_name: string)
local function get_current_branch(callback)
    if not utils.get_filepath() then
        return
    end
    local command = utils.make_local_command("git branch --show-current")

    utils.start_job(command, {
        on_stdout = function(url)
            if url and url[1] then
                callback(url[1])
            else
                callback("")
            end
        end,
    })
end

---@param filepath string
---@param sha string?
---@param line1 number?
---@param line2 number?
---@param callback fun(url: string)
function M.get_file_url(filepath, sha, line1, line2, callback)
    M.get_repo_root(function(root)
        -- if outside a repository, return the filepath
        -- so we can still copy the path or open the file
        if root == "" then
            callback(filepath)
            return
        end

        local relative_filepath = string.sub(filepath, #root + 2)

        if sha == nil then
            get_current_branch(function(branch)
                M.get_remote_url(function(remote_url)
                    local url = get_file_url(remote_url, "branch", branch, relative_filepath, line1, line2)
                    callback(url)
                end)
            end)
        else
            M.get_remote_url(function(remote_url)
                local url = get_file_url(remote_url, "commit", sha, relative_filepath, line1, line2)
                callback(url)
            end)
        end
    end)
end

---@param sha string
---@param remote_url string
---@return string
function M.get_commit_url(sha, remote_url)
    local repo_url = get_repo_url(remote_url)
    local commit_path = get_commit_path(sha, repo_url)

    return repo_url .. commit_path
end

---@param filepath string
---@param sha string?
---@param line1 number?
---@param line2 number?
function M.open_file_in_browser(filepath, sha, line1, line2)
    M.get_file_url(filepath, sha, line1, line2, function(url)
        utils.launch_url(url)
    end)
end

---@param sha string
function M.open_commit_in_browser(sha)
    M.get_remote_url(function(remote_url)
        local commit_url = M.get_commit_url(sha, remote_url)
        utils.launch_url(commit_url)
    end)
end

---@param callback fun(url: string)
function M.get_remote_url(callback)
    if not utils.get_filepath() then
        return
    end
    local remote_url_command = utils.make_local_command("git remote get-url origin")

    utils.start_job(remote_url_command, {
        on_stdout = function(url)
            if url and url[1] then
                callback(url[1])
            else
                callback("")
            end
        end,
    })
end

---@param callback fun(repo_root: string)
function M.get_repo_root(callback)
    if not utils.get_filepath() then
        return
    end
    local command = utils.make_local_command("git rev-parse --show-toplevel")

    utils.start_job(command, {
        on_stdout = function(data)
            callback(data[1])
        end,
    })
end

return M

-- File: ~/src/nvim/clangd-unfurl.nvim/lua/clangd-unfurl.lua
-- Description: Unfurl local #include "file.h" in C files into a virtual buffer.

local vim = vim
local api = vim.api
local M = {}

-- Table to keep track of file contents and changes
M.files = {}
M.virtual_buffer = nil
M.original_buffer = nil
M.file_order = {}
M.modified_files = {}
M.line_mapping = {} -- Maps virtual buffer lines to original files and line numbers

-- Utility function to read a file asynchronously
local function read_file_async(filepath, callback)
    local uv = vim.loop
    uv.fs_open(filepath, "r", 438, function(err_open, fd)
        if err_open then
            vim.schedule(function()
                vim.notify("Failed to open " .. filepath .. ": " .. err_open, vim.log.levels.ERROR)
                callback(nil)
            end)
            return
        end
        uv.fs_fstat(fd, function(err_fstat, stat)
            if err_fstat then
                uv.fs_close(fd)
                vim.schedule(function()
                    vim.notify("Failed to stat " .. filepath .. ": " .. err_fstat, vim.log.levels.ERROR)
                    callback(nil)
                end)
                return
            end
            uv.fs_read(fd, stat.size, 0, function(err_read, data)
                uv.fs_close(fd)
                if err_read then
                    vim.schedule(function()
                        vim.notify("Failed to read " .. filepath .. ": " .. err_read, vim.log.levels.ERROR)
                        callback(nil)
                    end)
                    return
                end
                vim.schedule(function()
                    callback(data)
                end)
            end)
        end)
    end)
end

-- Function to parse includes and load files recursively
local function parse_includes_async(filepath, parent_dir, seen_files, callback)
    parent_dir = parent_dir or vim.fn.fnamemodify(filepath, ":h")
    seen_files = seen_files or {}

    -- Prevent circular includes
    if seen_files[filepath] then
        vim.schedule(function()
            vim.notify("Circular include detected: " .. filepath, vim.log.levels.ERROR)
            callback({})
        end)
        return
    end
    seen_files[filepath] = true

    read_file_async(filepath, function(content)
        if not content then
            callback({})
            return
        end

        local lines = {}
        for line in content:gmatch("([^\n]*)\n?") do
            table.insert(lines, line)
        end

        local parsed_content = {}
        local i = 1
        local function process_line()
            local line = lines[i]
            if not line then
                callback(parsed_content)
                return
            end
            local include = line:match('#include%s+"([^"]+)"')
            if include then
                local include_path = vim.fn.fnamemodify(parent_dir .. "/" .. include, ":p")
                if not M.files[include_path] then
                    parse_includes_async(include_path, vim.fn.fnamemodify(include_path, ":h"), seen_files, function(included_content)
                        if included_content then
                            M.files[include_path] = included_content
                            table.insert(parsed_content, { type = "include", path = include_path, line = i })
                        else
                            table.insert(parsed_content, { type = "line", content = line, line = i })
                        end
                        i = i + 1
                        process_line()
                    end)
                else
                    table.insert(parsed_content, { type = "include", path = include_path, line = i })
                    i = i + 1
                    process_line()
                end
            else
                table.insert(parsed_content, { type = "line", content = line, line = i })
                i = i + 1
                process_line()
            end
        end
        process_line()
    end)
end

-- Function to construct the virtual buffer content and mapping
local function construct_virtual_content_async(original_filepath, callback)
    local lines = {}
    M.line_mapping = {} -- Reset mapping

    local function process_content(content, origin, done)
        local i = 1
        local function process_entry()
            local entry = content[i]
            if not entry then
                done()
                return
            end
            if entry.type == "include" then
                local include_path = entry.path
                if M.files[include_path] then
                    -- Record start of included file
                    local start_line_num = #lines + 1
                    -- Insert included file content
                    process_content(M.files[include_path], include_path, function()
                        -- Record end of included file
                        local end_line_num = #lines
                        -- Set virtual text for boundaries
                        M.boundaries = M.boundaries or {}
                        table.insert(M.boundaries, {
                            start_line = start_line_num,
                            end_line = end_line_num,
                            filepath = include_path,
                        })
                        i = i + 1
                        process_entry()
                    end)
                else
                    -- If included file couldn't be loaded, keep the include line
                    table.insert(lines, entry.content)
                    table.insert(M.line_mapping, { filepath = origin, line = entry.line })
                    i = i + 1
                    process_entry()
                end
            elseif entry.type == "line" then
                table.insert(lines, entry.content)
                table.insert(M.line_mapping, { filepath = origin, line = entry.line })
                i = i + 1
                process_entry()
            else
                i = i + 1
                process_entry()
            end
        end
        process_entry()
    end

    if M.files[original_filepath] then
        process_content(M.files[original_filepath], original_filepath, function()
            callback(lines)
        end)
    else
        callback({})
    end
end

-- Function to create custom highlight groups
local function create_highlight_groups()
    -- Define a distinct highlight for virtual text
    vim.cmd([[highlight ClangdUnfurlBoundary guifg=#FF5555 guibg=NONE gui=bold]])
end

-- Function to open a virtual buffer with unfurled content
function M.open_virtual_buffer()
    M.original_buffer = api.nvim_get_current_buf()
    local filepath = vim.api.nvim_buf_get_name(M.original_buffer)

    if filepath == "" then
        vim.notify("Buffer has no name. Please save the file first.", vim.log.levels.ERROR)
        return
    end

    -- Reset tracking tables
    M.files = {}
    M.file_order = {}
    M.modified_files = {}
    M.line_mapping = {}
    M.boundaries = {}

    -- Parse includes
    parse_includes_async(filepath, nil, nil, function(parsed)
        if not parsed then return end
        table.insert(M.file_order, filepath)
        M.files[filepath] = parsed

        -- Construct virtual content
        construct_virtual_content_async(filepath, function(virtual_content)
            -- Create a new buffer
            M.virtual_buffer = api.nvim_create_buf(false, true) -- [listed = false, scratch = true]
            api.nvim_buf_set_lines(M.virtual_buffer, 0, -1, false, virtual_content)
            api.nvim_buf_set_option(M.virtual_buffer, 'modifiable', true)
            api.nvim_buf_set_option(M.virtual_buffer, 'filetype', 'c')

            -- **Set the buffer's name and directory**
            local temp_filename = vim.fn.fnamemodify(filepath, ":p:h") .. "/_unfurled_" .. vim.fn.fnamemodify(filepath, ":t")
            api.nvim_buf_set_name(M.virtual_buffer, temp_filename)
            api.nvim_set_current_dir(vim.fn.fnamemodify(filepath, ":p:h"))

            -- Create custom highlight groups
            create_highlight_groups()

            -- Open the buffer in a new split window
            vim.cmd('split')
            local win = api.nvim_get_current_win()
            api.nvim_win_set_buf(win, M.virtual_buffer)

            -- Set virtual text for boundaries
            local ns_id = api.nvim_create_namespace('ClangdUnfurl')
            for _, boundary in ipairs(M.boundaries) do
                -- Start boundary
                api.nvim_buf_set_extmark(M.virtual_buffer, ns_id, boundary.start_line - 1, 0, {
                    virt_text = { { "-- Start of " .. vim.fn.fnamemodify(boundary.filepath, ":t") .. " --", "ClangdUnfurlBoundary" } },
                    virt_text_pos = 'eol',
                })
                -- End boundary
                api.nvim_buf_set_extmark(M.virtual_buffer, ns_id, boundary.end_line - 1, 0, {
                    virt_text = { { "-- End of " .. vim.fn.fnamemodify(boundary.filepath, ":t") .. " --", "ClangdUnfurlBoundary" } },
                    virt_text_pos = 'eol',
                })
            end

            -- Set up LSP for buffer
            local lspclients = vim.lsp.get_active_clients()
            local clangd_client = nil
            for _, client in pairs(lspclients) do
                if  client.name == 'clangd' then
                    clangd_client = client
                    break
                end
            end
            if not clangd_client then
                vim.notify("clangd LSP client not found.", vim.log.levels.ERROR)
            else
                vim.lsp.buf_attach_client(M.virtual_buffer, clangd_client.id)
            end

            -- Set up buffer change tracking using nvim_buf_attach
            api.nvim_buf_attach(M.virtual_buffer, false, {
                on_lines = function(_, buf, changedtick, firstline, lastline, new_lastline, bytecount)
                    -- Map changes back to original files
                    for i = firstline + 1, new_lastline do
                        local mapping = M.line_mapping[i]
                        if mapping then
                            local line = api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
                            if not M.modified_files[mapping.filepath] then
                                M.modified_files[mapping.filepath] = {}
                            end
                            M.modified_files[mapping.filepath][mapping.line] = line
                        end
                    end
                end,
                on_detach = function()
                    -- Cleanup if needed
                end,
            })

            -- Provide user feedback
            vim.notify("Unfurled includes in " .. filepath, vim.log.levels.INFO)
        end)
    end)
end

-- Function to save all modified files
function M.save_all()
    for filepath, lines in pairs(M.modified_files) do
        local original_content = {}
        local f = io.open(filepath, "r")
        if f then
            for line in f:lines() do
                table.insert(original_content, line)
            end
            f:close()
            -- Apply modifications
            for line_num, new_line in pairs(lines) do
                original_content[line_num] = new_line
            end
            -- Write back to file
            local f_write = io.open(filepath, "w")
            if f_write then
                f_write:write(table.concat(original_content, "\n"))
                f_write:close()
                vim.notify("Saved changes to " .. filepath, vim.log.levels.INFO)
            else
                vim.notify("Failed to write to " .. filepath, vim.log.levels.ERROR)
            end
        else
            vim.notify("Failed to read " .. filepath, vim.log.levels.ERROR)
        end
    end
    vim.notify("All changes saved.", vim.log.levels.INFO)
end

-- Setup commands and autocommands
function M.setup()
    -- Command to unfurl includes
    api.nvim_create_user_command('UnfurlC', function()
        M.open_virtual_buffer()
    end, {})

    -- Command to save all changes
    api.nvim_create_user_command('UnfurlSave', function()
        M.save_all()
    end, {})
end

return M

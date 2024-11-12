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

-- Utility function to read a file
local function read_file(filepath)
    local f = io.open(filepath, "r")
    if not f then
        vim.notify("Failed to read " .. filepath, vim.log.levels.ERROR)
        return nil
    end
    local content = f:read("*a")
    f:close()
    return content
end

-- Utility function to write to a file
local function write_file(filepath, content)
    local f = io.open(filepath, "w")
    if not f then
        vim.notify("Failed to write to " .. filepath, vim.log.levels.ERROR)
        return
    end
    f:write(content)
    f:close()
end

-- Function to parse includes and load files recursively
local function parse_includes(filepath, parent_dir, seen_files)
    parent_dir = parent_dir or vim.fn.fnamemodify(filepath, ":h")
    seen_files = seen_files or {}

    -- Prevent circular includes
    if seen_files[filepath] then
        vim.notify("Circular include detected: " .. filepath, vim.log.levels.ERROR)
        return {}
    end
    seen_files[filepath] = true

    local content = read_file(filepath)
    if not content then
        return {}
    end

    local lines = {}
    for line in content:gmatch("([^\n]*)\n?") do
        table.insert(lines, line)
    end

    local parsed_content = {}
    for _, line in ipairs(lines) do
        local include = line:match('#include%s+"([^"]+)"')
        if include then
            local include_path = vim.fn.fnamemodify(parent_dir .. "/" .. include, ":p")
            if not M.files[include_path] then
                local included_content = parse_includes(include_path, vim.fn.fnamemodify(include_path, ":h"), seen_files)
                if included_content then
                    M.files[include_path] = included_content
                end
            end
            table.insert(parsed_content, { type = "include", path = include_path })
        else
            table.insert(parsed_content, { type = "line", content = line })
        end
    end

    return parsed_content
end

-- Function to construct the virtual buffer content and mapping
local function construct_virtual_content(original_filepath)
    local lines = {}
    M.line_mapping = {} -- Reset mapping

    local function process_content(content, origin)
        for _, entry in ipairs(content) do
            if entry.type == "include" then
                local include_path = entry.path
                if M.files[include_path] then
                    -- Insert start boundary
                    local start_marker = string.format("-- Start of %s --", vim.fn.fnamemodify(include_path, ":t"))
                    table.insert(lines, start_marker)
                    table.insert(M.line_mapping, { filepath = include_path, line = 0, type = "boundary" })

                    -- Insert included file content
                    for idx, included_entry in ipairs(M.files[include_path]) do
                        if included_entry.type == "line" then
                            table.insert(lines, included_entry.content) -- **FIXED: Insert only the string content**
                            table.insert(M.line_mapping, { filepath = include_path, line = idx, type = "code" })
                        end
                    end

                    -- Insert end boundary
                    local end_marker = string.format("-- End of %s --", vim.fn.fnamemodify(include_path, ":t"))
                    table.insert(lines, end_marker)
                    table.insert(M.line_mapping, { filepath = include_path, line = -1, type = "boundary" })
                else
                    -- If included file couldn't be loaded, keep the include line
                    table.insert(lines, string.format("-- Failed to include %s --", include_path))
                    table.insert(M.line_mapping, { filepath = original_filepath, line = 0, type = "boundary" })
                end
            elseif entry.type == "line" then
                table.insert(lines, entry.content)
                table.insert(M.line_mapping, { filepath = original_filepath, line = 0, type = "code" })
            end
        end
    end

    -- Process the original file first
    if M.files[original_filepath] then
        process_content(M.files[original_filepath], original_filepath)
    end

    return lines
end

-- Function to create custom highlight groups
local function create_highlight_groups()
    -- Define a distinct highlight for boundary markers
    vim.cmd([[highlight ClangdUnfurlBoundary guifg=#FF5555 guibg=#1e1e1e gui=bold]])
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

    -- Parse includes
    local parsed = parse_includes(filepath)
    if not parsed then return end
    table.insert(M.file_order, filepath)
    M.files[filepath] = parsed

    -- Construct virtual content
    local virtual_content = construct_virtual_content(filepath)

    -- Create a new buffer
    M.virtual_buffer = api.nvim_create_buf(false, true) -- [listed = false, scratch = true]
    api.nvim_buf_set_lines(M.virtual_buffer, 0, -1, false, virtual_content)
    api.nvim_buf_set_option(M.virtual_buffer, 'modifiable', true)
    api.nvim_buf_set_option(M.virtual_buffer, 'filetype', 'c')

    -- Create custom highlight groups
    create_highlight_groups()

    -- Open the buffer in a new split window
    vim.cmd('split')
    local win = api.nvim_get_current_win()
    api.nvim_win_set_buf(win, M.virtual_buffer)

    -- Highlight boundary markers
    for idx, mapping in ipairs(M.line_mapping) do
        if mapping.type == "boundary" then
            api.nvim_buf_add_highlight(M.virtual_buffer, -1, 'ClangdUnfurlBoundary', idx -1, 0, -1)
        end
    end

    -- Set up autocmd to prevent editing boundary lines
    api.nvim_create_autocmd({"TextChanged", "TextChangedI"}, {
        buffer = M.virtual_buffer,
        callback = function()
            -- Get the current cursor position
            local cursor = api.nvim_win_get_cursor(0)
            local line_num = cursor[1]
            if not M.line_mapping[line_num] then return end
            local mapping = M.line_mapping[line_num]
            if mapping.type == "boundary" then
                -- Revert the change
                local original_line = api.nvim_buf_get_lines(M.virtual_buffer, line_num -1, line_num, false)[1]
                api.nvim_buf_set_lines(M.virtual_buffer, line_num -1, line_num, false, {original_line})
                vim.notify("Boundary lines are read-only.", vim.log.levels.WARN)
            end
        end
    })

    -- Set up cursor movement to skip boundary lines
    api.nvim_create_autocmd("CursorMoved", {
        buffer = M.virtual_buffer,
        callback = function()
            local cursor = api.nvim_win_get_cursor(0)
            local line_num = cursor[1]
            if not M.line_mapping[line_num] then return end
            local mapping = M.line_mapping[line_num]
            if mapping.type == "boundary" then
                -- Move cursor to the next or previous line
                if line_num < #M.line_mapping then
                    api.nvim_win_set_cursor(0, {line_num +1, 0})
                elseif line_num > 1 then
                    api.nvim_win_set_cursor(0, {line_num -1, 0})
                end
            end
        end
    })

    -- Optional: Make boundary lines non-selectable via mappings
    -- Further enhancements can be done here
end

-- Function to map virtual buffer lines to original files
local function map_line_to_file(line_num)
    if not M.line_mapping[line_num] then
        return nil, nil
    end
    local mapping = M.line_mapping[line_num]
    if mapping.type == "boundary" then
        return nil, nil
    elseif mapping.type == "code" then
        return mapping.filepath, mapping.line
    end
    return nil, nil
end

-- Function to handle buffer changes
local function on_virtual_buf_change(buf, changedtick)
    -- Retrieve all changed lines
    -- This is a simplified approach; for better performance, consider tracking changes more granularly
    local changed_lines = {}
    for line_num, mapping in ipairs(M.line_mapping) do
        local line = api.nvim_buf_get_lines(buf, line_num -1, line_num, false)[1]
        if mapping.type == "code" then
            changed_lines[line_num] = line
            -- Map the change back to the original file
            if not M.modified_files[mapping.filepath] then
                M.modified_files[mapping.filepath] = {}
            end
            -- Here, we assume line numbers correspond; adjust as needed
            if mapping.line > 0 then
                M.modified_files[mapping.filepath][mapping.line] = line
            else
                -- Handle lines with line_num = 0 if necessary
            end
        end
    end
end

-- Function to save all modified files
function M.save_all()
    for filepath, lines in pairs(M.modified_files) do
        local original_content = {}
        local content = read_file(filepath)
        if content then
            for line in content:gmatch("([^\n]*)\n?") do
                table.insert(original_content, line)
            end
            -- Apply modifications
            for line_num, new_line in pairs(lines) do
                if original_content[line_num] then
                    original_content[line_num] = new_line
                else
                    original_content[line_num] = new_line
                end
            end
            -- Write back to file
            write_file(filepath, table.concat(original_content, "\n"))
            vim.notify("Saved changes to " .. filepath, vim.log.levels.INFO)
        else
            vim.notify("Failed to read " .. filepath .. " for saving.", vim.log.levels.ERROR)
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

    -- Autocmd to handle buffer changes
    api.nvim_create_autocmd({"TextChanged", "TextChangedI"}, {
        callback = function(args)
            on_virtual_buf_change(args.buf, args.changedtick)
        end
    })
end

return M
